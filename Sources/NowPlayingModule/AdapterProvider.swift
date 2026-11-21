import AppKit
import Foundation
import NotchCore
import os

/// Where the adapter's pieces live. All paths are absolute.
public struct AdapterLocations: Sendable, Equatable {
    public var perl: URL
    public var script: URL
    public var framework: URL
    public var testClient: URL

    public init(perl: URL = URL(filePath: "/usr/bin/perl"), script: URL, framework: URL, testClient: URL? = nil) {
        self.perl = perl; self.script = script; self.framework = framework
        self.testClient = testClient ?? framework.appending(path: "MediaRemoteAdapterTestClient")
    }

    /// The copies `scripts/bundle.sh` puts in the app: the framework in `Contents/Frameworks`, the script in
    /// `Contents/Resources`. `nil` when either is missing (e.g. `swift run`).
    public static func inBundle(_ bundle: Bundle = .main) -> AdapterLocations? {
        guard
            let frameworks = bundle.privateFrameworksURL, let resources = bundle.resourceURL
        else { return nil }
        let locations = AdapterLocations(
            script: resources.appending(path: "mediaremote-adapter.pl"),
            framework: frameworks.appending(path: "MediaRemoteAdapter.framework", directoryHint: .isDirectory)
        )
        let fm = FileManager.default
        guard fm.fileExists(atPath: locations.script.path), fm.fileExists(atPath: locations.framework.path) else { return nil }
        return locations
    }

    func arguments(_ command: [String]) -> [String] { [script.path, framework.path] + command }

    /// Changes whenever a different adapter build is bundled: size and modification date of the framework binary
    /// and of the script.
    public var identity: String {
        let binary = framework.appending(path: "MediaRemoteAdapter").resolvingSymlinksInPath()
        return [binary, script].map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let date = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            return "\(size)@\(date)"
        }.joined(separator: ",")
    }
}

/// Now playing for any app, via `mediaremote-adapter.pl stream` (MediaRemote through Apple's own perl).
@MainActor
public final class AdapterProvider: NowPlayingProvider {
    public let source = NowPlayingSource.mediaRemote
    public var onUpdate: ((NowPlayingState?) -> Void)?
    public var onFailure: ((NowPlayingFailure) -> Void)?

    private let locations: AdapterLocations
    private let launcher: any ProcessLaunching
    private let backoff: RestartBackoff
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: Logger
    private var task: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?
    private var last: NowPlayingState?
    private var generation = 0
    /// Number of times the stream process has been launched. For tests and diagnostics.
    public private(set) var launches = 0

    public init(
        locations: AdapterLocations, launcher: any ProcessLaunching = FoundationProcessLauncher(),
        backoff: RestartBackoff = RestartBackoff(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: Logger = Log.logger(for: .nowPlaying)
    ) {
        self.locations = locations; self.launcher = launcher; self.backoff = backoff; self.sleep = sleep; self.log = log
    }

    /// Runs the adapter's own `test` command: exit 0 means MediaRemote is reachable. Never plays anything; when no
    /// media is active it briefly publishes a silent fake entry from the test client.
    public nonisolated static func selfTest(
        _ locations: AdapterLocations, launcher: any ProcessLaunching = FoundationProcessLauncher(), timeout: Duration = .seconds(10)
    ) async -> AdapterTestOutcome {
        let result = await launcher.run(
            locations.perl, arguments: [locations.script.path, locations.framework.path, locations.testClient.path, "test"],
            timeout: timeout
        )
        return outcome(of: result)
    }

    /// Exit 0 passes; a timeout or a launch failure (status -1) is unknown; any other exit fails.
    public nonisolated static func outcome(of result: ProcessResult) -> AdapterTestOutcome {
        if result.timedOut || result.status < 0 { return .unknown }
        return result.status == 0 ? .passed : .failed
    }

    public func start() {
        guard task == nil else { return }
        let launcher = launcher, sleep = sleep, log = log, backoff = backoff
        let executable = locations.perl
        let arguments = locations.arguments(["stream", "--micros", "--debounce=60"])
        // Detached so JSON and artwork decoding stay off the main actor; events hop back in order.
        generation &+= 1
        let generation = generation
        // Events carry their run's generation so a stopped run can never leak a late state into the next one.
        let emit: @Sendable (StreamEvent) async -> Void = { [weak self] event in await self?.handle(event, generation: generation) }
        task = Task.detached {
            await Self.supervise(
                launcher: launcher, executable: executable, arguments: arguments, backoff: backoff, sleep: sleep, log: log,
                emit: emit
            )
        }
        removeTerminationObserver()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    enum StreamEvent: Sendable { case launched, state(NowPlayingState?), gaveUp }

    /// Runs the stream process until cancelled, restarting it with backoff when it exits.
    /// Cancelling the calling task terminates the child immediately.
    nonisolated static func supervise(
        launcher: any ProcessLaunching, executable: URL, arguments: [String], backoff: RestartBackoff,
        sleep: @Sendable (Duration) async throws -> Void, log: Logger, emit: @Sendable (StreamEvent) async -> Void
    ) async {
        var backoff = backoff
        var parser = AdapterStreamParser()
        while !Task.isCancelled {
            let began = ContinuousClock.now
            var ran: Duration = .zero
            do {
                let child = try launcher.launch(executable, arguments: arguments)
                await emit(.launched)
                parser.reset()
                await withTaskCancellationHandler {
                    for await chunk in child.output {
                        for state in parser.feed(chunk) { await emit(.state(state)) }
                    }
                } onCancel: {
                    child.terminate()
                }
                let status = await child.waitForExit()
                if Task.isCancelled { return }
                ran = ContinuousClock.now - began
                log.notice("adapter stream exited with status \(status, privacy: .public)")
            } catch {
                log.error("adapter launch failed: \(String(describing: error), privacy: .public)")
            }
            guard let delay = backoff.next(afterRunOf: ran) else {
                log.error("adapter keeps exiting; giving up")
                await emit(.state(nil))
                await emit(.gaveUp)
                return
            }
            do { try await sleep(delay) } catch { return }
        }
    }

    private func handle(_ event: StreamEvent, generation: Int) {
        guard task != nil, generation == self.generation else { return }
        switch event {
        case .launched: launches += 1
        case .state(let state): deliver(state)
        case .gaveUp:
            task = nil
            removeTerminationObserver()
            onFailure?(.gaveUp)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        last = nil
        removeTerminationObserver()
    }

    private func removeTerminationObserver() {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    public func send(_ command: MediaCommand) {
        if command == .togglePlayPause, var optimistic = last {
            optimistic.isPlaying.toggle()
            deliver(optimistic)
        }
        let launcher = launcher, executable = locations.perl
        let arguments = locations.arguments(["send", String(command.adapterID)])
        Task.detached { _ = await launcher.run(executable, arguments: arguments, timeout: .seconds(5)) }
    }

    private func deliver(_ state: NowPlayingState?) {
        guard state != last else { return }
        last = state
        onUpdate?(state)
    }
}

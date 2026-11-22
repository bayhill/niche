import AppKit
import Darwin
import NotchCore
import Observation
import os
import SwiftUI

/// Local servers listening on this Mac: open, copy the address, stop.
///
/// Nothing runs in the background: the listening processes are read when the page appears and every few seconds
/// while it shows, with `lsof` and `libproc`. The ports themselves are never touched. Stop sends SIGTERM, never
/// SIGKILL, and only to a process that is listed and is still the same process when it is checked again.
@MainActor
@Observable
public final class DevServersModule: NotchModule {
    /// List every listening process of the user, not just the ones started from a project folder.
    public static let showAllKey = SettingsKey<Bool>("devServers.showAll", default: false)

    public let id: ModuleID = .devServers
    public let title = "Dev servers"
    public let symbol = "server.rack"
    public let placement: PanelPlacement = .page(order: 50)

    public enum Phase: Sendable, Equatable {
        /// Not listed yet.
        case waiting
        case listed
        /// The last listing failed.
        case failed
    }

    /// A brief state shown on one row.
    public enum RowNote: Sendable, Equatable {
        case copied
        /// Stop was clicked once; a second click stops.
        case confirmStop
        case stopping
        /// SIGTERM was sent but the process is still listening.
        case stillRunning
        /// Nothing was signalled: the process changed, or the signal failed.
        case notStopped
    }

    public struct Note: Sendable, Equatable {
        public var server: DevServer.ID
        public var kind: RowNote
    }

    /// What `stopServer` did.
    public enum StopOutcome: Sendable, Equatable {
        /// SIGTERM was sent and the server is gone.
        case stopped
        /// SIGTERM was sent; the process still listens.
        case stillRunning
        /// The server is not on the page (or no longer the process that was shown); nothing was sent.
        case notListed
        /// The pid now belongs to another process, or the process could not be identified; nothing was sent.
        case changed
        /// The signal could not be delivered.
        case signalFailed
    }

    public private(set) var phase: Phase = .waiting
    /// Every listener of the user, by port. `servers` is what the page shows.
    public private(set) var allServers: [DevServer] = []
    public private(set) var note: Note?
    /// The home folder the project rule measures against.
    public private(set) var home: String

    @ObservationIgnored private let scanner: any DevServerScanning
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private let signal: @MainActor (Int32) -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let followUpInterval: Duration
    @ObservationIgnored private let followUps: Int
    @ObservationIgnored private let ownPID: Int32
    @ObservationIgnored private let fixedHome: Bool
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var log: Logger?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var issued = 0
    @ObservationIgnored private var applied = 0

    /// - Parameters:
    ///   - scanner: lists the listening processes (`LsofScanner` in the app).
    ///   - open: opens a URL in the default browser.
    ///   - copy: puts text on the clipboard.
    ///   - signal: sends SIGTERM to a pid and says whether it was delivered.
    ///   - sleep: waits between refreshes and before a note clears; injected so tests step through time.
    ///   - refreshInterval: how often the list is read again while the page shows.
    ///   - followUpInterval: the wait between checks after a stop.
    ///   - followUps: how many checks after a stop before the server is called still running.
    ///   - home: the home folder for the project rule; `nil` takes it from the context at `start`.
    ///   - ownPID: this app's pid, which is never signalled.
    public init(
        scanner: any DevServerScanning,
        open: @escaping @MainActor (URL) -> Void,
        copy: @escaping @MainActor (String) -> Void,
        signal: @escaping @MainActor (Int32) -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        refreshInterval: Duration = .seconds(3),
        followUpInterval: Duration = .milliseconds(500),
        followUps: Int = 6,
        home: String? = nil,
        ownPID: Int32 = getpid()
    ) {
        self.scanner = scanner
        self.openURL = open
        self.copyText = copy
        self.signal = signal
        self.sleep = sleep
        self.refreshInterval = refreshInterval
        self.followUpInterval = followUpInterval
        self.followUps = followUps
        self.home = home ?? ""
        self.fixedHome = home != nil
        self.ownPID = ownPID
    }

    /// The module the app runs: `lsof` and `libproc`, the default browser, the general pasteboard, SIGTERM.
    public static func live() -> DevServersModule {
        DevServersModule(
            scanner: LsofScanner(),
            open: { NSWorkspace.shared.open($0) },
            copy: DevServersModule.copyToGeneralPasteboard,
            signal: { kill($0, SIGTERM) == 0 }
        )
    }

    /// Four invented servers, one open to the network. Runs no command and signals nothing; Stop removes the row.
    public static func sample() -> DevServersModule {
        let scanner = SampleScanner()
        let module = DevServersModule(
            scanner: scanner, open: { _ in }, copy: { _ in },
            signal: { pid in scanner.remove(pid: pid); return true },
            home: DevServerSamples.home
        )
        module.allServers = DevServerSamples.servers
        module.phase = .listed
        return module
    }

    /// The app's copy: replaces the general pasteboard's contents with the text.
    public static func copyToGeneralPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Lifecycle

    /// Remembers the context. Lists nothing: that waits for the page to appear.
    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        settings = context.settings
        log = context.log
        if !fixedHome { home = context.directories.home.path }
        if viewers > 0 { startPolling() }
        context.log.notice("started")
    }

    public func stop() {
        running = false
        pollTask?.cancel(); pollTask = nil
        noteTask?.cancel(); noteTask = nil
        note = nil
    }

    // MARK: What the page shows

    public var showsAll: Bool { settings?.get(Self.showAllKey) ?? Self.showAllKey.defaultValue }

    /// Dev servers by port, or every listener when `showsAll`.
    public var servers: [DevServer] {
        showsAll ? allServers : allServers.filter { DevServerFilter.isDevServer($0, home: home) }
    }

    // MARK: Refreshing

    /// The page appeared: list now, then every `refreshInterval` until it disappears.
    public func pageAppeared() {
        viewers += 1
        if viewers == 1, running { startPolling() }
    }

    public func pageDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        pollTask?.cancel(); pollTask = nil
    }

    /// True while the page is showing and the list is being kept fresh.
    public var isPolling: Bool { pollTask != nil }

    private func startPolling() {
        pollTask?.cancel()
        let interval = refreshInterval
        let sleep = sleep
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    /// Reads the list once. A result that arrives after a newer one is dropped.
    public func refresh() async { _ = await scanAndApply() }

    /// The fresh list, or `nil` when listing failed. A list older than one already shown is returned, not shown.
    private func scanAndApply() async -> [DevServer]? {
        issued += 1
        let ticket = issued
        let result: Result<[DevServer], ScanError>
        do throws(ScanError) { result = .success(try await scanner.scan()) } catch { result = .failure(error) }
        guard ticket > applied else { return try? result.get() }
        applied = ticket
        switch result {
        case .success(let found):
            if found != allServers || phase != .listed {
                Motion.animate(Motion.morph) {
                    allServers = found
                    phase = .listed
                }
            }
            if let note, note.kind != .stopping, !found.contains(where: { $0.id == note.server }) { clearNote() }
            return found
        case .failure:
            if phase != .failed { log?.error("listing listening processes failed") }
            Motion.animate(Motion.morph) { phase = .failed }
            return nil
        }
    }

    // MARK: Actions

    public func open(_ server: DevServer) {
        log?.info("opening port \(server.port, privacy: .public)")
        openURL(server.url)
    }

    /// Copies `http://localhost:<port>`, with a brief "Copied" on the row.
    public func copy(_ server: DevServer) {
        copyText(server.address)
        Haptics.tick()
        setNote(.copied, for: server.id, clearingAfter: .milliseconds(1200))
    }

    /// The Stop button: the first click asks for a second, the second stops.
    public func requestStop(_ server: DevServer) {
        switch note {
        case Note(server: server.id, kind: .confirmStop):
            Task { await stopServer(server) }
        case Note(server: server.id, kind: .stopping):
            return
        default:
            setNote(.confirmStop, for: server.id, clearingAfter: .seconds(3))
        }
    }

    /// Sends SIGTERM to a listed server's process after checking, with a fresh listing, that the pid still is the
    /// same process (same start time) listening on the same port. Then follows the list until the server is gone.
    @discardableResult
    public func stopServer(_ server: DevServer) async -> StopOutcome {
        guard let listed = servers.first(where: { $0.id == server.id }), listed.startTime == server.startTime else {
            return .notListed
        }
        guard listed.pid > 1, listed.pid != ownPID, let started = listed.startTime else {
            setNote(.notStopped, for: listed.id, clearingAfter: .seconds(3))
            return .changed
        }
        setNote(.stopping, for: listed.id, clearingAfter: nil)
        guard let fresh = await scanAndApply(),
              let current = fresh.first(where: { $0.id == listed.id }), current.startTime == started
        else {
            log?.notice("not stopping pid \(listed.pid, privacy: .public): it changed since it was listed")
            setNote(.notStopped, for: listed.id, clearingAfter: .seconds(3))
            return .changed
        }
        log?.notice(
            "stopping pid \(listed.pid, privacy: .public) on port \(listed.port, privacy: .public), \(listed.projectName ?? "", privacy: .private)"
        )
        guard signal(listed.pid) else {
            log?.error("SIGTERM to pid \(listed.pid, privacy: .public) failed")
            setNote(.notStopped, for: listed.id, clearingAfter: .seconds(3))
            return .signalFailed
        }
        if await isGone(listed) { return .stopped }
        for _ in 0..<followUps {
            do { try await sleep(followUpInterval) } catch { break }
            if await isGone(listed) { return .stopped }
        }
        setNote(.stillRunning, for: listed.id, clearingAfter: .seconds(3))
        return .stillRunning
    }

    /// Refreshes; true (and the note cleared) when that process no longer listens on that port.
    private func isGone(_ server: DevServer) async -> Bool {
        guard let fresh = await scanAndApply() else { return false }
        let gone = !fresh.contains { $0.id == server.id && $0.startTime == server.startTime }
        if gone, note?.server == server.id { clearNote() }
        return gone
    }

    private func setNote(_ kind: RowNote, for server: DevServer.ID, clearingAfter delay: Duration?) {
        noteTask?.cancel(); noteTask = nil
        let next = Note(server: server, kind: kind)
        Motion.animate(Motion.quick) { note = next }
        guard let delay else { return }
        let sleep = sleep
        noteTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.note == next else { return }
            self.clearNote()
        }
    }

    private func clearNote() {
        noteTask?.cancel(); noteTask = nil
        Motion.animate(Motion.quick) { note = nil }
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(DevServersPage(module: self)) }

    public func settingsView() -> AnyView? {
        guard let settings else { return nil }
        return AnyView(DevServersSettings(settings: settings))
    }
}

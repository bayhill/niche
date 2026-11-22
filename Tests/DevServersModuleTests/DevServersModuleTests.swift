import Foundation
import NotchCore
import NotchCoreTesting
import Synchronization
import Testing
@testable import DevServersModule

/// Answers from a list the test changes; counts scans. Can be told to fail.
final class FakeScanner: DevServerScanning {
    private let state: Mutex<(servers: [DevServer], fails: Bool, scans: Int)>

    init(_ servers: [DevServer] = []) { state = Mutex((servers, false, 0)) }

    func scan() async throws(ScanError) -> [DevServer] {
        let (servers, fails) = state.withLock { s in s.scans += 1; return (s.servers, s.fails) }
        if fails { throw .listingFailed }
        return servers
    }

    func set(_ servers: [DevServer]) { state.withLock { $0.servers = servers } }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }
    var scans: Int { state.withLock { $0.scans } }
}

/// Every sleep waits until the test releases it; cancelling the sleeping task ends it with `CancellationError`.
final class SteppedSleeper: Sendable {
    private struct Sleeper {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var next = 0
        var waiting: [Sleeper] = []
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { s in s.next += 1; return s.next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { s -> Bool in
                    if s.cancelled.contains(id) { return true }
                    s.waiting.append(Sleeper(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let index = s.waiting.firstIndex(where: { $0.id == id }) { return s.waiting.remove(at: index).continuation }
                s.cancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// How many sleeps of `duration` are waiting.
    func waiting(_ duration: Duration) -> Int { state.withLock { $0.waiting.filter { $0.duration == duration }.count } }

    /// Ends the oldest waiting sleep of `duration`. False when there is none.
    @discardableResult
    func release(_ duration: Duration) -> Bool {
        let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            guard let index = s.waiting.firstIndex(where: { $0.duration == duration }) else { return nil }
            return s.waiting.remove(at: index).continuation
        }
        continuation?.resume()
        return continuation != nil
    }
}

@MainActor
final class Recorder {
    var opened: [URL] = []
    var copied: [String] = []
    var signalled: [Int32] = []
    var signalSucceeds = true
    /// Runs as the signal is sent, the way the process would quit.
    var onSignal: ((Int32) -> Void)?
}

@MainActor
func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
    let clock = ContinuousClock(), end = clock.now + timeout
    while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
}

let home = "/Users/sample"
let interval = Duration.seconds(3)

let storefront = DevServer(
    pid: 2101, port: 5173, command: "node", executablePath: "/usr/local/bin/node",
    workingDirectory: "\(home)/Projects/storefront", startTime: ProcessStartTime(seconds: 10), hosts: ["127.0.0.1", "[::1]"]
)
let api = DevServer(
    pid: 2202, port: 8000, command: "python3", executablePath: "/usr/local/bin/python3",
    workingDirectory: "\(home)/Projects/api", startTime: ProcessStartTime(seconds: 20), hosts: ["*"]
)
/// An app's helper: listed only with `showAll`.
let helper = DevServer(
    pid: 2303, port: 6463, command: "Helper", executablePath: "/Applications/Chat.app/Contents/MacOS/Helper",
    workingDirectory: "/", startTime: ProcessStartTime(seconds: 30), hosts: ["127.0.0.1"]
)

@MainActor
func makeModule(
    _ scanner: FakeScanner, recorder: Recorder = Recorder(), sleeper: SteppedSleeper = SteppedSleeper(),
    followUps: Int = 2, ownPID: Int32 = 99_999
) -> DevServersModule {
    DevServersModule(
        scanner: scanner,
        open: { recorder.opened.append($0) },
        copy: { recorder.copied.append($0) },
        signal: { pid in
            recorder.signalled.append(pid)
            recorder.onSignal?(pid)
            return recorder.signalSucceeds
        },
        sleep: { try await sleeper.sleep($0) },
        refreshInterval: interval,
        followUpInterval: .milliseconds(500),
        followUps: followUps,
        home: home,
        ownPID: ownPID
    )
}

@MainActor @Suite struct DevServersModuleTests {
    @Test func isAPage() {
        let module = DevServersModule.sample()
        #expect(module.id == .devServers)
        #expect(module.title == "Dev servers")
        #expect(module.symbol == "server.rack")
        #expect(module.placement == .page(order: 50))
        #expect(module.liveActivity == nil)
        #expect(module.nudge == nil)
    }

    @Test func sampleShowsInventedServersAndTouchesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = DevServersModule.sample()
        await module.start(env.context(for: .devServers))
        #expect(module.servers.map(\.portText) == [":3000", ":5173", ":8000", ":8080"])
        #expect(module.servers.map(\.projectName) == ["docs", "storefront", "api", "blog"])
        #expect(module.servers.filter(\.reach.isExposed).map(\.port) == [3000])
        #expect(module.settingsView() != nil)
        // The fixture's Stop takes the row away without signalling anything real.
        #expect(await module.stopServer(module.servers[1]) == .stopped)
        #expect(module.servers.map(\.port) == [3000, 8000, 8080])
        module.stop()
    }

    @Test func noSettingsBeforeStart() {
        #expect(makeModule(FakeScanner()).settingsView() == nil)
    }

    @Test func startListsNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let module = makeModule(scanner)
        await module.start(env.context(for: .devServers))
        #expect(scanner.scans == 0)
        #expect(module.phase == .waiting)
        #expect(!module.isPolling)
        module.stop()
    }

    @Test func refreshesWhileThePageShowsAndStopsWhenItGoes() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let sleeper = SteppedSleeper()
        let module = makeModule(scanner, sleeper: sleeper)
        await module.start(env.context(for: .devServers))

        module.pageAppeared()
        #expect(module.isPolling)
        await waitUntil { sleeper.waiting(interval) == 1 }
        #expect(scanner.scans == 1)
        #expect(module.phase == .listed)
        #expect(module.servers == [storefront])

        scanner.set([storefront, api])
        sleeper.release(interval)
        await waitUntil { scanner.scans == 2 && sleeper.waiting(interval) == 1 }
        #expect(module.servers.map(\.port) == [5173, 8000])

        // A second view of the page does not start a second loop.
        module.pageAppeared()
        module.pageDisappeared()
        #expect(module.isPolling)

        module.pageDisappeared()
        #expect(!module.isPolling)
        await waitUntil { sleeper.waiting(interval) == 0 }
        #expect(sleeper.waiting(interval) == 0)
        #expect(!sleeper.release(interval))
        #expect(scanner.scans == 2)
        module.stop()
    }

    @Test func aPageShownBeforeStartBeginsWithStart() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let sleeper = SteppedSleeper()
        let module = makeModule(scanner, sleeper: sleeper)
        module.pageAppeared()
        #expect(!module.isPolling)
        await module.start(env.context(for: .devServers))
        await waitUntil { scanner.scans == 1 }
        #expect(module.isPolling)
        module.stop()
        #expect(!module.isPolling)
    }

    @Test func listsDevServersOnlyUnlessShowAll() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = makeModule(FakeScanner([storefront, helper, api]))
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(module.allServers.count == 3)
        #expect(module.servers == [storefront, helper, api].filter { $0.pid != helper.pid })
        #expect(!module.showsAll)

        env.settings.set(DevServersModule.showAllKey, true)
        #expect(module.showsAll)
        #expect(module.servers.map(\.pid) == [storefront.pid, helper.pid, api.pid])
        module.stop()
    }

    @Test func homeComesFromTheContextUnlessGiven() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = DevServersModule(scanner: FakeScanner(), open: { _ in }, copy: { _ in }, signal: { _ in false })
        await module.start(env.context(for: .devServers))
        #expect(module.home == env.directories.home.path)
        module.stop()
    }

    @Test func aFailedListingSaysSo() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        scanner.setFails(true)
        let module = makeModule(scanner)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(module.phase == .failed)
        scanner.setFails(false)
        await module.refresh()
        #expect(module.phase == .listed)
        #expect(module.servers == [storefront])
        module.stop()
    }

    @Test func worksThroughLsof() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let runner = ScriptedCommandRunner { _ in CommandResult(status: 0, stdout: Data(lsofFixture.utf8)) }
        let inspector = FakeInspector([
            1201: ProcessDetails(executablePath: "/usr/local/bin/node", workingDirectory: "\(home)/Projects/storefront"),
        ])
        let module = DevServersModule(
            scanner: LsofScanner(runner: runner, inspector: inspector, uid: 501), open: { _ in }, copy: { _ in },
            signal: { _ in false }, home: home
        )
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(module.servers.map(\.portText) == [":5173"])
        #expect(module.allServers.count == 4)
        module.stop()
    }

    @Test func openAndCopyUseTheLocalhostAddress() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let recorder = Recorder()
        let module = makeModule(FakeScanner([storefront]), recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        module.open(storefront)
        module.copy(storefront)
        #expect(recorder.opened == [URL(string: "http://localhost:5173")!])
        #expect(recorder.copied == ["http://localhost:5173"])
        #expect(module.note == .init(server: storefront.id, kind: .copied))
        module.stop()
        #expect(module.note == nil)
    }

    @Test func aNoteClearsAfterItsTime() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let sleeper = SteppedSleeper()
        let module = makeModule(FakeScanner([storefront]), sleeper: sleeper)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        module.copy(storefront)
        await waitUntil { sleeper.waiting(.milliseconds(1200)) == 1 }
        sleeper.release(.milliseconds(1200))
        await waitUntil { module.note == nil }
        #expect(module.note == nil)
        module.stop()
    }

    @Test func stopTakesTwoClicksThenSendsSIGTERMAndRefreshes() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront, api])
        let recorder = Recorder()
        recorder.onSignal = { pid in scanner.set([storefront, api].filter { $0.pid != pid }) }
        let module = makeModule(scanner, recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()

        module.requestStop(storefront)
        #expect(module.note == .init(server: storefront.id, kind: .confirmStop))
        #expect(recorder.signalled.isEmpty)

        module.requestStop(storefront)
        await waitUntil { module.servers == [api] }
        #expect(recorder.signalled == [storefront.pid])
        #expect(module.servers == [api])
        #expect(module.note == nil)
        module.stop()
    }

    @Test func armingAnotherRowDisarmsTheFirst() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let recorder = Recorder()
        let module = makeModule(FakeScanner([storefront, api]), recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        module.requestStop(storefront)
        module.requestStop(api)
        module.requestStop(storefront)
        #expect(module.note == .init(server: storefront.id, kind: .confirmStop))
        #expect(recorder.signalled.isEmpty)
        module.stop()
    }

    @Test func neverSignalsWhatIsNotListed() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let recorder = Recorder()
        let module = makeModule(FakeScanner([storefront, helper]), recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        // Never listed at all.
        #expect(await module.stopServer(api) == .notListed)
        // Listening, but not on the page: an app's helper without showAll.
        #expect(await module.stopServer(helper) == .notListed)
        // Same pid and port as a listed server, but another process.
        var impostor = storefront
        impostor.startTime = ProcessStartTime(seconds: 999)
        #expect(await module.stopServer(impostor) == .notListed)
        #expect(recorder.signalled.isEmpty)
        module.stop()
    }

    @Test func aReusedPidIsNeverSignalled() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let recorder = Recorder()
        let module = makeModule(scanner, recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        // The server quit and another process got its pid and port before Stop.
        var successor = storefront
        successor.startTime = ProcessStartTime(seconds: 11)
        scanner.set([successor])
        #expect(await module.stopServer(storefront) == .changed)
        #expect(recorder.signalled.isEmpty)
        #expect(module.note == .init(server: storefront.id, kind: .notStopped))
        #expect(module.servers == [successor])
        module.stop()
    }

    @Test func aServerThatQuitMeanwhileIsNotSignalled() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let recorder = Recorder()
        let module = makeModule(scanner, recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        scanner.set([])
        #expect(await module.stopServer(storefront) == .changed)
        scanner.set([storefront])
        await module.refresh()
        scanner.setFails(true)
        #expect(await module.stopServer(storefront) == .changed)
        #expect(recorder.signalled.isEmpty)
        module.stop()
    }

    @Test func aProcessWhoseStartIsUnknownIsNotSignalled() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        var unknown = storefront
        unknown.startTime = nil
        let recorder = Recorder()
        let module = makeModule(FakeScanner([unknown]), recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(await module.stopServer(unknown) == .changed)
        #expect(recorder.signalled.isEmpty)
        module.stop()
    }

    @Test func neverSignalsItself() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let recorder = Recorder()
        let module = makeModule(FakeScanner([storefront]), recorder: recorder, ownPID: storefront.pid)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(await module.stopServer(storefront) == .changed)
        #expect(recorder.signalled.isEmpty)
        module.stop()
    }

    @Test func aFailedSignalSaysNotStopped() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let recorder = Recorder()
        recorder.signalSucceeds = false
        let module = makeModule(FakeScanner([storefront]), recorder: recorder)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        #expect(await module.stopServer(storefront) == .signalFailed)
        #expect(recorder.signalled == [storefront.pid])
        #expect(module.note == .init(server: storefront.id, kind: .notStopped))
        module.stop()
    }

    @Test func aServerThatKeepsListeningIsStillRunning() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let recorder = Recorder()
        let sleeper = SteppedSleeper()
        let module = makeModule(scanner, recorder: recorder, sleeper: sleeper, followUps: 2)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        let stopping = Task { await module.stopServer(storefront) }
        await waitUntil { sleeper.waiting(.milliseconds(500)) == 1 }
        #expect(module.note == .init(server: storefront.id, kind: .stopping))
        sleeper.release(.milliseconds(500))
        await waitUntil { sleeper.waiting(.milliseconds(500)) == 1 }
        sleeper.release(.milliseconds(500))
        #expect(await stopping.value == .stillRunning)
        #expect(recorder.signalled == [storefront.pid])
        #expect(module.note == .init(server: storefront.id, kind: .stillRunning))
        // Listed once before, once to re-check, then after the signal and after each follow-up.
        #expect(scanner.scans == 5)
        module.stop()
    }

    @Test func aServerThatQuitsDuringFollowUpsIsStopped() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let scanner = FakeScanner([storefront])
        let sleeper = SteppedSleeper()
        let module = makeModule(scanner, sleeper: sleeper, followUps: 3)
        await module.start(env.context(for: .devServers))
        await module.refresh()
        let stopping = Task { await module.stopServer(storefront) }
        await waitUntil { sleeper.waiting(.milliseconds(500)) == 1 }
        scanner.set([])
        sleeper.release(.milliseconds(500))
        #expect(await stopping.value == .stopped)
        #expect(module.note == nil)
        #expect(module.servers.isEmpty)
        module.stop()
    }
}

import Foundation
import NotchCore
@testable import NowPlayingModule
import Synchronization

final class FakeChild: ChildProcess {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let status: Int32
    private let terminatedFlag = Mutex(false)

    /// - Parameter stayOpen: keep stdout open after the chunks (a long-running stream) until `terminate()`.
    init(chunks: [Data], status: Int32 = 0, stayOpen: Bool = false) {
        (output, continuation) = AsyncStream.makeStream(of: Data.self)
        self.status = status
        for chunk in chunks { continuation.yield(chunk) }
        if !stayOpen { continuation.finish() }
    }

    func waitForExit() async -> Int32 { terminated ? 15 : status }
    func terminate() {
        terminatedFlag.withLock { $0 = true }
        continuation.finish()
    }
    var terminated: Bool { terminatedFlag.withLock { $0 } }
}

final class FakeLauncher: ProcessLaunching {
    private let queue: Mutex<[FakeChild]>
    private let fallback: @Sendable () -> FakeChild
    private let launchedArgs = Mutex<[[String]]>([])
    private let ranArgs = Mutex<[[String]]>([])
    private let result: ProcessResult
    let children = Mutex<[FakeChild]>([])

    init(children: [FakeChild] = [], fallback: @escaping @Sendable () -> FakeChild = { FakeChild(chunks: [], status: 1) },
         runResult: ProcessResult = ProcessResult(status: 0)) {
        queue = Mutex(children); self.fallback = fallback; result = runResult
    }

    func launch(_ executable: URL, arguments: [String]) throws -> any ChildProcess {
        launchedArgs.withLock { $0.append(arguments) }
        let child = queue.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? fallback()
        children.withLock { $0.append(child) }
        return child
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> ProcessResult {
        ranArgs.withLock { $0.append([executable.path] + arguments) }
        return result
    }

    var launched: [[String]] { launchedArgs.withLock { $0 } }
    var ran: [[String]] { ranArgs.withLock { $0 } }
}

/// Records requested delays and returns immediately.
final class RecordingSleeper: Sendable {
    private let delays = Mutex<[Duration]>([])
    var recorded: [Duration] { delays.withLock { $0 } }
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] d in
            delays.withLock { $0.append(d) }
            await Task.yield()
        }
    }
}

@MainActor
final class FakeProvider: NowPlayingProvider {
    let source: NowPlayingSource
    var onUpdate: ((NowPlayingState?) -> Void)?
    var onFailure: ((NowPlayingFailure) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [MediaCommand] = []
    init(_ source: NowPlayingSource) { self.source = source }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func send(_ command: MediaCommand) { sent.append(command) }
}

final class FakeScriptRunner: ScriptRunning {
    let respond: @Sendable (String) -> Result<String, ScriptError>
    let calls = Mutex<Int>(0)
    init(respond: @escaping @Sendable (String) -> Result<String, ScriptError>) { self.respond = respond }
    func run(_ source: String) async -> Result<String, ScriptError> {
        calls.withLock { $0 += 1 }
        return respond(source)
    }
}

@MainActor
func eventually(_ timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

enum StreamFixture {
    static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func full(_ payload: [String: Any]) -> Data { line(["type": "data", "diff": false, "payload": payload]) }
    static func diff(_ payload: [String: Any]) -> Data { line(["type": "data", "diff": true, "payload": payload]) }

    static var track: [String: Any] { [
        "bundleIdentifier": "com.spotify.client", "playing": true, "title": "Paper Lanterns at Low Tide", "artist": "Saltmere Quartet",
        "album": "Harbour Hours", "durationMicros": 480_000_000, "elapsedTimeMicros": 12_500_000,
        "timestampEpochMicros": 1_790_000_000_000_000, "artworkMimeType": "image/png",
    ] }
}

@MainActor
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

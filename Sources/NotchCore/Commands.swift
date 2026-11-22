import Foundation
import Synchronization

/// What a command left behind.
public struct CommandResult: Sendable, Equatable {
    /// The exit status; -1 when the command could not be started.
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    /// The command ran past its timeout and was stopped.
    public var timedOut: Bool

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a command-line tool to completion. Injected so tests never start a process.
public protocol CommandRunning: Sendable {
    /// - Parameters:
    ///   - executable: an absolute path. Nothing is looked up on `PATH` and no shell is involved.
    ///   - environment: replaces the app's environment when given.
    ///   - timeout: the command is sent SIGTERM when it runs longer.
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandResult {
        await run(executable, arguments: arguments, environment: nil, timeout: timeout)
    }
}

/// `Foundation.Process`, with stdin closed and both outputs captured.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(executable, arguments, environment, timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], _ environment: [String: String]?, _ timeout: Duration) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return CommandResult(status: -1, stderr: Data(String(describing: error).utf8))
        }
        // Both pipes are drained while the command runs, so a talkative one cannot block on a full pipe.
        let stdout = Mutex(Data()), stderr = Mutex(Data())
        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            let data = outHandle.readDataToEndOfFile()
            stdout.withLock { $0 = data }
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            let data = errHandle.readDataToEndOfFile()
            stderr.withLock { $0 = data }
        }
        // The pid is only signalled while `waitUntilExit` has not returned, so it cannot have been reused.
        let pid = process.processIdentifier
        let state = Mutex((finished: false, timedOut: false))
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            state.withLock {
                guard !$0.finished else { return }
                $0.timedOut = true
                kill(pid, SIGTERM)
            }
        }
        process.waitUntilExit()
        let timedOut = state.withLock { $0.finished = true; return $0.timedOut }
        readers.wait()
        return CommandResult(
            status: process.terminationStatus, stdout: stdout.withLock { $0 }, stderr: stderr.withLock { $0 }, timedOut: timedOut
        )
    }
}

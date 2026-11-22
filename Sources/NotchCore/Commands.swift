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
    ///   - timeout: the command is sent SIGTERM when it runs longer, and SIGKILL if it is still running a moment
    ///     later. The call returns soon after, even when a process the command started still holds its output open.
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

    /// Seconds a command has after SIGTERM before SIGKILL, and seconds its pipes are still read once it has exited.
    /// A process the command started inherits the pipes and can hold them open for as long as it likes.
    static let grace = 0.5

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
        let readers = DispatchGroup()
        let stdout = PipeDrain(out.fileHandleForReading, group: readers)
        let stderr = PipeDrain(err.fileHandleForReading, group: readers)
        // The pid is signalled only until `waitUntilExit` returns here. Foundation reaps the child on its own queue
        // just before that, so a signal can land in that brief gap after the pid is freed; it would reach another
        // process only if the system handed the same pid out again within the gap.
        let pid = process.processIdentifier
        let state = Mutex((finished: false, timedOut: false))
        let components = timeout.components
        let deadline = DispatchTime.now() + Double(components.seconds) + Double(components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            state.withLock {
                guard !$0.finished else { return }
                $0.timedOut = true
                kill(pid, SIGTERM)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline + grace) {
            state.withLock { if !$0.finished { kill(pid, SIGKILL) } }
        }
        process.waitUntilExit()
        let timedOut = state.withLock { $0.finished = true; return $0.timedOut }
        // Whatever the command itself wrote is already in the pipes; only a process it started can keep them open now.
        if readers.wait(timeout: .now() + grace) == .timedOut {
            stdout.stop()
            stderr.stop()
            readers.wait()
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout.data, stderr: stderr.data, timedOut: timedOut)
    }
}

/// Reads one pipe into memory on its own queue until end of file, or until `stop()`.
/// The handle is closed only by the source's cancel handler, which runs on the same queue after any read in progress,
/// so stopping can never race a read or close a descriptor number that has since been reused.
private final class PipeDrain: Sendable {
    private let source: any DispatchSourceRead
    private let buffer = Mutex(Data())

    init(_ handle: FileHandle, group: DispatchGroup) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "niche.command.pipe"))
        group.enter()
        source.setEventHandler { [self] in drain(fd) }
        source.setCancelHandler {
            try? handle.close()
            group.leave()
        }
        source.activate()
    }

    /// What was read so far.
    var data: Data { buffer.withLock { $0 } }

    /// Stops reading and closes the pipe; what was read is kept.
    func stop() { source.cancel() }

    private func drain(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withLock { $0.append(contentsOf: chunk[..<count]) }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                source.cancel()  // End of file, or the pipe failed.
                return
            }
        }
    }
}

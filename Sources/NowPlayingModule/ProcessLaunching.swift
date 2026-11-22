import Foundation
import Synchronization

/// A running child process whose stdout is consumed as a stream.
public protocol ChildProcess: AnyObject, Sendable {
    /// Raw stdout chunks, in order. Finishes when stdout closes.
    var output: AsyncStream<Data> { get }
    /// Waits for the process to exit and returns its status. Call at most once.
    func waitForExit() async -> Int32
    /// Sends SIGTERM if still running. Safe to call repeatedly and from any thread.
    func terminate()
}

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

/// Starts processes. Injected so tests never spawn anything.
public protocol ProcessLaunching: Sendable {
    func launch(_ executable: URL, arguments: [String]) throws -> any ChildProcess
    /// Runs to completion, killing the process after `timeout`.
    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> ProcessResult
}

/// `Foundation.Process`-backed launcher.
public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ executable: URL, arguments: [String]) throws -> any ChildProcess {
        try FoundationChildProcess(executable: executable, arguments: arguments, captureStderr: false)
    }

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async -> ProcessResult {
        let child: FoundationChildProcess
        do { child = try FoundationChildProcess(executable: executable, arguments: arguments, captureStderr: true) } catch {
            return ProcessResult(status: -1, stderr: Data(String(describing: error).utf8))
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            child.markTimedOut()
            child.terminate()
        }
        var stdout = Data()
        for await chunk in child.output { stdout.append(chunk) }
        let status = await child.waitForExit()
        timer.cancel()
        // The last of stderr can arrive a moment after the exit; without it an error message would be lost.
        await child.waitForStderr(atMost: .milliseconds(500))
        return ProcessResult(status: status, stdout: stdout, stderr: child.collectedStderr, timedOut: child.timedOut)
    }
}

final class FoundationChildProcess: ChildProcess {
    let output: AsyncStream<Data>
    private let exit: AsyncStream<Int32>
    private let process: Mutex<Process>
    private let stderrData: DataBox
    /// Finishes when stderr has been read to its end (at once when stderr is not captured).
    private let stderrEnd: AsyncStream<Void>
    private let timedOutFlag = Mutex(false)

    init(executable: URL, arguments: [String], captureStderr: Bool) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputContinuation.finish()
            } else {
                outputContinuation.yield(data)
            }
        }
        let (exit, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { p in
            exitContinuation.yield(p.terminationStatus)
            exitContinuation.finish()
        }
        let stderrBox = DataBox()
        let (stderrEnd, stderrEndContinuation) = AsyncStream.makeStream(of: Void.self)
        if captureStderr {
            let stderr = Pipe()
            process.standardError = stderr
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stderrEndContinuation.finish()
                } else {
                    stderrBox.value.withLock { $0.append(data) }
                }
            }
        } else {
            process.standardError = FileHandle.nullDevice
            stderrEndContinuation.finish()
        }
        try process.run()
        self.output = output
        self.exit = exit
        self.process = Mutex(process)
        self.stderrData = stderrBox
        self.stderrEnd = stderrEnd
    }

    /// Waits until stderr has been read to its end, but no longer than `limit` (a grandchild may keep it open).
    func waitForStderr(atMost limit: Duration) async {
        let end = stderrEnd
        // Two plain tasks, not a task group: iterating the stream stops when its task is cancelled.
        let reading = Task { for await _ in end {} }
        let deadline = Task {
            try? await Task.sleep(for: limit)
            reading.cancel()
        }
        await reading.value
        deadline.cancel()
    }

    func waitForExit() async -> Int32 {
        for await status in exit { return status }
        return -1
    }

    func terminate() {
        process.withLock { if $0.isRunning { $0.terminate() } }
    }

    func markTimedOut() { timedOutFlag.withLock { $0 = true } }
    var timedOut: Bool { timedOutFlag.withLock { $0 } }
    var collectedStderr: Data { stderrData.value.withLock { $0 } }
}

private final class DataBox: Sendable {
    let value = Mutex(Data())
}

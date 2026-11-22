import Darwin
import Foundation

/// What the kernel says about a running process.
public struct ProcessDetails: Sendable, Hashable {
    public var executablePath: String?
    public var workingDirectory: String?
    public var startTime: ProcessStartTime?

    public init(executablePath: String? = nil, workingDirectory: String? = nil, startTime: ProcessStartTime? = nil) {
        self.executablePath = executablePath; self.workingDirectory = workingDirectory; self.startTime = startTime
    }
}

/// Looks up a process by pid. Injected so tests never read real processes.
public protocol ProcessInspecting: Sendable {
    /// `nil` when the process is gone or belongs to someone else. Fast and synchronous; called off the main actor.
    func details(of pid: Int32) -> ProcessDetails?
}

/// The public `libproc` API: `proc_pidpath` for the executable, `proc_pidinfo` for the working directory and the
/// start time. Works for the current user's processes without any permission.
public struct LibprocInspector: ProcessInspecting {
    public init() {}

    public func details(of pid: Int32) -> ProcessDetails? {
        guard pid > 0 else { return nil }
        let start = startTime(of: pid)
        let executable = executablePath(of: pid)
        let directory = workingDirectory(of: pid)
        guard start != nil || executable != nil || directory != nil else { return nil }
        return ProcessDetails(executablePath: executable, workingDirectory: directory, startTime: start)
    }

    private func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private func startTime(of pid: Int32) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

import Darwin
import Foundation
import NotchCore

/// Why the listening processes could not be listed.
public enum ScanError: Error, Sendable, Equatable {
    /// `lsof` could not be started, ran past its timeout or failed.
    case listingFailed
}

/// Lists every TCP listener of the current user, with what is known about each process. Unfiltered.
public protocol DevServerScanning: Sendable {
    func scan() async throws(ScanError) -> [DevServer]
}

/// `/usr/sbin/lsof` for the sockets, a `ProcessInspecting` for each process. Never touches the ports themselves.
public struct LsofScanner: DevServerScanning {
    public static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    private let runner: any CommandRunning
    private let inspector: any ProcessInspecting
    private let uid: UInt32
    private let timeout: Duration

    public init(
        runner: any CommandRunning = ProcessCommandRunner(), inspector: any ProcessInspecting = LibprocInspector(),
        uid: UInt32 = getuid(), timeout: Duration = .seconds(5)
    ) {
        self.runner = runner; self.inspector = inspector; self.uid = uid; self.timeout = timeout
    }

    public func scan() async throws(ScanError) -> [DevServer] {
        let result = await runner.run(Self.lsof, arguments: Listing.lsofArguments(uid: uid), timeout: timeout)
        // lsof exits 1 when nothing matches, and when part of what it was asked for could not be read; what it
        // did print is still right.
        guard !result.timedOut, result.status == 0 || result.status == 1 else { throw .listingFailed }
        return Self.servers(from: Listing.parse(result.text), inspector: inspector)
    }

    /// Groups sockets into servers and fills in each process once.
    static func servers(from sockets: [ListeningSocket], inspector: any ProcessInspecting) -> [DevServer] {
        var details: [Int32: ProcessDetails?] = [:]
        return Listing.group(sockets).map { group in
            let pid = group.id.pid
            if details[pid] == nil { details[pid] = .some(inspector.details(of: pid)) }
            let info = details[pid] ?? nil
            return DevServer(
                pid: pid, port: group.id.port, command: group.command, executablePath: info?.executablePath,
                workingDirectory: info?.workingDirectory, startTime: info?.startTime, hosts: group.hosts
            )
        }
    }
}

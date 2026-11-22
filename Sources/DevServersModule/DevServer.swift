import Foundation

/// When a process started, as the kernel reports it. Tells a process apart from a later one that reuses its pid.
public struct ProcessStartTime: Sendable, Hashable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64 = 0) {
        self.seconds = seconds; self.microseconds = microseconds
    }
}

/// Which interfaces a listening socket accepts connections on.
public enum Reach: Int, Sendable, Hashable, Comparable {
    /// Only this Mac (`127.0.0.1`, `[::1]`).
    case loopback
    /// One address of this Mac other than loopback, such as a Wi-Fi address: reachable from that network.
    case address
    /// Every interface (`*`, `0.0.0.0`, `[::]`): reachable from any network this Mac is on.
    case allInterfaces

    /// Anything but loopback can be reached by other devices.
    public var isExposed: Bool { self != .loopback }

    public static func < (lhs: Reach, rhs: Reach) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Classifies the host part of an `lsof` address: `*`, `127.0.0.1`, `[::1]`, `[fe80::1%en0]`...
    public static func of(host: String) -> Reach {
        var bare = host
        if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if let zone = bare.firstIndex(of: "%") { bare = String(bare[..<zone]) }
        let lowered = bare.lowercased()
        switch lowered {
        case "*", "0.0.0.0", "::", "::ffff:0.0.0.0": return .allInterfaces
        case "::1", "localhost": return .loopback
        default: break
        }
        if lowered.hasPrefix("127.") || lowered.hasPrefix("::ffff:127.") { return .loopback }
        return .address
    }
}

/// One process listening on one TCP port. IPv4 and IPv6 sockets of the same process and port are one server.
public struct DevServer: Sendable, Hashable, Identifiable {
    public struct ID: Sendable, Hashable {
        public var pid: Int32
        public var port: Int
        public init(pid: Int32, port: Int) { self.pid = pid; self.port = port }
    }

    public var pid: Int32
    public var port: Int
    /// The command name `lsof` reports; used when the executable's path cannot be read.
    public var command: String
    public var executablePath: String?
    public var workingDirectory: String?
    public var startTime: ProcessStartTime?
    /// Every address the process listens on for this port, as `lsof` writes it (`127.0.0.1`, `[::1]`, `*`).
    public var hosts: [String]

    public init(
        pid: Int32, port: Int, command: String, executablePath: String? = nil, workingDirectory: String? = nil,
        startTime: ProcessStartTime? = nil, hosts: [String] = ["127.0.0.1"]
    ) {
        self.pid = pid; self.port = port; self.command = command; self.executablePath = executablePath
        self.workingDirectory = workingDirectory; self.startTime = startTime; self.hosts = hosts
    }

    public var id: ID { ID(pid: pid, port: port) }

    /// The widest reach of any of its sockets.
    public var reach: Reach { hosts.map(Reach.of(host:)).max() ?? .loopback }

    /// "node", "python": the executable's file name, else the command name.
    public var processName: String {
        if let executablePath, let name = executablePath.split(separator: "/").last { return String(name) }
        return command
    }

    /// The working directory's last component ("storefront"); `nil` when unknown or the root.
    public var projectName: String? {
        guard let workingDirectory, let name = workingDirectory.split(separator: "/").last else { return nil }
        return String(name)
    }

    /// ":5173"
    public var portText: String { ":\(port)" }

    /// `http://localhost:5173`
    public var url: URL { URL(string: "http://localhost:\(port)")! }

    /// What Copy puts on the clipboard.
    public var address: String { url.absoluteString }

    /// A non-loopback address it listens on, for the explanation of the network mark.
    public var exposedHost: String? { hosts.first { Reach.of(host: $0).isExposed } }
}

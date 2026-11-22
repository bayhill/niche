import Foundation

/// A listening socket as one `lsof -F` record reports it.
public struct ListeningSocket: Sendable, Hashable {
    public var pid: Int32
    public var command: String
    /// `*`, `127.0.0.1`, `[::1]`...
    public var host: String
    public var port: Int

    public init(pid: Int32, command: String, host: String, port: Int) {
        self.pid = pid; self.command = command; self.host = host; self.port = port
    }
}

/// Reads `lsof -nP -iTCP -sTCP:LISTEN -F pcn` output and groups it into servers.
public enum Listing {
    /// The arguments for every listening TCP socket of one user, in the field format `parse` reads.
    /// `-n`/`-P` keep addresses and ports numeric (no name lookups), `-w` drops warnings, `-a` ANDs the filters.
    public static func lsofArguments(uid: UInt32) -> [String] {
        ["-nP", "-w", "-iTCP", "-sTCP:LISTEN", "-a", "-u", String(uid), "-F", "pcn"]
    }

    /// Parses field output: one field per line, the first character naming it. `p` starts a process, `c` is its
    /// command, `f` starts one of its files and `n` is that file's address (`127.0.0.1:5173`, `[::1]:5173`,
    /// `*:3000`). Anything else (`t`, `T`...) is ignored, and so is a record that does not parse.
    public static func parse(_ text: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        var seen: Set<ListeningSocket> = []
        var pid: Int32?
        var command = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let (host, port) = address(value) else { continue }
                let socket = ListeningSocket(pid: pid, command: command, host: host, port: port)
                if seen.insert(socket).inserted { sockets.append(socket) }
            default:
                continue
            }
        }
        return sockets
    }

    /// Splits `host:port` at the last colon. `[::1]:5173` keeps its brackets; a port must be 1...65535.
    static func address(_ name: String) -> (host: String, port: Int)? {
        // A connection would read `local->remote`; a listener has only the local side.
        guard !name.contains("->"), let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[..<colon])
        guard !host.isEmpty, let port = Int(name[name.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// One server per process and port, sorted by port then pid. Hosts keep the order `lsof` listed them in.
    public static func group(_ sockets: [ListeningSocket]) -> [(id: DevServer.ID, command: String, hosts: [String])] {
        var order: [DevServer.ID] = []
        var groups: [DevServer.ID: (command: String, hosts: [String])] = [:]
        for socket in sockets {
            let id = DevServer.ID(pid: socket.pid, port: socket.port)
            if var group = groups[id] {
                if !group.hosts.contains(socket.host) { group.hosts.append(socket.host) }
                groups[id] = group
            } else {
                order.append(id)
                groups[id] = (socket.command, [socket.host])
            }
        }
        return order
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            .map { (id: $0, command: groups[$0]!.command, hosts: groups[$0]!.hosts) }
    }
}

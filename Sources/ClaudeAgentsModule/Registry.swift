import Darwin
import Foundation

// MARK: - Process inspection

/// What the module needs to know about other processes. Injected so liveness is testable.
public protocol ProcessInspecting: Sendable {
    /// When the process started, or `nil` if no such process is running (zombies count as gone).
    func startTime(of pid: Int32) -> Date?
    /// The parent process id, or `nil` when unknown.
    func parent(of pid: Int32) -> Int32?
}

/// Reads the kernel's process table with `sysctl(KERN_PROC_PID)`. Needs no permission.
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    private func info(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    public func startTime(of pid: Int32) -> Date? {
        guard let info = info(pid), info.kp_proc.p_stat != SZOMB else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    public func parent(of pid: Int32) -> Int32? {
        guard let ppid = info(pid)?.kp_eproc.e_ppid, ppid > 0 else { return nil }
        return ppid
    }
}

// MARK: - Registry record

/// One file in Claude Code's undocumented live registry, `~/.claude/sessions/<pid>.json`.
/// Every field except the pid is optional; unknown fields are ignored and unknown values are kept as strings.
public struct RegistryRecord: Sendable, Equatable {
    public var pid: Int32
    /// Missing in malformed files; then a stand-in `pid:<pid>` id is used so the session still shows.
    public var sessionID: String
    public var cwd: String?
    public var name: String?
    /// Seen in session files: `auto` (generated from the task), `derived` (cwd slug), `user`, `peer`.
    public var nameSource: String?
    /// Seen in session files: `busy`, `idle`, `shell`. `waiting` and `blocked`, with `waitingFor`, are handled too.
    public var status: String?
    /// Why a `waiting` session waits, as short text such as "permission prompt" or "input needed".
    public var waitingFor: String?
    public var statusUpdatedAt: Date?
    public var updatedAt: Date?
    public var startedAt: Date?
    /// `ps -o lstart` style text, e.g. "Wed Nov 18 11:06:40 2026" (UTC in the files seen so far).
    public var procStart: String?
    public var kind: String?
    public var entrypoint: String?
    public var version: String?
    /// A pre-warmed process that no user session has claimed yet.
    public var spare: Bool
    /// Present in some session files: `tempo` "blocked" plus a `needs` sentence saying what the session waits for.
    public var tempo: String?
    public var needs: String?

    public init(
        pid: Int32, sessionID: String, cwd: String? = nil, name: String? = nil, nameSource: String? = nil,
        status: String? = nil, waitingFor: String? = nil, statusUpdatedAt: Date? = nil, updatedAt: Date? = nil,
        startedAt: Date? = nil, procStart: String? = nil, kind: String? = nil, entrypoint: String? = nil,
        version: String? = nil, spare: Bool = false, tempo: String? = nil, needs: String? = nil
    ) {
        self.pid = pid; self.sessionID = sessionID; self.cwd = cwd; self.name = name; self.nameSource = nameSource
        self.status = status; self.waitingFor = waitingFor; self.statusUpdatedAt = statusUpdatedAt
        self.updatedAt = updatedAt; self.startedAt = startedAt; self.procStart = procStart; self.kind = kind
        self.entrypoint = entrypoint; self.version = version; self.spare = spare; self.tempo = tempo; self.needs = needs
    }

    /// Parses one registry file. `fileName` (e.g. "123.json") supplies the pid when the body lacks it.
    /// Returns `nil` only when the data is not a JSON object or no pid can be found.
    public static func parse(_ data: Data, fileName: String? = nil) -> RegistryRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else { return nil }
        let filePID = fileName.flatMap { Int32($0.split(separator: ".").first ?? "") }
        guard let pid = JSONValue.int32(json["pid"]) ?? filePID, pid > 0 else { return nil }
        let session = JSONValue.string(json["sessionId"]).flatMap { $0.isEmpty ? nil : $0 } ?? "pid:\(pid)"
        return RegistryRecord(
            pid: pid, sessionID: session, cwd: JSONValue.string(json["cwd"]), name: JSONValue.string(json["name"]),
            nameSource: JSONValue.string(json["nameSource"]), status: JSONValue.string(json["status"]),
            waitingFor: JSONValue.string(json["waitingFor"]), statusUpdatedAt: JSONValue.date(json["statusUpdatedAt"]),
            updatedAt: JSONValue.date(json["updatedAt"]), startedAt: JSONValue.date(json["startedAt"]),
            procStart: JSONValue.string(json["procStart"]), kind: JSONValue.string(json["kind"]),
            entrypoint: JSONValue.string(json["entrypoint"]), version: JSONValue.string(json["version"]),
            spare: (json["spare"] as? Bool) ?? false, tempo: JSONValue.string(json["tempo"]),
            needs: JSONValue.string(json["needs"])
        )
    }

    /// The moment the status was last set, falling back to the last write and the session start.
    public var observedAt: Date? { statusUpdatedAt ?? updatedAt ?? startedAt }
}

/// Tolerant accessors for `JSONSerialization` values.
enum JSONValue {
    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    static func int32(_ v: Any?) -> Int32? {
        switch v {
        case let n as NSNumber: Int32(exactly: n.doubleValue.rounded(.towardZero))
        case let s as String: Int32(s)
        default: nil
        }
    }

    /// Epoch milliseconds (numbers above 1e11), epoch seconds, numeric strings, or ISO 8601 text.
    static func date(_ v: Any?) -> Date? {
        func fromNumber(_ d: Double) -> Date? {
            guard d.isFinite, d > 0 else { return nil }
            return Date(timeIntervalSince1970: d > 100_000_000_000 ? d / 1000 : d)
        }
        switch v {
        case let n as NSNumber: return fromNumber(n.doubleValue)
        case let s as String:
            if let d = Double(s) { return fromNumber(d) }
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
        default: return nil
        }
    }
}

// MARK: - Liveness

public enum Liveness {
    /// Seconds of slack when comparing start times (`ps` prints whole seconds).
    static let tolerance: TimeInterval = 2

    /// A record counts only if its pid is running and is plausibly the process that wrote it:
    /// - with a parseable `procStart`, the kernel start time must match it (in UTC or local time) within 2 s;
    /// - otherwise, with `startedAt`, the process must have started no later than the session did
    ///   (a recycled pid belongs to a younger process);
    /// - with neither, a running pid is trusted.
    public static func isLive(_ record: RegistryRecord, inspector: any ProcessInspecting) -> Bool {
        guard let started = inspector.startTime(of: record.pid) else { return false }
        if let text = record.procStart, let candidates = parseProcStart(text), !candidates.isEmpty {
            return candidates.contains { abs($0.timeIntervalSince(started)) <= tolerance }
        }
        if let sessionStart = record.startedAt {
            return started.timeIntervalSince(sessionStart) <= tolerance
        }
        return true
    }

    /// "Sat Nov 21 16:59:57 2026" read as UTC and as local time. `nil` when the text is not in that shape.
    public static func parseProcStart(_ text: String) -> [Date]? {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var dates: [Date] = []
        for zone in [TimeZone(identifier: "UTC"), TimeZone.current].compactMap({ $0 }) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            if let d = f.date(from: normalized) { dates.append(d) }
        }
        return dates.isEmpty ? nil : dates
    }
}

// MARK: - Reading the directory

public struct RegistrySnapshot: Sendable, Equatable {
    /// Live records only, one per session id (the most recently updated wins).
    public var records: [RegistryRecord]
    /// False when the directory is missing or unreadable (older Claude Code, or none installed).
    public var available: Bool
    public init(records: [RegistryRecord], available: Bool) { self.records = records; self.available = available }
}

/// Reads `~/.claude/sessions` without ever writing to it. Stale files are skipped, never deleted.
public struct RegistryReader: Sendable {
    public let directory: URL
    public let inspector: any ProcessInspecting

    public init(directory: URL, inspector: any ProcessInspecting) { self.directory = directory; self.inspector = inspector }

    public func read() -> RegistrySnapshot {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return RegistrySnapshot(records: [], available: false)
        }
        var bySession: [String: RegistryRecord] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url), let record = RegistryRecord.parse(data, fileName: name) else { continue }
            guard !record.spare, Liveness.isLive(record, inspector: inspector) else { continue }
            if let existing = bySession[record.sessionID],
               (existing.observedAt ?? .distantPast) >= (record.observedAt ?? .distantPast) { continue }
            bySession[record.sessionID] = record
        }
        let records = bySession.values.sorted { $0.pid < $1.pid }
        return RegistrySnapshot(records: records, available: true)
    }
}

import Foundation

/// One Claude Code hook event, as forwarded by the `niche-bridge` plugin.
public struct HookEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `source`: startup, resume, clear, compact, fork.
        case sessionStart(source: String?)
        case userPromptSubmit
        /// A permission dialog is about to be shown.
        case permissionRequest(tool: String?)
        case postToolUse(tool: String?)
        case postToolUseFailure(tool: String?)
        /// `type`: permission_prompt, idle_prompt, elicitation_dialog, agent_needs_input, auth_success, ...
        case notification(type: String?, message: String?)
        case stop
        /// The turn ended on an API error (`error`: rate_limit, server_error, ...).
        case stopFailure(error: String?)
        /// `reason`: clear, resume, logout, prompt_input_exit, other.
        case sessionEnd(reason: String?)
        /// Any event the reducer does not act on.
        case other(String)
    }

    public var sessionID: String
    public var kind: Kind
    /// When the event happened (the spool file's modification time).
    public var at: Date
    public var cwd: String?
    /// `session_title`, present when the session has a custom title.
    public var title: String?

    public init(sessionID: String, kind: Kind, at: Date, cwd: String? = nil, title: String? = nil) {
        self.sessionID = sessionID; self.kind = kind; self.at = at; self.cwd = cwd; self.title = title
    }

    /// Parses a hook event: the reduced JSON the bridge writes, or a hook's full stdin JSON. Falls back to scanning
    /// the text for the known fields when the JSON does not parse, such as a damaged or cut-short file (the bridge
    /// itself always writes complete JSON, at most 200 characters per field). `nil` without a session id and event name.
    public static func parse(_ data: Data, at: Date) -> HookEvent? {
        var fields: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] {
            fields = json
        } else {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
            fields = [:]
            for key in ["session_id", "hook_event_name", "cwd", "notification_type", "tool_name", "session_title", "source", "reason", "error"] {
                if let value = scanString(key, in: text) { fields[key] = value }
            }
        }
        guard let session = JSONValue.string(fields["session_id"]), !session.isEmpty,
              let name = JSONValue.string(fields["hook_event_name"]), !name.isEmpty
        else { return nil }
        let tool = JSONValue.string(fields["tool_name"])
        let kind: Kind = switch name {
        case "SessionStart": .sessionStart(source: JSONValue.string(fields["source"]))
        case "UserPromptSubmit": .userPromptSubmit
        case "PermissionRequest": .permissionRequest(tool: tool)
        case "PostToolUse": .postToolUse(tool: tool)
        case "PostToolUseFailure": .postToolUseFailure(tool: tool)
        case "Notification":
            .notification(type: JSONValue.string(fields["notification_type"]), message: JSONValue.string(fields["message"]))
        case "Stop": .stop
        case "StopFailure": .stopFailure(error: JSONValue.string(fields["error"]))
        case "SessionEnd": .sessionEnd(reason: JSONValue.string(fields["reason"]))
        default: .other(name)
        }
        return HookEvent(
            sessionID: session, kind: kind, at: at, cwd: JSONValue.string(fields["cwd"]),
            title: JSONValue.string(fields["session_title"]).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `"key": "value"` in raw JSON text, with simple escapes undone.
    static func scanString(_ key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var i = keyRange.upperBound
        func skipSpace() { while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) } }
        skipSpace()
        guard i < text.endIndex, text[i] == ":" else { return nil }
        i = text.index(after: i)
        skipSpace()
        guard i < text.endIndex, text[i] == "\"" else { return nil }
        i = text.index(after: i)
        var out = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                return out
            }
            if c == "\\" {
                i = text.index(after: i)
                guard i < text.endIndex else { return nil }
                switch text[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(text[i])
                }
            } else {
                out.append(c)
            }
            i = text.index(after: i)
        }
        return nil
    }
}

/// Drains the spool folder the bridge writes to. Files are read oldest first and deleted once read, including
/// ones that cannot be parsed; stale ones are deleted unread. Dot-files are the bridge's in-flight temp files; they are left alone unless stale.
public struct SpoolReader: Sendable {
    public let directory: URL
    /// In-flight temp files older than this are leftovers from a killed hook and are removed.
    public var staleTempAge: TimeInterval = 600
    /// Events older than this are deleted unread instead of replayed (left over from a crash; the app drains every
    /// few seconds while it runs).
    public var maxEventAge: TimeInterval = 120

    public init(directory: URL) { self.directory = directory }

    public func drain(now: Date = .now) -> [HookEvent] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: []) else { return [] }
        var files: [(url: URL, date: Date)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let date = values?.contentModificationDate ?? now
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if now.timeIntervalSince(date) > staleTempAge { try? fm.removeItem(at: url) }
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            if now.timeIntervalSince(date) > maxEventAge {
                try? fm.removeItem(at: url)
                continue
            }
            files.append((url, date))
        }
        files.sort { $0.date != $1.date ? $0.date < $1.date : $0.url.lastPathComponent < $1.url.lastPathComponent }
        var events: [HookEvent] = []
        for file in files {
            let data = try? Data(contentsOf: file.url)
            try? fm.removeItem(at: file.url)
            if let data, let event = HookEvent.parse(data, at: file.date) { events.append(event) }
        }
        return events
    }
}

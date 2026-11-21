import Foundation
import Testing
@testable import ClaudeAgentsModule

@Suite struct HookEventParsingTests {
    let now = Fixture.t0

    @Test func parsesDocumentedShapes() throws {
        let n = try #require(HookEvent.parse(Fixture.hook("Notification", extra: #","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#), at: now))
        #expect(n.sessionID == "s1" && n.cwd == "/Users/dev/projects/demo" && n.at == now)
        #expect(n.kind == .notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"))
        #expect(HookEvent.parse(Fixture.hook("PermissionRequest", extra: #","tool_name":"Bash","tool_input":{"command":"ls"}"#), at: now)?.kind == .permissionRequest(tool: "Bash"))
        #expect(HookEvent.parse(Fixture.hook("SessionStart", extra: #","source":"resume","session_title":"Refactor""#), at: now)?.title == "Refactor")
        #expect(HookEvent.parse(Fixture.hook("SessionEnd", extra: #","reason":"clear""#), at: now)?.kind == .sessionEnd(reason: "clear"))
        #expect(HookEvent.parse(Fixture.hook("StopFailure", extra: #","error":"rate_limit""#), at: now)?.kind == .stopFailure(error: "rate_limit"))
        #expect(HookEvent.parse(Fixture.hook("Stop", extra: #","stop_hook_active":false"#), at: now)?.kind == .stop)
        #expect(HookEvent.parse(Fixture.hook("TaskCreated"), at: now)?.kind == .other("TaskCreated"))
    }

    @Test func rejectsEventsWithoutIdentity() {
        #expect(HookEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8), at: now) == nil)
        #expect(HookEvent.parse(Data(#"{"session_id":"x"}"#.utf8), at: now) == nil)
        #expect(HookEvent.parse(Data([0xff, 0xfe, 0x00]), at: now) == nil)
    }

    @Test func truncatedPayloadStillYieldsTheEvent() throws {
        var data = Fixture.hook("PostToolUse", extra: #","tool_name":"Read","tool_response":{"content":""#)
        data.append(Data(repeating: UInt8(ascii: "x"), count: 1000))
        let e = try #require(HookEvent.parse(data, at: now))
        #expect(e.kind == .postToolUse(tool: "Read") && e.sessionID == "s1" && e.cwd == "/Users/dev/projects/demo")
        #expect(HookEvent.scanString("k", in: #"{"k" : "a\"b\nc"}"#) == "a\"b\nc")
    }
}

@Suite struct SpoolTests {
    @Test func drainsInOrderAndDeletesWhatItRead() throws {
        let dir = try Fixture.tempDir("spool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        func put(_ name: String, _ data: Data, mtime: TimeInterval) throws {
            let url = dir.appending(path: name)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: Fixture.t0.addingTimeInterval(mtime)], ofItemAtPath: url.path)
        }
        try put("300-1-1.json", Fixture.hook("Stop"), mtime: 30)
        try put("100-1-1.json", Fixture.hook("UserPromptSubmit"), mtime: 10)
        try put("200-1-2.json", Fixture.hook("PermissionRequest", extra: #","tool_name":"Bash""#), mtime: 20)
        try put("200-1-1.json", Data("{\"session_id\": \"s1\", \"hook_event_name\": \"PostToolUse\", \"tool_resp".utf8), mtime: 20)
        try put("250-1-1.json", Data("garbage".utf8), mtime: 25)
        try put(".event.inflight", Data("{".utf8), mtime: 29)
        try put(".event.stale", Data("{".utf8), mtime: -10_000)
        try put("notes.txt", Data("x".utf8), mtime: 0)

        let events = SpoolReader(directory: dir).drain(now: Fixture.t0.addingTimeInterval(31))
        #expect(events.map(\.kind) == [.userPromptSubmit, .postToolUse(tool: nil), .permissionRequest(tool: "Bash"), .stop],
                "mtime order, file name breaks ties; corrupt skipped; partial parsed leniently")
        #expect(events.first?.at == Fixture.t0.addingTimeInterval(10))
        let left = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == [".event.inflight", "notes.txt"], "read files and stale temps are gone; in-flight temp untouched")
        #expect(SpoolReader(directory: dir).drain(now: Fixture.t0).isEmpty)

        try put("stale.json", Fixture.hook("PermissionRequest"), mtime: -500)
        #expect(SpoolReader(directory: dir).drain(now: Fixture.t0).isEmpty, "stale events are not replayed")
        #expect(!fm.fileExists(atPath: dir.appending(path: "stale.json").path), "and are deleted")
        #expect(SpoolReader(directory: dir.appending(path: "missing")).drain().isEmpty)
    }
}

@Suite struct ForwardScriptTests {
    static let pluginRoot = Fixture.repoRoot.appending(path: "Support/ClaudePlugin/plugins/notcher-bridge")
    let script = pluginRoot.appending(path: "scripts/forward.sh")

    /// The exact command string from hooks.json.
    static func hookCommand() throws -> String {
        let url = pluginRoot.appending(path: "hooks/hooks.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        let commands = Set(hooks.values.flatMap { $0 }.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String })
        #expect(commands.count == 1)
        return try #require(commands.first)
    }

    static func run(_ executable: String, _ arguments: [String], env: [String: String], cwd: URL? = nil, input: Data) throws -> (status: Int32, out: Data, err: Data) {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = arguments
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        let writer = Thread { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
        writer.start()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }

    func run(home: URL, input: Data) throws -> (status: Int32, out: Data, err: Data) {
        try Self.run("/bin/bash", [script.path], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"], input: input)
    }

    func makeSpool() throws -> (home: URL, spool: URL) {
        let home = try Fixture.tempDir("home")
        let spool = home.appending(path: "Library/Application Support/Notcher/claude-events")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        return (home, spool)
    }

    func written(_ spool: URL) throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.hasSuffix(".json") && !name.hasPrefix("."))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: spool.appending(path: name))) as? [String: Any])
    }

    @Test func writesOnlyTheFieldsTheAppReads() throws {
        let (home, spool) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Data(#"{"session_id":"s1","transcript_path":"/Users/dev/.claude/projects/x/s1.jsonl","cwd":"/Users/dev/projects/demo","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"my secret prompt","session_title":"Fix cart","effort":{"level":"high"},"x":null}"#.utf8)
        let r = try run(home: home, input: input)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let fields = try written(spool)
        #expect(Set(fields.keys) == ["session_id", "hook_event_name", "cwd", "session_title"])
        #expect(fields["session_title"] as? String == "Fix cart")
        let raw = try String(contentsOf: spool.appending(path: FileManager.default.contentsOfDirectory(atPath: spool.path)[0]), encoding: .utf8)
        #expect(!raw.contains("secret") && !raw.contains("transcript"))
        #expect(SpoolReader(directory: spool).drain().map(\.kind) == [.userPromptSubmit])
    }

    @Test func notificationKeepsTypeAndMessage() throws {
        let (home, spool) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try run(home: home, input: Fixture.hook("Notification", extra: #","notification_type":"permission_prompt","message":"Claude needs \"permission\"\nto use Bash","title":"Claude Code""#))
        let fields = try written(spool)
        #expect(fields["message"] as? String == "Claude needs \"permission\"\nto use Bash")
        #expect(SpoolReader(directory: spool).drain().map(\.kind) == [.notification(type: "permission_prompt", message: "Claude needs \"permission\"\nto use Bash")])
    }

    @Test func dropsToolContentAndCapsLongText() throws {
        let (home, spool) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: home) }
        var input = Fixture.hook("PostToolUse", extra: #","tool_name":"Read","tool_input":{"file_path":"/etc/secret"},"session_title":""#)
        input.append(Data(String(repeating: "\u{00E9}\u{1F600}", count: 400).utf8))
        input.append(Data(#"","tool_response":""#.utf8))
        input.append(Data(repeating: UInt8(ascii: "y"), count: 300_000))
        input.append(Data("\"}".utf8))
        let r = try run(home: home, input: input)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let name = try FileManager.default.contentsOfDirectory(atPath: spool.path)[0]
        let data = try Data(contentsOf: spool.appending(path: name))
        #expect(data.count < 2048, "the event on disk stays small")
        let fields = try written(spool)
        #expect(fields["tool_input"] == nil && fields["tool_response"] == nil)
        #expect((fields["session_title"] as? String)?.count == 200, "cut by characters, still valid UTF-8")
        #expect(SpoolReader(directory: spool).drain().map(\.kind) == [.postToolUse(tool: "Read")])
    }

    @Test func skipsWhenNobodyDrains() throws {
        let (home, spool) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: home) }
        for i in 0..<51 { try Data("{}".utf8).write(to: spool.appending(path: "old-\(i).json")) }
        let r = try run(home: home, input: Fixture.hook("Stop"))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).count == 51)
    }

    @Test func doesNothingWhenAlertsAreOff() throws {
        let home = try Fixture.tempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let r = try run(home: home, input: Fixture.hook("Stop"))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let all = FileManager.default.enumerator(atPath: home.path)?.allObjects ?? []
        #expect(all.isEmpty, "no file and no folder created")
    }

    /// Runs the exact hooks.json command string through `sh -c` (as Claude Code does for shell-form hooks), with the
    /// plugin at a path containing a space, both with the variable left for the shell and substituted inline.
    /// Hostile stdin must never execute.
    @Test func hookCommandNeverRunsStdinAsCode() throws {
        let command = try Self.hookCommand()
        #expect(command == #"/bin/bash "${CLAUDE_PLUGIN_ROOT}/scripts/forward.sh""#)
        let (home, spool) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: home) }
        let pluginCopy = home.appending(path: "Application Support/claude-plugin/plugins/notcher-bridge")
        try FileManager.default.createDirectory(at: pluginCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.pluginRoot, to: pluginCopy)
        let marker = home.appending(path: "pwned")
        let hostileValues = [
            "$(touch \(marker.path))", "`touch \(marker.path)2`", "'; touch \(marker.path)3; '", "\"; touch \(marker.path)4; \"",
            "line\ntouch \(marker.path)5\n",
        ]
        let hostileJSON = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "$(touch \(marker.path)6)", "hook_event_name": "Notification",
            "notification_type": "permission_prompt", "message": hostileValues.joined(separator: " "),
            "prompt": hostileValues.joined(separator: "\n"),
        ])
        let notJSON = Data("touch \(marker.path)7\n$(touch \(marker.path)8)\n`touch \(marker.path)9`\n".utf8)
        let inline = command.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginCopy.path)
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "CLAUDE_PLUGIN_ROOT": pluginCopy.path]
        for cmd in [command, inline] {
            for input in [hostileJSON, notJSON] {
                let r = try Self.run("/bin/sh", ["-c", cmd], env: env, cwd: home, input: input)
                #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
            }
        }
        let created = (FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String] ?? []).filter { $0.contains("pwned") }
        #expect(created.isEmpty, "nothing from stdin executed: \(created)")
        let events = SpoolReader(directory: spool).drain()
        #expect(events.count == 2, "the valid event is forwarded once per command form; non-JSON is dropped")
        #expect(events.allSatisfy { if case .notification(_, let message) = $0.kind { message?.contains("$(touch") == true } else { false } },
                "hostile text survives only as inert data")
    }

    @Test func pluginManifestsAreWellFormed() throws {
        let root = Fixture.repoRoot.appending(path: "Support/ClaudePlugin")
        let market = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: ".claude-plugin/marketplace.json"))) as? [String: Any])
        #expect(market["name"] as? String == HookInstaller.marketplace)
        let plugins = try #require(market["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == HookInstaller.plugin)
        let hooks = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "plugins/notcher-bridge/hooks/hooks.json"))) as? [String: Any])
        let events = try #require(hooks["hooks"] as? [String: [[String: Any]]])
        #expect(Set(events.keys) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"])
        let handlers = events.values.flatMap { $0 }.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        #expect(handlers.allSatisfy { $0["args"] == nil }, "shell form only: no exec-form args to be ignored by older versions")
    }
}

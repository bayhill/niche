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
        #expect(SpoolReader(directory: dir.appending(path: "missing")).drain().isEmpty)
    }
}

@Suite struct ForwardScriptTests {
    let script = Fixture.repoRoot.appending(path: "Support/ClaudePlugin/plugins/notcher-bridge/scripts/forward.sh")

    func run(home: URL, input: Data) throws -> (status: Int32, out: Data, err: Data) {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
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

    @Test func writesOneFileSilently() throws {
        let home = try Fixture.tempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let spool = home.appending(path: "Library/Application Support/Notcher/claude-events")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let input = Fixture.hook("Notification", extra: #","notification_type":"permission_prompt","message":"hi""#)
        let r = try run(home: home, input: input)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.hasSuffix(".json") && !name.hasPrefix("."))
        #expect(try Data(contentsOf: spool.appending(path: name)) == input)
        let events = SpoolReader(directory: spool).drain()
        #expect(events.map(\.kind) == [.notification(type: "permission_prompt", message: "hi")])
    }

    @Test func truncatesHugePayloadsButKeepsTheEvent() throws {
        let home = try Fixture.tempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let spool = home.appending(path: "Library/Application Support/Notcher/claude-events")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        var input = Fixture.hook("PostToolUse", extra: #","tool_name":"Read","tool_response":""#)
        input.append(Data(repeating: UInt8(ascii: "y"), count: 300_000))
        input.append(Data("\"}".utf8))
        let r = try run(home: home, input: input)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
        #expect(files.count == 1)
        #expect(try Data(contentsOf: spool.appending(path: files[0])).count == 65_536)
        #expect(SpoolReader(directory: spool).drain().map(\.kind) == [.postToolUse(tool: "Read")])
    }

    @Test func doesNothingWhenAlertsAreOff() throws {
        let home = try Fixture.tempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let r = try run(home: home, input: Fixture.hook("Stop"))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let all = FileManager.default.enumerator(atPath: home.path)?.allObjects ?? []
        #expect(all.isEmpty, "no file and no folder created")
    }

    @Test func pluginManifestsAreWellFormed() throws {
        let root = Fixture.repoRoot.appending(path: "Support/ClaudePlugin")
        let market = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: ".claude-plugin/marketplace.json"))) as? [String: Any])
        #expect(market["name"] as? String == HookInstaller.marketplace)
        let plugins = try #require(market["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == HookInstaller.plugin)
        let hooks = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "plugins/notcher-bridge/hooks/hooks.json"))) as? [String: Any])
        let events = try #require(hooks["hooks"] as? [String: Any])
        #expect(Set(events.keys) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"])
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }
}

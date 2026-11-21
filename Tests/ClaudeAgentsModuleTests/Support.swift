import Foundation
@testable import ClaudeAgentsModule

/// Process table for tests.
struct FakeInspector: ProcessInspecting {
    var starts: [Int32: Date] = [:]
    var parents: [Int32: Int32] = [:]
    func startTime(of pid: Int32) -> Date? { starts[pid] }
    func parent(of pid: Int32) -> Int32? { parents[pid] }
}

/// Records every command and plays the part of the `claude` CLI against a fixture settings.json.
actor RecordingRunner: ProcessRunning {
    struct Call: Equatable { var executable: URL; var arguments: [String] }
    private(set) var calls: [Call] = []
    let settings: URL
    var failOn: String?

    init(settings: URL, failOn: String? = nil) { self.settings = settings; self.failOn = failOn }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if let failOn, arguments.contains(failOn) { return ProcessResult(status: 1, stderr: "boom") }
        var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
        var enabled = json["enabledPlugins"] as? [String: Any] ?? [:]
        var markets = json["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        switch Array(arguments.prefix(3)) {
        case ["plugin", "marketplace", "add"]:
            markets["notcher-local"] = ["source": ["source": "directory", "path": arguments[3]]]
        case ["plugin", "install", "notcher-bridge@notcher-local"]: enabled["notcher-bridge@notcher-local"] = true
        case ["plugin", "uninstall", "notcher-bridge@notcher-local"]: enabled["notcher-bridge@notcher-local"] = nil
        case ["plugin", "marketplace", "remove"]: markets["notcher-local"] = nil
        default: break
        }
        json["enabledPlugins"] = enabled
        json["extraKnownMarketplaces"] = markets
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        return ProcessResult(status: 0, stdout: "ok")
    }
}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Sanitised from real `~/.claude/sessions/*.json` files (Claude Code 2.1.318–2.1.330).
    static let busyAuto = #"{"pid":4242,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000001","cwd":"/Users/dev/projects/demo","startedAt":1795280402474,"procStart":"Sat Nov 21 16:59:57 2026","version":"2.1.330","peerProtocol":1,"peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin","asksForConvertedSkills":false,"messagingSocketPath":"/tmp/cc-socks/4242.sock","name":"build-demo-app","nameSource":"auto","nameSince":1795283523654,"status":"busy","updatedAt":1795283523654,"statusUpdatedAt":1795283522055}"#
    static let idleDerived = #"{"pid":4343,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000002","cwd":"/Users/dev/projects/Shop.Web","startedAt":1795160784184,"procStart":"Fri Nov 20 07:46:19 2026","version":"2.1.329","kind":"interactive","entrypoint":"cli","pidDomain":"darwin","name":"shop-web-85","nameSource":"derived","nameSince":1795160784184,"status":"idle","updatedAt":1795283720896,"statusUpdatedAt":1795283720896}"#
    static let shell = #"{"pid":4444,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000003","cwd":"/Users/dev/projects/gui","startedAt":1795192489143,"procStart":"Fri Nov 20 16:34:43 2026","version":"2.1.329","kind":"interactive","entrypoint":"cli","name":"gui-8f","nameSource":"derived","status":"shell","updatedAt":1795280066430,"statusUpdatedAt":1795280066430}"#
    static let vscode = #"{"pid":4545,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000004","cwd":"/Users/dev","startedAt":1793868289263,"procStart":"Thu Nov  5 08:44:46 2026","version":"2.1.318","kind":"interactive","entrypoint":"claude-vscode","pidDomain":"darwin","name":"dev-e0","nameSource":"derived","nameSince":1793868289263,"updatedAt":1793868289335,"status":"idle","statusUpdatedAt":1793868289335}"#

    static func hook(_ name: String, session: String = "s1", extra: String = "") -> Data {
        Data(#"{"session_id":"\#(session)","transcript_path":"/Users/dev/.claude/projects/x/\#(session).jsonl","cwd":"/Users/dev/projects/demo","permission_mode":"default","hook_event_name":"\#(name)"\#(extra)}"#.utf8)
    }

    static func event(_ kind: HookEvent.Kind, _ session: String = "s1", at offset: TimeInterval, cwd: String? = "/Users/dev/projects/demo") -> HookEvent {
        HookEvent(sessionID: session, kind: kind, at: t0.addingTimeInterval(offset), cwd: cwd)
    }

    static func record(
        _ session: String = "s1", pid: Int32 = 100, status: String?, at offset: TimeInterval, waitingFor: String? = nil,
        name: String? = "demo-task", nameSource: String? = "auto", cwd: String = "/Users/dev/projects/demo"
    ) -> RegistryRecord {
        RegistryRecord(
            pid: pid, sessionID: session, cwd: cwd, name: name, nameSource: nameSource, status: status, waitingFor: waitingFor,
            statusUpdatedAt: t0.addingTimeInterval(offset), updatedAt: t0.addingTimeInterval(offset),
            startedAt: t0.addingTimeInterval(-3600), entrypoint: "cli"
        )
    }

    static func tempDir(_ label: String = "claude") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "notcher-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The worktree root, from this file's path.
    static var repoRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

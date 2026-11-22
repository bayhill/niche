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

    /// Invented session files in the shape of `~/.claude/sessions/<pid>.json`, holding only fields the parser reads.
    static let busyAuto = #"{"pid":4242,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000001","cwd":"/Users/dev/projects/demo","startedAt":1795000003250,"procStart":"Wed Nov 18 11:06:40 2026","version":"9.1.2","kind":"interactive","entrypoint":"cli","name":"build-demo-app","nameSource":"auto","status":"busy","updatedAt":1795003600000,"statusUpdatedAt":1795003598500}"#
    static let idleDerived = #"{"pid":4343,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000002","cwd":"/Users/dev/projects/Garden.Web","startedAt":1795100002000,"procStart":"Thu Nov 19 14:53:20 2026","version":"9.1.1","kind":"interactive","entrypoint":"cli","name":"garden-web-85","nameSource":"derived","status":"idle","updatedAt":1795103000000,"statusUpdatedAt":1795103000000}"#
    static let shell = #"{"pid":4444,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000003","cwd":"/Users/dev/projects/gui","startedAt":1795200001500,"procStart":"Fri Nov 20 18:40:00 2026","version":"9.1.1","kind":"interactive","entrypoint":"cli","name":"gui-8f","nameSource":"derived","status":"shell","updatedAt":1795201000000,"statusUpdatedAt":1795201000000}"#
    static let vscode = #"{"pid":4545,"sessionId":"11111111-aaaa-4bbb-8ccc-000000000004","cwd":"/Users/dev","startedAt":1794000002100,"procStart":"Fri Nov  6 21:20:00 2026","version":"9.0.7","kind":"interactive","entrypoint":"claude-vscode","name":"dev-e0","nameSource":"derived","status":"idle","updatedAt":1794000002200,"statusUpdatedAt":1794000002200}"#

    /// A hook's stdin with the fields the parser reads; `extra` is spliced in after the event name.
    static func hook(_ name: String, session: String = "s1", extra: String = "") -> Data {
        Data(#"{"session_id":"\#(session)","cwd":"/Users/dev/projects/demo","hook_event_name":"\#(name)"\#(extra)}"#.utf8)
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

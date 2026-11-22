import Foundation
import NotchCore
import NotchCoreTesting
import Synchronization
import Testing
@testable import BuildsModule

/// A sleep the test wakes by hand. Records every requested duration; cancellation ends the sleep at once.
final class ManualSleeper: Sendable {
    private struct State {
        var requested: [Duration] = []
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        var cancelledEarly: Set<UUID> = []
    }

    private let state = Mutex(State())

    var requested: [Duration] { state.withLock { $0.requested } }
    var pending: Int { state.withLock { $0.waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { s -> Bool in
                    if s.cancelledEarly.remove(id) != nil { return true }
                    s.requested.append(duration)
                    s.waiters.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let index = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: index).continuation }
                s.cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest sleep.
    func wake() {
        let continuation = state.withLock { s in s.waiters.isEmpty ? nil : s.waiters.removeFirst().continuation }
        continuation?.resume()
    }
}

/// Answers gh's `run list` by `--repo=` and `--branch=`; anything unscripted is an empty list.
final class FakeGitHub: Sendable {
    private final class Answers: Sendable {
        let state = Mutex<[String: CommandResult]>([:])
    }

    private let answers: Answers
    let runner: ScriptedCommandRunner

    init() {
        let answers = Answers()
        self.answers = answers
        runner = ScriptedCommandRunner { call in
            let key = FakeGitHub.key(call.arguments)
            return answers.state.withLock { $0[key] } ?? CommandResult(status: 0, stdout: Data("[]".utf8))
        }
    }

    /// - Parameter branch: `nil` for the call without `--branch`.
    func answer(_ repo: String, branch: String? = nil, _ result: CommandResult) {
        answers.state.withLock { $0[Self.key(repo: repo, branch: branch)] = result }
    }

    func runs(_ repo: String, branch: String? = nil, _ runs: [RunJSON]) {
        answer(repo, branch: branch, CommandResult(status: 0, stdout: Data(RunJSON.array(runs).utf8)))
    }

    var calls: [ScriptedCommandRunner.Call] { runner.calls }

    static func key(repo: String, branch: String?) -> String { "\(repo)|\(branch ?? "-")" }

    static func key(_ arguments: [String]) -> String {
        let repo = arguments.first { $0.hasPrefix("--repo=") }.map { String($0.dropFirst("--repo=".count)) } ?? ""
        let branch = arguments.first { $0.hasPrefix("--branch=") }.map { String($0.dropFirst("--branch=".count)) }
        return key(repo: repo, branch: branch)
    }
}

/// One invented run, written the way `gh run list --json` writes it.
struct RunJSON {
    var id: Int
    var workflow = "CI"
    var branch = "main"
    var sha = "c0ffee"
    var status = "completed"
    var conclusion = ""
    var created = "2026-03-01T10:00:00Z"
    var updated = "2026-03-01T10:04:00Z"
    var title = "Tidy the build script"

    var json: String {
        """
        {"databaseId":\(id),"displayTitle":"\(title)","workflowName":"\(workflow)","headBranch":"\(branch)",\
        "headSha":"\(sha)","status":"\(status)","conclusion":"\(conclusion)","event":"push",\
        "createdAt":"\(created)","updatedAt":"\(updated)","url":"https://github.com/acme/widget/actions/runs/\(id)"}
        """
    }

    static func array(_ runs: [RunJSON]) -> String { "[" + runs.map(\.json).joined(separator: ",") + "]" }

    /// Started `started` minutes before now, last changed `changed` minutes before now.
    func ago(started: Double, changed: Double? = nil) -> RunJSON {
        var copy = self
        let now = Date()
        copy.created = now.addingTimeInterval(-started * 60).formatted(.iso8601)
        copy.updated = now.addingTimeInterval(-(changed ?? started) * 60).formatted(.iso8601)
        return copy
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_772_359_200)  // 2026-03-01T10:00:00Z
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Writes a minimal `.git` folder: `config` with the given remotes, and `HEAD`.
@discardableResult
func makeRepository(
    in root: URL, _ name: String, remotes: [(String, String)] = [("origin", "git@github.com:acme/widget.git")],
    head: String = "ref: refs/heads/main\n"
) throws -> URL {
    let folder = root.appending(path: name, directoryHint: .isDirectory)
    let git = folder.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    var config = "[core]\n\trepositoryformatversion = 0\n\tbare = false\n"
    for (remote, url) in remotes {
        config += "[remote \"\(remote)\"]\n\turl = \(url)\n\tfetch = +refs/heads/*:refs/remotes/\(remote)/*\n"
    }
    try config.write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
    try head.write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
    return folder
}

func setHead(_ folder: URL, _ head: String) throws {
    try head.write(to: folder.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
}

@MainActor
func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(15)) async {
    let clock = ContinuousClock(), end = clock.now + timeout
    while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
}

/// Lets tasks that are ready run to their next suspension.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

/// Flips whether gh "exists".
final class Installed: Sendable {
    private let state: Mutex<Bool>
    init(_ on: Bool) { state = Mutex(on) }
    var on: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

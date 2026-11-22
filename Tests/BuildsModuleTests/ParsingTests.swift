import Foundation
import NotchCore
import NotchCoreTesting
import Testing
@testable import BuildsModule

@Suite struct RemoteURLTests {
    @Test(arguments: [
        ("git@github.com:acme/widget.git", "github.com", "acme", "widget"),
        ("git@github.com:acme/widget", "github.com", "acme", "widget"),
        ("https://github.com/acme/widget.git", "github.com", "acme", "widget"),
        ("https://github.com/acme/widget", "github.com", "acme", "widget"),
        ("https://github.com/acme/widget/", "github.com", "acme", "widget"),
        ("ssh://git@github.com/acme/widget.git", "github.com", "acme", "widget"),
        ("ssh://git@git.example.com:2222/acme/widget.git", "git.example.com", "acme", "widget"),
        ("https://someone@GitHub.com/acme/widget.js.git", "github.com", "acme", "widget.js"),
        ("git://github.com/acme/my_widget.git", "github.com", "acme", "my_widget"),
        ("  git@code.example.org:acme-labs/widget.git\n", "code.example.org", "acme-labs", "widget"),
    ])
    func parses(_ raw: String, _ host: String, _ owner: String, _ name: String) {
        #expect(RemoteURL.parse(raw) == RemoteURL.Parts(host: host, owner: owner, name: name))
    }

    @Test(arguments: [
        "", "widget", "/srv/git/widget.git", "file:///srv/git/acme/widget.git", "https://github.com/acme",
        "https://gitlab.example.com/group/sub/widget.git", "git@github.com:-acme/widget.git", "https:///acme/widget",
        "git@github.com:acme/wid get.git", "ftp://github.com/acme/widget",
    ])
    func rejects(_ raw: String) {
        #expect(RemoteURL.parse(raw) == nil)
    }
}

@Suite struct GitConfigTests {
    @Test func readsRemotesInOrder() {
        let config = """
        [core]
        \tbare = false
        ; a comment
        [remote "upstream"]
        \turl = https://github.com/acme/upstream.git
        [branch "main"]
        \tremote = origin
        \turl = not-a-remote
        [Remote "origin"]
        \tURL = "git@github.com:acme/widget.git" # trailing comment
        \turl = git@github.com:acme/second.git
        [remote.legacy]
        \turl = https://github.com/acme/legacy
        """
        #expect(GitConfig.remotes(in: config) == [
            .init(name: "upstream", url: "https://github.com/acme/upstream.git"),
            .init(name: "origin", url: "git@github.com:acme/widget.git"),
            .init(name: "legacy", url: "https://github.com/acme/legacy"),
        ])
    }

    @Test func noRemotes() {
        #expect(GitConfig.remotes(in: "[core]\n\tbare = false\n").isEmpty)
        #expect(GitConfig.remotes(in: "").isEmpty)
        #expect(GitConfig.remotes(in: "[remote \"origin\"]\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n").isEmpty)
    }
}

@Suite struct GitFolderTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "builds-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let files = DiskRepositoryFiles()

    @Test func readsOriginElseFirstRemote() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let both = try makeRepository(in: root, "both", remotes: [
            ("upstream", "https://github.com/acme/upstream.git"), ("origin", "git@github.com:acme/widget.git"),
        ])
        let repo = try BuildRepository.read(folder: both, files: files)
        #expect(repo.slug == "acme/widget")
        #expect(repo.host == "github.com")
        #expect(repo.repoArgument == "acme/widget")
        #expect(repo.folderPath == both.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash)
        #expect(!repo.folderPath.hasSuffix("/"))

        let fork = try makeRepository(in: root, "fork", remotes: [("upstream", "ssh://git@git.example.com/acme/tools.git")])
        let other = try BuildRepository.read(folder: fork, files: files)
        #expect(other.repoArgument == "git.example.com/acme/tools")
    }

    @Test func explainsWhatIsMissing() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(throws: RepositoryError.notARepository) { try BuildRepository.read(folder: plain, files: files) }

        let bare = try makeRepository(in: root, "bare", remotes: [])
        #expect(throws: RepositoryError.noRemote) { try BuildRepository.read(folder: bare, files: files) }

        let local = try makeRepository(in: root, "local", remotes: [("origin", "/srv/git/widget.git")])
        #expect(throws: RepositoryError.unsupportedRemote) { try BuildRepository.read(folder: local, files: files) }

        for error in [RepositoryError.notARepository, .noRemote, .unsupportedRemote, .alreadyAdded] {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("!"))
            #expect(!error.message.lowercased().contains("you"))
        }
    }

    @Test func followsAWorktreeGitFile() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let main = try makeRepository(in: root, "main", remotes: [("origin", "https://github.com/acme/widget")])
        let worktreeGit = main.appending(path: ".git/worktrees/feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/login\n".write(to: worktreeGit.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: worktreeGit.appending(path: "commondir"), atomically: true, encoding: .utf8)
        let checkout = root.appending(path: "feature-checkout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path(percentEncoded: false))\n".write(to: checkout.appending(path: ".git"), atomically: true, encoding: .utf8)

        let repo = try BuildRepository.read(folder: checkout, files: files)
        #expect(repo.slug == "acme/widget")
        #expect(GitFolder.branch(of: checkout, files: files) == "feature/login")
        #expect(GitFolder.branch(of: main, files: files) == "main")
    }

    @Test func followsARelativeGitFile() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let modules = root.appending(path: "parent/.git/modules/child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:acme/child.git\n".write(to: modules.appending(path: "config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/trunk\n".write(to: modules.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let child = root.appending(path: "parent/child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/child\n".write(to: child.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(try BuildRepository.read(folder: child, files: files).slug == "acme/child")
        #expect(GitFolder.branch(of: child, files: files) == "trunk")
    }

    @Test func branchFromHead() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepository(in: root, "repo")
        #expect(GitFolder.branch(of: repo, files: files) == "main")
        try setHead(repo, "ref: refs/heads/release/2.0\n")
        #expect(GitFolder.branch(of: repo, files: files) == "release/2.0")
        try setHead(repo, "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n")
        #expect(GitFolder.branch(of: repo, files: files) == nil)
        try setHead(repo, "ref: refs/remotes/origin/main\n")
        #expect(GitFolder.branch(of: repo, files: files) == nil)
        #expect(GitFolder.branch(of: root.appending(path: "missing"), files: files) == nil)
    }
}

@Suite struct DecoderTests {
    @Test func decodesInventedOutput() throws {
        let json = """
        [
          {"databaseId": 11, "displayTitle": "Add search", "workflowName": "CI", "headBranch": "main", "headSha": "aaa",
           "status": "in_progress", "conclusion": "", "event": "push", "createdAt": "2026-03-01T10:00:00Z",
           "updatedAt": "2026-03-01T10:02:30.250Z", "url": "https://github.com/acme/widget/actions/runs/11"},
          {"databaseId": 10, "displayTitle": "Fix typo", "workflowName": "Lint", "headBranch": "main", "headSha": "bbb",
           "status": "completed", "conclusion": "failure", "event": "pull_request", "createdAt": "2026-03-01T09:00:00Z",
           "updatedAt": "0001-01-01T00:00:00Z", "url": "javascript:alert(1)"},
          {"displayTitle": "No id", "status": "completed"},
          {"databaseId": 9, "status": "queued", "extra": true}
        ]
        """
        let runs = try RunListDecoder.decode(Data(json.utf8))
        #expect(runs.map(\.id) == [11, 10, 9])
        #expect(runs[0].state == .running)
        #expect(runs[0].workflow == "CI")
        #expect(runs[0].commit == "aaa")
        #expect(runs[0].createdAt == Date(timeIntervalSince1970: 1_772_359_200))
        #expect(abs(runs[0].updatedAt.timeIntervalSince(runs[0].createdAt) - 150.25) < 0.01)
        #expect(runs[0].url?.absoluteString == "https://github.com/acme/widget/actions/runs/11")
        #expect(runs[1].state == .failed)
        #expect(runs[1].updatedAt == runs[1].createdAt)  // the zero date reads as unknown
        #expect(runs[1].url == nil)  // only web addresses
        #expect(runs[2].state == .queued)
        #expect(runs[2].workflow.isEmpty)
        #expect(runs[2].createdAt == .distantPast)
    }

    @Test func emptyAndBroken() throws {
        #expect(try RunListDecoder.decode(Data("[]".utf8)).isEmpty)
        #expect(throws: RunListDecoder.Failure.self) { try RunListDecoder.decode(Data("not json".utf8)) }
        #expect(throws: RunListDecoder.Failure.self) { try RunListDecoder.decode(Data("{\"databaseId\": 1}".utf8)) }
    }

    @Test(arguments: [
        ("queued", "", BuildState.queued), ("requested", "", .queued), ("pending", "", .queued),
        ("in_progress", "", .running), ("waiting", "", .waiting), ("action_required", "", .needsApproval),
        ("completed", "success", .passed), ("completed", "failure", .failed), ("completed", "timed_out", .failed),
        ("completed", "startup_failure", .failed), ("completed", "cancelled", .cancelled),
        ("completed", "skipped", .skipped), ("completed", "stale", .skipped), ("completed", "neutral", .finished),
        ("completed", "action_required", .needsApproval), ("something_new", "", .queued),
    ])
    func states(_ status: String, _ conclusion: String, _ state: BuildState) {
        #expect(BuildState(status: status, conclusion: conclusion) == state)
    }

    @Test func labelsFollowTheContentRules() {
        for state in BuildState.allCases {
            #expect(state.label.first?.isUppercase == true)
            #expect(!state.label.contains("!"))
        }
    }
}

@Suite struct SummaryTests {
    private let t0 = Date(timeIntervalSince1970: 1_772_359_200)

    private func run(_ id: Int, sha: String, _ status: String, _ conclusion: String = "", minutes: Double) -> BuildRun {
        BuildRun(id: id, workflow: "W\(id)", branch: "main", commit: sha, status: status, conclusion: conclusion,
                 createdAt: t0.addingTimeInterval(minutes * 60))
    }

    @Test func theNewestCommitSpeaks() {
        let runs = [
            run(1, sha: "old", "completed", "failure", minutes: 0),
            run(2, sha: "new", "completed", "success", minutes: 10),
            run(3, sha: "new", "completed", "skipped", minutes: 11),
        ]
        #expect(BuildSummary.decidingRun(runs)?.id == 2)  // the older failure is history; skipped hides nothing
    }

    @Test func aFailureOrRunningWorkflowOutweighsAPass() {
        let failing = [run(1, sha: "a", "completed", "success", minutes: 2), run(2, sha: "a", "completed", "failure", minutes: 1)]
        #expect(BuildSummary.decidingRun(failing)?.id == 2)
        let running = failing + [run(3, sha: "a", "in_progress", minutes: 0)]
        #expect(BuildSummary.decidingRun(running)?.id == 3)
    }

    @Test func withoutCommitsTheNewestRunSpeaks() {
        let runs = [run(1, sha: "", "completed", "failure", minutes: 0), run(2, sha: "", "completed", "success", minutes: 5)]
        #expect(BuildSummary.decidingRun(runs)?.id == 2)
        #expect(BuildSummary.decidingRun([]) == nil)
    }

    @Test func completionIsReportedOnlyForRunsSeenInFlight() {
        var tracker = CompletionTracker()
        #expect(tracker.observe([run(1, sha: "a", "completed", "success", minutes: 0), run(2, sha: "b", "queued", minutes: 1)]).isEmpty)
        #expect(tracker.observe([run(2, sha: "b", "in_progress", minutes: 1)]).isEmpty)
        #expect(tracker.observe([run(2, sha: "b", "completed", "failure", minutes: 1)]).map(\.id) == [2])
        #expect(tracker.observe([run(2, sha: "b", "completed", "failure", minutes: 1)]).isEmpty)  // reported once
        // A re-run goes back to queued under the same id, and is reported again when it finishes.
        #expect(tracker.observe([run(2, sha: "b", "queued", minutes: 1)]).isEmpty)
        #expect(tracker.observe([run(2, sha: "b", "completed", "success", minutes: 1)]).map(\.id) == [2])
    }

    @Test func rowsPutWorkInFlightFirstThenFailuresThenRecency() {
        func repo(_ name: String) -> BuildRepository {
            BuildRepository(folderPath: "/tmp/\(name)", host: "github.com", owner: "acme", name: name)
        }
        let repos = ["passed-old", "loading", "failed", "passed-new", "problem", "running", "empty"].map(repo)
        func runs(_ status: String, _ conclusion: String = "", minutes: Double) -> FetchOutcome {
            .runs([run(Int(minutes), sha: "x", status, conclusion, minutes: minutes)], branch: "main")
        }
        let outcomes: [String: FetchOutcome] = [
            "/tmp/passed-old": runs("completed", "success", minutes: 1),
            "/tmp/failed": runs("completed", "failure", minutes: 2),
            "/tmp/passed-new": runs("completed", "success", minutes: 5),
            "/tmp/problem": .problem(.notFound),
            "/tmp/running": runs("in_progress", minutes: 0),
            "/tmp/empty": .runs([], branch: nil),
        ]
        let rows = BuildBoard.rows(repositories: repos, outcomes: outcomes)
        #expect(rows.map(\.repository.name) == ["running", "failed", "passed-new", "passed-old", "loading", "problem", "empty"])
        #expect(rows[4].content == .loading)
        #expect(rows[5].content == .problem(.notFound))
        #expect(rows[6].content == .noRuns)
        #expect(rows[0].checkedOutBranch == "main")
        #expect(BuildBoard.hasActiveRuns(outcomes.values))
        #expect(!BuildBoard.hasActiveRuns([outcomes["/tmp/failed"]!]))
    }
}

@Suite struct GitHubCLITests {
    private let dotCom = BuildRepository(folderPath: "/tmp/w", host: "github.com", owner: "acme", name: "widget")
    private let enterprise = BuildRepository(folderPath: "/tmp/e", host: "git.example.com", owner: "acme", name: "tools")

    @Test func locatesOnlyTheKnownPlaces() {
        #expect(GitHubCLI.locate { _ in false } == nil)
        #expect(GitHubCLI.locate { $0 == "/usr/local/bin/gh" }?.path == "/usr/local/bin/gh")
        #expect(GitHubCLI.locate { _ in true }?.path == "/opt/homebrew/bin/gh")
        #expect(GitHubCLI.candidates == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])
    }

    @Test func arguments() {
        #expect(GitHubCLI.arguments(for: dotCom, branch: "feature/x") == [
            "run", "list", "--repo=acme/widget", "--branch=feature/x", "--limit=5",
            "--json=databaseId,displayTitle,workflowName,headBranch,headSha,status,conclusion,event,createdAt,updatedAt,url",
        ])
        let anyBranch = GitHubCLI.arguments(for: enterprise, branch: nil)
        #expect(anyBranch.contains("--repo=git.example.com/acme/tools"))
        #expect(!anyBranch.contains { $0.hasPrefix("--branch") })
        // A branch that looks like a flag stays the flag's value.
        #expect(GitHubCLI.arguments(for: dotCom, branch: "--help").contains("--branch=--help"))
    }

    @Test func environmentKeepsTheAppsAndQuietsGh() {
        let env = GitHubCLI.environment(base: ["HOME": "/Users/example", "NO_COLOR": "0"])
        #expect(env == ["HOME": "/Users/example", "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
    }

    @Test func interpretsResults() {
        let ok = CommandResult(status: 0, stdout: Data(RunJSON.array([RunJSON(id: 3, conclusion: "success")]).utf8))
        #expect((try? GitHubCLI.interpret(ok).get())?.map(\.id) == [3])
        let signedOut = CommandResult(status: 4, stderr: Data("To get started with GitHub CLI, please run:  gh auth login\n".utf8))
        #expect(GitHubCLI.interpret(signedOut) == .failure(.signedOut))
        let notFound = CommandResult(status: 1, stderr: Data("GraphQL: Could not resolve to a Repository with the name 'acme/gone'.".utf8))
        #expect(GitHubCLI.interpret(notFound) == .failure(.notFound))
        #expect(GitHubCLI.interpret(CommandResult(status: 1, stderr: Data("HTTP 404: Not Found".utf8))) == .failure(.notFound))
        #expect(GitHubCLI.interpret(CommandResult(status: 0, stdout: Data("[]".utf8), timedOut: true)) == .failure(.timedOut))
        #expect(GitHubCLI.interpret(CommandResult(status: 0, stdout: Data("Usage: gh".utf8))) == .failure(.unreadable))
        #expect(GitHubCLI.interpret(CommandResult(status: 1, stderr: Data("HTTP 502".utf8))) == .failure(.failed))
        #expect(GitHubCLI.interpret(CommandResult(status: -1)) == .failure(.failed))
    }

    @Test func problemMessagesFollowTheContentRules() {
        for problem in [RepositoryProblem.signedOut, .notFound, .timedOut, .unreadable, .failed] {
            let text = problem.message(host: "github.com")
            #expect(!text.contains("!"))
            #expect(!text.lowercased().split(separator: " ").contains("you"))
            #expect(text.first?.isUppercase == true)
        }
    }

    @Test func fetchesTheBranchThenAnyBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "builds-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRepository(in: root, "widget", head: "ref: refs/heads/topic\n")
        let repo = try BuildRepository.read(folder: folder, files: DiskRepositoryFiles())
        let gh = FakeGitHub()
        let fetcher = RunFetcher(executable: URL(filePath: "/opt/homebrew/bin/gh"), runner: gh.runner, files: DiskRepositoryFiles(), environment: [:])

        gh.runs("acme/widget", [RunJSON(id: 7, branch: "main", conclusion: "success")])
        let fallback = await fetcher.fetch(repo)
        #expect(gh.calls.map { FakeGitHub.key($0.arguments) } == ["acme/widget|topic", "acme/widget|-"])
        guard case .runs(let runs, let branch) = fallback else { Issue.record("expected runs"); return }
        #expect(runs.map(\.id) == [7])
        #expect(branch == "topic")

        gh.runs("acme/widget", branch: "topic", [RunJSON(id: 8, branch: "topic", status: "queued")])
        _ = await fetcher.fetch(repo)
        #expect(gh.calls.count == 3)  // one call when the branch has runs

        try setHead(folder, "0123456789abcdef0123456789abcdef01234567\n")
        _ = await fetcher.fetch(repo)
        #expect(gh.calls.count == 4)
        #expect(gh.calls.last.map { FakeGitHub.key($0.arguments) } == "acme/widget|-")  // detached: any branch only

        gh.answer("acme/widget", CommandResult(status: 4))
        #expect(await fetcher.fetch(repo) == .problem(.signedOut))
    }
}

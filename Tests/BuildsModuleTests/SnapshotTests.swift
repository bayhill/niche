import Foundation
import NotchCore
import NotchCoreTesting
import Testing
@testable import BuildsModule

/// Writes the page in each state to $TMPDIR/niche-snapshots for visual review.
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "niche-snapshots", directoryHint: .isDirectory)

    private func write(_ module: BuildsModule, _ name: String) throws {
        let url = try ViewSnapshot.write(
            BuildsPage(module: module, scrolls: false), size: PanelLayout.pageSize, to: Self.dir.appending(path: "\(name).png")
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A module on fakes, started, with the given repositories and answers, after its first pass.
    private func module(
        _ env: TestEnvironment, installed: Bool = true, repositories: [String] = [], answer: (FakeGitHub) -> Void = { _ in }
    ) async throws -> BuildsModule {
        let gh = FakeGitHub()
        answer(gh)
        let sleeper = ManualSleeper()
        let module = BuildsModule(
            runner: gh.runner, isExecutable: { _ in installed }, environment: [:],
            sleep: { try await sleeper.sleep($0) }, openURL: { _ in }, chooseFolder: { nil }
        )
        await module.start(env.context(for: .builds))
        for name in repositories {
            module.addRepository(at: try makeRepository(in: env.root, name, remotes: [("origin", "git@github.com:acme/\(name).git")]))
        }
        await waitUntil { sleeper.pending == 1 && !module.isFetching && module.lastFetched != nil }
        return module
    }

    @Test func pages() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.services.openSettings = { _ in }

        let sample = BuildsModule.sample()
        await sample.start(env.context(for: .builds))
        try write(sample, "builds-sample")

        let empty = try await module(env)
        try write(empty, "builds-empty")
        empty.stop()

        let missing = try await module(env, installed: false, repositories: ["widget"])
        try write(missing, "builds-gh-missing")
        missing.stop()
        env.settings.reset(BuildsModule.repositoriesKey)

        let signedOut = try await module(env, repositories: ["portal"]) { gh in
            gh.answer("acme/portal", branch: "main", CommandResult(status: 4))
        }
        try write(signedOut, "builds-signed-out")
        signedOut.stop()
        env.settings.reset(BuildsModule.repositoriesKey)

        let mixed = try await module(env, repositories: ["gateway", "archive", "notes", "ledger"]) { gh in
            gh.runs("acme/gateway", branch: "main", [RunJSON(id: 1, workflow: "Build and test", status: "queued").ago(started: 1)])
            gh.answer("acme/archive", branch: "main", CommandResult(status: 1, stderr: Data("HTTP 404: Not Found".utf8)))
            gh.runs("acme/ledger", [RunJSON(id: 2, workflow: "Nightly", branch: "a-very-long-branch-name/for-testing-truncation",
                                            status: "completed", conclusion: "action_required").ago(started: 40, changed: 38)])
        }
        try write(mixed, "builds-mixed")
        mixed.stop()
        env.settings.reset(BuildsModule.repositoriesKey)

        let many = try await module(env, repositories: (1...7).map { "service-\($0)" }) { gh in
            for i in 1...7 {
                let run = RunJSON(id: i, workflow: "CI", conclusion: i == 3 ? "failure" : "success")
                gh.runs("acme/service-\(i)", branch: "main", [run.ago(started: Double(i * 17), changed: Double(i * 15))])
            }
        }
        try write(many, "builds-many")
        many.stop()

        print("snapshots in \(Self.dir.path)")
    }
}

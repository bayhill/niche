import Foundation
import NotchCore
import NotchCoreTesting
import Synchronization
import Testing
@testable import BuildsModule

/// A module wired to fakes: scripted gh, a hand-driven sleep and clock, a recording opener.
@MainActor
private final class Harness {
    let env: TestEnvironment
    let gh = FakeGitHub()
    let sleeper = ManualSleeper()
    let clock = TestClock()
    let installed = Installed(true)
    let browser = Browser()
    let module: BuildsModule

    @MainActor final class Browser {
        var opened: [URL] = []
        var chosen: URL?
    }

    var opened: [URL] { browser.opened }
    var chosen: URL? {
        get { browser.chosen }
        set { browser.chosen = newValue }
    }

    init(activity: Duration = .seconds(60), environment: [String: String] = ["HOME": "/Users/example"]) throws {
        env = try TestEnvironment()
        let sleeper = sleeper, clock = clock, installed = installed, browser = browser
        module = BuildsModule(
            runner: gh.runner,
            files: DiskRepositoryFiles(),
            isExecutable: { $0 == "/opt/homebrew/bin/gh" && installed.on },
            environment: environment,
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            openURL: { browser.opened.append($0) },
            chooseFolder: { browser.chosen },
            activityDuration: activity
        )
    }

    /// A repository folder whose origin is `acme/<name>`, on `branch`, added through the module; a host other than
    /// github.com is confirmed the way Settings does it.
    @discardableResult
    func add(_ name: String, branch: String = "main", host: String = "github.com") throws -> URL {
        let folder = try makeRepository(in: env.root, name, remotes: [("origin", "git@\(host):acme/\(name).git")], head: "ref: refs/heads/\(branch)\n")
        if host == "github.com" {
            #expect(module.addRepository(at: folder))
        } else {
            #expect(!module.addRepository(at: folder))
            #expect(module.pendingRepository?.host == host)
            module.confirmPendingRepository()
        }
        return folder
    }

    func start() async {
        await module.start(env.context(for: .builds))
    }

    /// Waits for the refresh loop to finish a pass and go to sleep.
    func waitForSleep(_ count: Int = 1) async {
        await waitUntil { sleeper.pending == 1 && sleeper.requested.count >= count }
    }

    /// Ends the current wait; the loop refreshes again and goes back to sleep.
    func nextRefresh() async {
        let before = sleeper.requested.count
        sleeper.wake()
        await waitForSleep(before + 1)
    }

    func cleanUp() { module.stop(); env.cleanUp() }
}

@MainActor @Suite struct BuildsModuleTests {
    @Test func isAPage() {
        let module = BuildsModule.sample()
        #expect(module.id == .builds)
        #expect(module.title == "Builds")
        #expect(module.symbol == "hammer")
        #expect(module.placement == .page(order: 60))
    }

    @Test func sampleShowsInventedRowsAndTouchesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = BuildsModule.sample()
        await module.start(env.context(for: .builds))
        #expect(module.status == .ready)
        #expect(module.rows.map(\.repository.slug) == ["acme/api", "acme/docs", "acme/storefront", "acme/mobile"])
        #expect(module.rows.map(\.state) == [.running, .failed, .passed, .cancelled])
        #expect(module.rows.allSatisfy { $0.repository.folderPath.hasPrefix("/Users/example/") })
        #expect(module.liveActivity == nil)
        #expect(!module.addRepository(at: env.root))
        #expect(env.settings.get(BuildsModule.repositoriesKey).isEmpty)
        module.refreshNow()
        module.pageAppeared()
        #expect(!module.isFetching)
        module.stop()
    }

    @Test func noRepositoriesPointsToSettings() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        #expect(h.module.status == .noRepositories)
        #expect(h.module.settingsView() == nil)  // no settings before start
        #expect(!h.module.canOpenSettings)
        var opened: [ModuleID?] = []
        h.env.services.openSettings = { opened.append($0) }
        await h.start()
        await h.waitForSleep()
        #expect(h.module.status == .noRepositories)
        #expect(h.module.canOpenSettings)
        #expect(h.module.settingsView() != nil)
        #expect(h.gh.calls.isEmpty)
        #expect(h.sleeper.requested == [.seconds(300)])
        h.module.openSettings()
        #expect(opened == [.builds])
    }

    @Test func fetchesEachRepositoryOnItsBranchWithAQuietEnvironment() async throws {
        let h = try Harness(environment: [
            "HOME": "/Users/example", "GH_ENTERPRISE_TOKEN": "invented-1", "GITHUB_ENTERPRISE_TOKEN": "invented-2",
            "GH_HOST": "git.example.org",
        ]); defer { h.cleanUp() }
        await h.start()
        try h.add("widget", branch: "feature/login")
        try h.add("tools", host: "git.example.com")
        h.gh.runs("acme/widget", branch: "feature/login", [RunJSON(id: 1, branch: "feature/login", conclusion: "success")])
        h.gh.runs("git.example.com/acme/tools", branch: "main", [RunJSON(id: 2, conclusion: "failure")])
        await h.waitForSleep()
        await waitUntil { h.module.rows.allSatisfy { $0.run != nil } }

        let keys = Set(h.gh.calls.map { FakeGitHub.key($0.arguments) })
        #expect(keys.isSuperset(of: ["acme/widget|feature/login", "git.example.com/acme/tools|main"]))
        for call in h.gh.calls {
            #expect(call.executable.path == "/opt/homebrew/bin/gh")
            #expect(call.environment == ["HOME": "/Users/example", "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
            #expect(call.arguments.contains("--limit=5"))
        }
        #expect(h.module.status == .ready)
        #expect(h.module.rows.map(\.repository.name) == ["tools", "widget"])  // the failure first
        #expect(h.module.rows.map(\.state) == [.failed, .passed])
        #expect(h.module.lastFetched == h.clock.now)
        #expect(!h.module.isFetching)
    }

    @Test func ghMissingHasItsOwnStateAndIsLookedForAgain() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        h.installed.on = false
        await h.start()
        try h.add("widget")
        await h.waitForSleep()
        #expect(h.module.status == .ghMissing)
        #expect(h.gh.calls.isEmpty)

        h.installed.on = true
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, conclusion: "success")])
        h.module.refreshNow()
        await waitUntil { h.module.status == .ready && h.module.rows.first?.run != nil }
        #expect(h.module.rows.first?.state == .passed)
    }

    @Test func signedOutEverywhereIsOneState() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        try h.add("tools")
        let signedOut = CommandResult(status: 4, stderr: Data("To get started with GitHub CLI, please run:  gh auth login".utf8))
        for repo in ["acme/widget", "acme/tools"] { h.gh.answer(repo, branch: "main", signedOut) }
        await waitUntil { h.module.status == .signedOut }
        #expect(h.module.status == .signedOut)

        // Signed in on one host only: the other repository's row says so quietly.
        h.gh.runs("acme/tools", branch: "main", [RunJSON(id: 3, conclusion: "success")])
        await h.waitForSleep()
        await h.nextRefresh()
        #expect(h.module.status == .ready)
        let widget = h.module.rows.first { $0.repository.name == "widget" }
        #expect(widget?.content == .problem(.signedOut))
    }

    @Test func aFailingRepositoryKeepsItsRowAndIsTriedAgain() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        try h.add("gone")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, conclusion: "success")])
        h.gh.answer("acme/gone", branch: "main", CommandResult(status: 1, stderr: Data("HTTP 404: Not Found".utf8)))
        await h.waitForSleep()
        await waitUntil { h.module.rows.contains { $0.content == .problem(.notFound) } }
        #expect(h.module.rows.map(\.repository.name) == ["widget", "gone"])
        #expect(h.module.rows.last?.content == .problem(.notFound))

        h.gh.runs("acme/gone", branch: "main", [RunJSON(id: 2, conclusion: "cancelled")])
        await h.nextRefresh()
        #expect(h.module.rows.first { $0.repository.name == "gone" }?.state == .cancelled)
        #expect(h.gh.calls.filter { FakeGitHub.key($0.arguments) == "acme/gone|main" }.count >= 2)
    }

    @Test func refreshesSoonerWhileARunIsInFlight() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        await h.waitForSleep()
        try h.add("widget")  // restarts the loop: the first wait is cancelled, a fresh pass runs
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, status: "in_progress")])
        await waitUntil { h.module.rows.first?.state == .running && h.sleeper.pending == 1 }
        #expect(h.sleeper.requested.last == .seconds(60))

        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, conclusion: "success")])
        await h.nextRefresh()
        #expect(h.sleeper.requested.last == .seconds(300))
        #expect(h.sleeper.pending == 1)
    }

    @Test func aRunSeenInFlightAnnouncesItsResult() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, workflow: "Test", status: "queued")])
        await waitUntil { h.module.rows.first?.state == .queued && h.sleeper.pending == 1 }
        #expect(h.module.liveActivity == nil)

        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, workflow: "Test", conclusion: "success")])
        h.clock.advance(60)
        await h.nextRefresh()
        let activity = try #require(h.module.liveActivity)
        #expect(activity.id == "builds.finished")
        #expect(activity.module == .builds)
        #expect(activity.priority == .passive)
        #expect(activity.leading == .symbol("checkmark.circle.fill", tint: .success))
        #expect(activity.leadingText == "widget")
        #expect(activity.trailingText == "Passed")
        #expect(activity.expiresAt == h.clock.now.addingTimeInterval(60))
        #expect(activity.accessibilityLabel == "Test passed in acme/widget")
        #expect(h.module.announcedRepositoryID == h.module.rows.first?.id)

        h.env.settings.set(BuildsModule.showBesideNotchKey, false)
        #expect(h.module.liveActivity == nil)
    }

    @Test func aFailureShowsACross() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 5, status: "in_progress")])
        await waitUntil { h.module.rows.first?.state == .running && h.sleeper.pending == 1 }
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 5, conclusion: "failure")])
        await h.nextRefresh()
        #expect(h.module.liveActivity?.leading == .symbol("xmark.circle.fill", tint: .warning))
        #expect(h.module.liveActivity?.trailingText == "Failed")
    }

    @Test func runsAlreadyFinishedWhenFirstSeenAreNotAnnounced() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, conclusion: "failure")])
        await waitUntil { h.module.rows.first?.state == .failed && h.sleeper.pending == 1 }
        await h.nextRefresh()
        #expect(h.module.liveActivity == nil)
    }

    @Test func theNoteLeavesAfterItsTime() async throws {
        let h = try Harness(activity: .milliseconds(50)); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, status: "in_progress")])
        await waitUntil { h.module.rows.first?.state == .running && h.sleeper.pending == 1 }
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, conclusion: "success")])
        await h.nextRefresh()
        #expect(h.module.liveActivity != nil)
        await waitUntil { h.module.liveActivity == nil }
        #expect(h.module.liveActivity == nil)
    }

    @Test func showingThePageRefreshesOnlyWhenStale() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        await waitUntil { h.module.rows.first?.content == .noRuns && h.sleeper.pending == 1 }
        let calls = h.gh.calls.count

        h.clock.advance(20)
        h.module.pageAppeared()
        await settle()
        #expect(h.gh.calls.count == calls)

        h.clock.advance(15)
        h.module.pageAppeared()
        await waitUntil { h.gh.calls.count > calls && h.sleeper.pending == 1 }
        #expect(h.gh.calls.count > calls)
        #expect(h.module.lastFetched == h.clock.now)
    }

    @Test func stopCancelsEverything() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 1, status: "in_progress")])
        await waitUntil { h.module.rows.first?.state == .running && h.sleeper.pending == 1 }
        h.module.stop()
        await waitUntil { h.sleeper.pending == 0 }
        #expect(h.sleeper.pending == 0)
        let calls = h.gh.calls.count
        h.sleeper.wake()
        h.module.pageAppeared()
        h.module.refreshNow()
        await settle()
        #expect(h.gh.calls.count == calls)
        #expect(h.module.liveActivity == nil)

        // Start again resumes.
        await h.start()
        await waitUntil { h.gh.calls.count > calls }
        #expect(h.gh.calls.count > calls)
    }

    @Test func aClickOpensTheRun() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        try h.add("widget")
        h.gh.runs("acme/widget", branch: "main", [RunJSON(id: 42, conclusion: "success")])
        await waitUntil { h.module.rows.first?.run != nil }
        let row = try #require(h.module.rows.first)
        h.module.open(row)
        #expect(h.opened.map(\.absoluteString) == ["https://github.com/acme/widget/actions/runs/42"])
        h.module.open(BuildRow(repository: row.repository, content: .noRuns))
        #expect(h.opened.count == 1)
    }

    @Test func addingAndRemovingRepositories() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        let folder = try h.add("widget")
        let stored = h.env.settings.get(BuildsModule.repositoriesKey)
        #expect(stored.map(\.slug) == ["acme/widget"])
        #expect(stored.first?.host == "github.com")

        #expect(!h.module.addRepository(at: folder))
        #expect(h.module.addError == .alreadyAdded)

        let plain = h.env.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!h.module.addRepository(at: plain))
        #expect(h.module.addError == .notARepository)

        let bare = try makeRepository(in: h.env.root, "bare", remotes: [])
        h.chosen = bare
        await h.module.chooseRepository()
        #expect(h.module.addError == .noRemote)

        h.chosen = try makeRepository(in: h.env.root, "tools", remotes: [("origin", "https://github.com/acme/tools")])
        await h.module.chooseRepository()
        #expect(h.module.addError == nil)
        #expect(h.module.repositories.map(\.slug) == ["acme/widget", "acme/tools"])

        h.chosen = nil
        await h.module.chooseRepository()  // cancelled panel
        #expect(h.module.repositories.count == 2)

        let widget = try #require(h.module.repositories.first)
        h.module.removeRepository(widget)
        #expect(h.env.settings.get(BuildsModule.repositoriesKey).map(\.slug) == ["acme/tools"])
        #expect(h.module.rows.map(\.repository.slug) == ["acme/tools"])
    }

    @Test func anotherHostIsAddedOnlyOnceConfirmed() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        await h.waitForSleep()
        let folder = try makeRepository(in: h.env.root, "tools", remotes: [("origin", "https://git.example.org/acme/tools.git")])

        // Picked, then declined: nothing stored, gh never pointed at the host.
        h.chosen = folder
        await h.module.chooseRepository()
        #expect(h.module.pendingRepository?.repoArgument == "git.example.org/acme/tools")
        #expect(h.module.addError == nil)
        #expect(h.env.settings.get(BuildsModule.repositoriesKey).isEmpty)
        h.module.cancelPendingRepository()
        #expect(h.module.pendingRepository == nil)
        #expect(h.env.settings.get(BuildsModule.repositoriesKey).isEmpty)
        await h.nextRefresh()
        #expect(h.gh.calls.isEmpty)

        // Picked again and confirmed: stored with the host it was confirmed for, then fetched.
        #expect(!h.module.addRepository(at: folder))
        h.gh.runs("git.example.org/acme/tools", branch: "main", [RunJSON(id: 5, conclusion: "success")])
        h.module.confirmPendingRepository()
        let stored = h.env.settings.get(BuildsModule.repositoriesKey)
        #expect(stored.map(\.confirmedHost) == ["git.example.org"])
        #expect(stored.first?.mayFetch == true)
        await waitUntil { h.module.rows.first?.run != nil }
        #expect(h.gh.calls.map { FakeGitHub.key($0.arguments) }.contains("git.example.org/acme/tools|main"))
        #expect(h.module.rows.first?.state == .passed)

        // github.com needs no question.
        #expect(h.module.addRepository(at: try makeRepository(in: h.env.root, "widget")))
        #expect(h.module.pendingRepository == nil)
    }

    @Test func storedEntriesThatWereNeverConfirmedAreNotFetched() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        let folder = try makeRepository(in: h.env.root, "tools", remotes: [("origin", "https://git.example.org/acme/tools.git")])
        let path = folder.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash
        // As if the preferences had been edited by hand.
        let unconfirmed = BuildRepository(folderPath: path, host: "git.example.org", owner: "acme", name: "tools")
        let otherHost = BuildRepository(folderPath: h.env.root.path + "/moved", host: "evil.example", owner: "acme", name: "tools", confirmedHost: "git.example.org")
        let malformed = BuildRepository(folderPath: h.env.root.path + "/odd", host: "github.com", owner: "--help", name: "tools")
        let fine = BuildRepository(folderPath: h.env.root.path + "/fine", host: "github.com", owner: "acme", name: "widget")
        h.env.settings.set(BuildsModule.repositoriesKey, [unconfirmed, otherHost, malformed, fine])
        await h.start()
        await h.waitForSleep()
        await waitUntil { h.module.rows.allSatisfy { $0.content != .loading } }

        #expect(h.gh.calls.map { FakeGitHub.key($0.arguments) } == ["acme/widget|-"])
        let content = Dictionary(uniqueKeysWithValues: h.module.rows.map { ($0.id, $0.content) })
        #expect(content[unconfirmed.id] == .problem(.hostNotConfirmed))
        #expect(content[otherHost.id] == .problem(.hostNotConfirmed))
        #expect(content[malformed.id] == .problem(.invalidEntry))
        #expect(content[fine.id] == .noRuns)

        // Settings can ask about a well-formed entry; a malformed one can only be removed.
        h.module.reviewHost(of: malformed)
        #expect(h.module.pendingRepository == nil)
        h.module.reviewHost(of: fine)
        #expect(h.module.pendingRepository == nil)
        h.module.reviewHost(of: unconfirmed)
        #expect(h.module.pendingRepository == unconfirmed)
        h.module.confirmPendingRepository()
        let stored = h.env.settings.get(BuildsModule.repositoriesKey)
        #expect(stored.count == 4)  // updated in place, not added twice
        #expect(stored.first { $0.id == unconfirmed.id }?.confirmedHost == "git.example.org")
        await waitUntil { h.gh.calls.contains { FakeGitHub.key($0.arguments) == "git.example.org/acme/tools|main" } }
        #expect(h.gh.calls.contains { FakeGitHub.key($0.arguments) == "git.example.org/acme/tools|main" })
        #expect(!h.gh.calls.contains { $0.arguments.contains { $0.contains("evil.example") || $0.contains("--help") } })
    }

    @Test func entriesStoredBeforeConfirmationExistedDecodeAsUnconfirmed() throws {
        let json = #"[{"folderPath":"/tmp/a","host":"git.example.org","owner":"acme","name":"tools"},"#
            + #"{"folderPath":"/tmp/b","host":"github.com","owner":"acme","name":"widget"}]"#
        let decoded = try JSONDecoder().decode([BuildRepository].self, from: Data(json.utf8))
        #expect(decoded.map(\.confirmedHost) == [nil, nil])
        #expect(decoded.map(\.mayFetch) == [false, true])
        // And a confirmation survives a round trip.
        var confirmed = decoded[0]
        confirmed.confirmedHost = "git.example.org"
        let again = try JSONDecoder().decode(BuildRepository.self, from: JSONEncoder().encode(confirmed))
        #expect(again.mayFetch)
    }

    @Test func removingAPendingRepositoryForgetsTheQuestion() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        let pending = BuildRepository(folderPath: h.env.root.path + "/x", host: "git.example.org", owner: "acme", name: "x")
        h.env.settings.set(BuildsModule.repositoriesKey, [pending])
        h.module.reviewHost(of: pending)
        h.module.removeRepository(pending)
        #expect(h.module.pendingRepository == nil)
        h.module.confirmPendingRepository()
        #expect(h.env.settings.get(BuildsModule.repositoriesKey).isEmpty)
    }

    @Test func theBranchIsReadAtEachRefresh() async throws {
        let h = try Harness(); defer { h.cleanUp() }
        await h.start()
        let folder = try h.add("widget")
        await waitUntil { h.sleeper.pending == 1 && h.module.rows.first?.content == .noRuns }
        #expect(h.gh.calls.contains { FakeGitHub.key($0.arguments) == "acme/widget|main" })

        try setHead(folder, "ref: refs/heads/topic\n")
        h.gh.runs("acme/widget", branch: "topic", [RunJSON(id: 9, branch: "topic", conclusion: "success")])
        await h.nextRefresh()
        #expect(h.gh.calls.last.map { FakeGitHub.key($0.arguments) } == "acme/widget|topic")
        #expect(h.module.rows.first?.checkedOutBranch == "topic")
        #expect(h.module.rows.first?.run?.branch == "topic")
    }
}

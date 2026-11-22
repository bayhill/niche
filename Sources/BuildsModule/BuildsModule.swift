import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// The latest GitHub Actions runs for chosen repositories, through the user's own `gh` login.
///
/// The module holds no credentials: it runs the GitHub CLI the user already signed in to, never installs it and
/// never signs in. Repositories are folders picked in Settings; the branch checked out in each is read from its
/// `.git` folder at every refresh.
@MainActor
@Observable
public final class BuildsModule: NotchModule {
    /// The folders picked in Settings, with the GitHub repository each one's remote names.
    public static let repositoriesKey = SettingsKey<[BuildRepository]>("builds.repositories", default: [])
    /// Show a note beside the notch when a run seen queued or running this session finishes.
    public static let showBesideNotchKey = SettingsKey<Bool>("builds.showBesideNotch", default: true)
    static let activityID = "builds.finished"

    public let id: ModuleID = .builds
    public let title = "Builds"
    public let symbol = "hammer"
    public let placement: PanelPlacement = .page(order: 60)

    public enum Status: Sendable, Equatable {
        /// Nothing picked yet: the page points to Settings.
        case noRepositories
        /// gh is in none of the places it is looked for.
        case ghMissing
        /// gh has no sign-in for any of the repositories' hosts.
        case signedOut
        /// Rows, each with a run, a quiet problem, or loading.
        case ready
    }

    public var status: Status {
        let repositories = repositories
        if repositories.isEmpty { return .noRepositories }
        if ghMissing { return .ghMissing }
        if repositories.allSatisfy({ outcomes[$0.id] == .problem(.signedOut) }) { return .signedOut }
        return .ready
    }

    /// The page's rows: work in flight first, then failures, then by recency.
    public var rows: [BuildRow] { BuildBoard.rows(repositories: repositories, outcomes: outcomes) }

    /// In the order they were added.
    public var repositories: [BuildRepository] {
        fixtureRepositories ?? settings?.get(Self.repositoriesKey) ?? []
    }

    /// When the last refresh finished; `nil` before one.
    public private(set) var lastFetched: Date?
    public private(set) var isFetching = false
    /// Why the last folder picked in Settings was not added; cleared by the next success.
    public private(set) var addError: RepositoryError?
    /// A folder whose remote names a host other than github.com, waiting for the user to confirm that host in
    /// Settings. It is not stored, and gh is not run for it, until `confirmPendingRepository()`.
    public private(set) var pendingRepository: BuildRepository?
    /// True when the app can open Settings on this module's pane.
    public var canOpenSettings: Bool { context?.services.openSettings != nil }

    public var liveActivity: LiveActivity? {
        guard let announcement, settings?.get(Self.showBesideNotchKey) ?? Self.showBesideNotchKey.defaultValue else { return nil }
        let state = announcement.run.state
        let glyph = Self.finishedGlyph(state)
        return LiveActivity(
            id: Self.activityID, module: .builds, priority: .passive,
            leading: .symbol(glyph.symbol, tint: glyph.tint),
            leadingText: announcement.repository.name, trailingText: state.label,
            expiresAt: announcement.at.addingTimeInterval(Self.seconds(activityDuration)),
            updatedAt: announcement.at,
            accessibilityLabel: "\(announcement.run.workflow) \(state.label.lowercased()) in \(announcement.repository.slug)"
        )
    }

    /// The repository whose run is beside the notch, if any; its status mark is the hero.
    var announcedRepositoryID: String? { announcement?.repository.id }

    private var outcomes: [String: FetchOutcome] = [:]
    private var ghMissing = false
    private var announcement: Announcement?
    private var settings: SettingsStore?
    private var context: ModuleContext?

    @ObservationIgnored private let runner: any CommandRunning
    @ObservationIgnored private let files: any RepositoryFileReading
    @ObservationIgnored private let isExecutable: @Sendable (String) -> Bool
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: (@Sendable (Duration) async throws -> Void)?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let chooseFolder: @MainActor () async -> URL?
    @ObservationIgnored private let activeInterval: Duration
    @ObservationIgnored private let idleInterval: Duration
    @ObservationIgnored private let staleAfter: TimeInterval
    @ObservationIgnored private let activityDuration: Duration
    /// Fixture mode: sample rows, no commands, no files, no settings writes.
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private let fixtureRepositories: [BuildRepository]?
    @ObservationIgnored private var log: Logger?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var tracker = CompletionTracker()
    /// Bumped by every refresh and by `stop`; a refresh whose number is no longer current drops its results.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    /// - Parameters:
    ///   - runner: runs gh (`ProcessCommandRunner` in the app).
    ///   - files: reads `.git` metadata.
    ///   - isExecutable: whether a candidate path for gh exists and can be run.
    ///   - environment: the app's environment, handed to gh with its quiet flags added.
    ///   - now: clock for staleness and the live activity.
    ///   - sleep: waits between refreshes; tests hand in one they control.
    ///   - openURL: opens a run in the browser.
    ///   - chooseFolder: asks for a repository folder (an `NSOpenPanel` in the app).
    ///   - activeInterval: time between refreshes while a run is queued or in progress.
    ///   - idleInterval: time between refreshes otherwise.
    ///   - staleAfter: seconds after which showing the page refreshes at once.
    ///   - activityDuration: how long a finished run stays beside the notch.
    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        files: any RepositoryFileReading = DiskRepositoryFiles(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        chooseFolder: @escaping @MainActor () async -> URL? = BuildsModule.chooseFolderWithPanel,
        activeInterval: Duration = .seconds(60),
        idleInterval: Duration = .seconds(300),
        staleAfter: TimeInterval = 30,
        activityDuration: Duration = .seconds(8)
    ) {
        self.runner = runner; self.files = files; self.isExecutable = isExecutable; self.environment = environment
        self.now = now; self.sleep = sleep; self.openURL = openURL; self.chooseFolder = chooseFolder
        self.activeInterval = activeInterval; self.idleInterval = idleInterval; self.staleAfter = staleAfter
        self.activityDuration = activityDuration
        self.isFixture = false
        self.fixtureRepositories = nil
    }

    private init(fixture repositories: [BuildRepository], outcomes: [String: FetchOutcome], now: Date) {
        runner = ScriptlessRunner()
        files = NoRepositoryFiles()
        isExecutable = { _ in false }
        environment = [:]
        self.now = { Date() }
        sleep = nil
        openURL = { _ in }
        chooseFolder = { nil }
        activeInterval = .seconds(60); idleInterval = .seconds(300); staleAfter = 30; activityDuration = .seconds(8)
        isFixture = true
        fixtureRepositories = repositories
        self.outcomes = outcomes
        lastFetched = now
    }

    /// The module the app runs: the user's gh, the real `.git` folders, the browser.
    public static func live() -> BuildsModule { BuildsModule() }

    /// Invented repositories and runs, already showing. Runs no command and reads no file.
    public static func sample() -> BuildsModule {
        let now = Date()
        let (repositories, outcomes) = BuildsSamples.make(now: now)
        return BuildsModule(fixture: repositories, outcomes: outcomes, now: now)
    }

    /// Asks for a folder with an open panel.
    public static func chooseFolderWithPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose the folder of a Git repository with a GitHub remote."
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        self.context = context
        settings = context.settings
        log = context.log
        if !isFixture { restartLoop() }
        context.log.notice("started")
    }

    /// Cancels the refresh loop and the note beside the notch. `start` on the same instance resumes.
    public func stop() {
        running = false
        generation += 1
        loopTask?.cancel(); loopTask = nil
        announceTask?.cancel(); announceTask = nil
        announcement = nil
        isFetching = false
    }

    // MARK: Refreshing

    /// The page came into view: refresh now when the last refresh is older than `staleAfter`.
    public func pageAppeared() {
        guard running, !isFixture, !isFetching else { return }
        if let lastFetched, now().timeIntervalSince(lastFetched) <= staleAfter { return }
        restartLoop()
    }

    /// Refresh now, then carry on with the usual rhythm.
    public func refreshNow() {
        guard running, !isFixture else { return }
        restartLoop()
    }

    /// Fetches at once, then every `activeInterval` while a run is in flight, otherwise every `idleInterval`.
    private func restartLoop() {
        loopTask?.cancel()
        let sleep = self.sleep
        loopTask = Task { [weak self] in
            var wait: Duration?
            while !Task.isCancelled {
                if let wait {
                    do { try await RealClock.sleep(wait, using: sleep) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                wait = BuildBoard.hasActiveRuns(self.outcomes.values) ? self.activeInterval : self.idleInterval
            }
        }
    }

    /// One pass over every repository, in parallel. A repository that fails keeps its row with a quiet problem.
    func refresh() async {
        guard !isFixture, let settings else { return }
        generation += 1
        let current = generation
        // Only the newest refresh speaks for `isFetching`; an older one finishing late leaves it alone.
        isFetching = true
        defer { if current == generation { isFetching = false } }
        let repositories = settings.get(Self.repositoriesKey)
        guard !repositories.isEmpty else {
            outcomes = [:]
            lastFetched = now()
            return
        }
        guard let gh = GitHubCLI.locate(isExecutable: isExecutable) else {
            if !ghMissing { log?.notice("gh not found") }
            Motion.animate(Motion.morph) { ghMissing = true }
            lastFetched = now()
            return
        }
        let fetcher = RunFetcher(executable: gh, runner: runner, files: files, environment: GitHubCLI.environment(base: environment))
        // Entries gh must not be run for (an unconfirmed host, a malformed hand edit) keep a row that says why.
        let refused = repositories.compactMap { repository in
            RunFetcher.refusal(for: repository).map { (repository, FetchOutcome.problem($0)) }
        }
        let fetchable = repositories.filter(\.mayFetch)
        let fetched = await withTaskGroup(of: (BuildRepository, FetchOutcome).self, returning: [(BuildRepository, FetchOutcome)].self) { group in
            for repository in fetchable {
                group.addTask { (repository, await fetcher.fetch(repository)) }
            }
            var found: [(BuildRepository, FetchOutcome)] = []
            for await result in group { found.append(result) }
            return found
        }
        let results = refused + fetched
        guard current == generation else { return }
        lastFetched = now()

        let kept = Set(self.repositories.map(\.id))
        var next = outcomes.filter { kept.contains($0.key) }
        var finished: [(BuildRepository, BuildRun)] = []
        for (repository, outcome) in results where kept.contains(repository.id) {
            next[repository.id] = outcome
            switch outcome {
            case .runs(let runs, _):
                finished += tracker.observe(runs).map { (repository, $0) }
            case .problem(let problem):
                log?.info("runs for \(repository.repoArgument, privacy: .private) not loaded: \(String(describing: problem), privacy: .public)")
            }
        }
        if next != outcomes || ghMissing {
            Motion.animate(Motion.morph) {
                ghMissing = false
                outcomes = next
            }
        }
        if let (repository, run) = Self.mostNotable(finished) { announce(run, in: repository) }
    }

    /// A failure is news over a pass; otherwise the run that finished last.
    private static func mostNotable(_ finished: [(BuildRepository, BuildRun)]) -> (BuildRepository, BuildRun)? {
        finished.max { a, b in
            if a.1.state.needsLook != b.1.state.needsLook { return b.1.state.needsLook }
            return a.1.updatedAt < b.1.updatedAt
        }
    }

    // MARK: Live activity

    private struct Announcement: Equatable {
        let repository: BuildRepository
        let run: BuildRun
        let at: Date
    }

    private func announce(_ run: BuildRun, in repository: BuildRepository) {
        log?.info("run finished in \(repository.repoArgument, privacy: .private): \(run.state.label, privacy: .public)")
        announcement = Announcement(repository: repository, run: run, at: now())
        announceTask?.cancel()
        let duration = activityDuration
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.announcement = nil
        }
    }

    /// A check for a pass, a cross for anything else that finished.
    static func finishedGlyph(_ state: BuildState) -> (symbol: String, tint: TintRole) {
        switch state {
        case .passed: ("checkmark.circle.fill", .success)
        case .failed, .needsApproval: ("xmark.circle.fill", .warning)
        default: ("xmark.circle", .secondary)
        }
    }

    // MARK: User actions

    /// Opens the run behind a row in the browser.
    public func open(_ row: BuildRow) {
        guard let url = row.run?.url else { return }
        openURL(url)
    }

    public func openSettings() { context?.services.openSettings?(.builds) }

    /// "Add repository…": asks for a folder and adds it.
    public func chooseRepository() async {
        guard let folder = await chooseFolder() else { return }
        addRepository(at: folder)
    }

    /// Reads the folder's remote and adds it to the list. Sets `addError` when the folder cannot be used.
    /// A remote on a host other than github.com is not added yet: it becomes `pendingRepository`, for Settings to
    /// ask about by name, and this returns `false`.
    @discardableResult
    public func addRepository(at folder: URL) -> Bool {
        guard !isFixture, let settings else { return false }
        do throws(RepositoryError) {
            let repository = try BuildRepository.read(folder: folder, files: files)
            var list = settings.get(Self.repositoriesKey)
            guard !list.contains(where: { $0.id == repository.id }) else { throw .alreadyAdded }
            addError = nil
            guard repository.isGitHubDotCom else {
                log?.notice("repository on another host waits for confirmation: \(repository.repoArgument, privacy: .private)")
                pendingRepository = repository
                return false
            }
            pendingRepository = nil
            list.append(repository)
            settings.set(Self.repositoriesKey, list)
            addError = nil
            log?.notice("added repository \(repository.repoArgument, privacy: .private)")
            if running { restartLoop() }
            return true
        } catch {
            log?.info("folder not added: \(String(describing: error), privacy: .public)")
            addError = error
            return false
        }
    }

    /// Asks again about the host of a stored entry that is not confirmed, such as one edited by hand.
    public func reviewHost(of repository: BuildRepository) {
        guard !isFixture, !repository.isHostConfirmed, repository.isWellFormed else { return }
        pendingRepository = repository
    }

    /// The user confirmed `pendingRepository`'s host: store the entry (or update the stored one) with that host
    /// confirmed, and fetch it.
    public func confirmPendingRepository() {
        guard !isFixture, let settings, var repository = pendingRepository else { return }
        pendingRepository = nil
        repository.confirmedHost = repository.host
        var list = settings.get(Self.repositoriesKey)
        if let index = list.firstIndex(where: { $0.id == repository.id }) {
            list[index] = repository
        } else {
            list.append(repository)
        }
        settings.set(Self.repositoriesKey, list)
        log?.notice("confirmed host for \(repository.repoArgument, privacy: .private)")
        Motion.animate(Motion.morph) { outcomes[repository.id] = nil }
        if running { restartLoop() }
    }

    /// The user declined `pendingRepository`'s host: nothing is stored or changed.
    public func cancelPendingRepository() {
        pendingRepository = nil
    }

    public func removeRepository(_ repository: BuildRepository) {
        guard !isFixture, let settings else { return }
        if pendingRepository?.id == repository.id { pendingRepository = nil }
        var list = settings.get(Self.repositoriesKey)
        list.removeAll { $0.id == repository.id }
        settings.set(Self.repositoriesKey, list)
        addError = nil
        Motion.animate(Motion.morph) { outcomes[repository.id] = nil }
        if announcement?.repository.id == repository.id { announcement = nil }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(BuildsPage(module: self)) }

    public func settingsView() -> AnyView? {
        guard let settings else { return nil }
        return AnyView(BuildsSettings(module: self, settings: settings))
    }
}

/// The fixture's runner: runs nothing.
private struct ScriptlessRunner: CommandRunning {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async -> CommandResult {
        CommandResult(status: -1)
    }
}

/// The fixture's file access: reads nothing.
private struct NoRepositoryFiles: RepositoryFileReading {
    func text(at url: URL) -> String? { nil }
    func isDirectory(at url: URL) -> Bool { false }
}

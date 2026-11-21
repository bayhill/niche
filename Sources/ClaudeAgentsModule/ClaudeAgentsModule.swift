import Foundation
import NotchCore
import Observation
import SwiftUI

/// Shows which Claude Code sessions are running and whether any needs the user.
///
/// Two sources, merged by session id (see `SessionReducer`): Claude Code's live registry in `~/.claude/sessions`
/// (read-only, no setup) and, once the user enables alerts, hook events from the `notcher-bridge` plugin that land
/// in `<appSupport>/claude-events`.
@MainActor
@Observable
public final class ClaudeAgentsModule: NotchModule {
    public let id: ModuleID = .claudeAgents
    public let title = "Claude"
    public let symbol = "sparkles"
    public let placement: PanelPlacement = .dashboard(.leadingBottom)
    public var requirements: [PermissionRequirement] {
        [PermissionRequirement(
            .claudeHooks, optional: true,
            rationale: "Shows the moment a Claude Code session needs permission or input."
        )]
    }

    /// Ordered: needs the user, then working, then idle/finished.
    public private(set) var sessions: [ClaudeSession] = []
    public private(set) var liveActivity: LiveActivity?
    public private(set) var hookStatus: HookInstallStatus = .notInstalled
    public private(set) var plan: InstallPlan?
    public private(set) var lastResult: InstallResult?
    public private(set) var isChangingHooks = false

    /// Set only by a successful `installHooks()` and cleared first by `uninstallHooks()`. The spool folder that the
    /// bridge writes to exists only while this is true and the module is running.
    public static let alertsEnabled = SettingsKey<Bool>("claudeAgents.alertsEnabled", default: false)

    /// Whether the closed notch names the waiting session and what it wants. Off restores glyph-only wings, for
    /// people who share their screen and do not want project names visible.
    public static let showNamesInNotch = SettingsKey<Bool>("claudeAgents.showNamesInNotch", default: true)

    public var showsNamesInNotch: Bool { settings?.get(Self.showNamesInNotch) ?? Self.showNamesInNotch.defaultValue }

    public func setShowsNamesInNotch(_ on: Bool) {
        settings?.set(Self.showNamesInNotch, on)
        let activity = ClaudeActivity.make(for: sessions, now: clock(), showNames: showsNamesInNotch)
        if activity != liveActivity { liveActivity = activity }
    }

    /// The honest state of alerts: the user's choice combined with what Claude Code actually has registered.
    public var alertsState: AlertsState {
        AlertsState(enabled: settings?.get(Self.alertsEnabled) ?? sampleAlertsOn, hookStatus: hookStatus)
    }

    /// False until `start` has supplied the settings store; Install needs it to record the choice.
    public var canChangeAlerts: Bool { settings != nil && !isSample }

    /// The card shows at most this many rows; the rest are counted as "+N".
    public static let visibleLimit = ClaudeAgentsModuleLayout.visibleRows

    @ObservationIgnored private let directories: AppDirectories?
    @ObservationIgnored private let bundledPlugin: URL?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let inspector: any ProcessInspecting
    @ObservationIgnored private let runner: any ProcessRunning
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var activator: (any SessionActivating)?
    @ObservationIgnored private var installer: (any HookInstalling)?
    @ObservationIgnored private let isSample: Bool
    @ObservationIgnored private var reducer = SessionReducer()
    @ObservationIgnored private var registryReader: RegistryReader?
    @ObservationIgnored private var spoolReader: SpoolReader?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var watchers: [URL: any DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var spoolDirectory: URL?
    @ObservationIgnored private var sampleAlertsOn = false

    /// - Parameters:
    ///   - directories: filesystem roots; `nil` uses the ones handed to `start` (the app's).
    ///   - bundledPlugin: the plugin marketplace inside the app bundle (`Contents/Resources/ClaudePlugin`).
    ///   - installer: overrides the `HookInstaller` built from `directories` and `runner`.
    public init(
        directories: AppDirectories?,
        bundledPlugin: URL?,
        clock: @escaping @Sendable () -> Date = { Date() },
        inspector: any ProcessInspecting = SystemProcessInspector(),
        runner: any ProcessRunning = SystemProcessRunner(),
        activator: (any SessionActivating)? = nil,
        installer: (any HookInstalling)? = nil,
        pollInterval: Duration = .seconds(3)
    ) {
        self.directories = directories; self.bundledPlugin = bundledPlugin; self.clock = clock
        self.inspector = inspector; self.runner = runner; self.activator = activator; self.installer = installer
        self.pollInterval = pollInterval; self.isSample = false
    }

    /// Fixed sessions and install status, touching nothing on the system. Backs `sample()` and snapshots.
    init(sampleSessions: [ClaudeSession], now: Date, hookStatus: HookInstallStatus = .notInstalled) {
        directories = nil; bundledPlugin = nil; clock = { Date() }; inspector = SystemProcessInspector()
        runner = SystemProcessRunner(); pollInterval = .seconds(3); isSample = true
        installer = SampleHookInstaller()
        sessions = SessionReducer.ordered(sampleSessions)
        liveActivity = ClaudeActivity.make(for: sessions, now: now)
        self.hookStatus = hookStatus
        sampleAlertsOn = hookStatus == .installed
        plan = SampleHookInstaller().plan()
    }

    /// Reads the real registry and the app's spool folder; installs only when the user asks in Settings.
    public static func live() -> ClaudeAgentsModule {
        ClaudeAgentsModule(directories: nil, bundledPlugin: Bundle.main.resourceURL?.appending(path: "ClaudePlugin", directoryHint: .isDirectory))
    }

    /// Fake sessions in every state. Touches nothing on the system.
    public static func sample() -> ClaudeAgentsModule {
        let now = Date()
        func s(_ id: String, _ title: String, _ cwd: String, _ state: SessionState, ago: TimeInterval, _ entry: Entrypoint = .cli) -> ClaudeSession {
            ClaudeSession(id: id, pid: nil, cwd: cwd, title: title, entrypoint: entry, state: state,
                          since: now.addingTimeInterval(-ago), lastEvent: now.addingTimeInterval(-ago))
        }
        return ClaudeAgentsModule(sampleSessions: [
            s("sample-1", "notcher", "/Users/dev/projects/notcher", .needsPermission(detail: "Bash"), ago: 95),
            s("sample-2", "fix-login-redirect", "/Users/dev/projects/webshop", .needsInput(detail: nil), ago: 20, .vscode),
            s("sample-3", "lanternfly", "/Users/dev/projects/lanternfly", .working, ago: 380),
            s("sample-4", "garden-clock", "/Users/dev/projects/garden-clock", .finished(at: now.addingTimeInterval(-40)), ago: 40),
            s("sample-5", "dotfiles", "/Users/dev/dotfiles", .idle(since: now.addingTimeInterval(-3900)), ago: 3900),
        ], now: now)
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        services = context.services
        settings = context.settings
        if isSample {
            context.log.notice("started")
            return
        }
        let dirs = directories ?? context.directories
        registryReader = RegistryReader(directory: dirs.home.appending(path: ".claude/sessions", directoryHint: .isDirectory), inspector: inspector)
        let spool = dirs.appSupport.appending(path: "claude-events", directoryHint: .isDirectory)
        spoolDirectory = spool
        spoolReader = SpoolReader(directory: spool)
        reducer = SessionReducer()
        if installer == nil {
            installer = HookInstaller(
                paths: .standard(directories: dirs, bundledPlugin: bundledPlugin, searchPath: ProcessInfo.processInfo.environment["PATH"]),
                runner: runner, now: clock
            )
        }
        if activator == nil { activator = HostAppActivator(inspector: inspector) }
        if let installer {
            hookStatus = await Task.detached { installer.prepare(); return installer.status() }.value
        }
        guard running else { return }  // stopped while starting
        syncSpool()
        let interval = pollInterval
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let module = self else { return }
                module.armWatchers()
                await module.refresh()
                tick += 1
                if tick % 10 == 0 { module.refreshHookStatus() }
                try? await Task.sleep(for: interval)
            }
        }
        context.log.notice("started")
    }

    /// Stops polling and removes the spool folder, so the bridge collects nothing while the module is off or the
    /// app has quit (the app calls `stop()` at termination). `start` recreates it when alerts are enabled.
    public func stop() {
        loop?.cancel()
        loop = nil
        for source in watchers.values { source.cancel() }
        watchers = [:]
        running = false
        syncSpool()
    }

    /// The spool exists exactly while the module runs with alerts enabled.
    private func syncSpool() {
        guard let spool = spoolDirectory else { return }
        let fm = FileManager.default
        if running, settings?.get(Self.alertsEnabled) == true {
            try? fm.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if fm.fileExists(atPath: spool.path) {
            try? fm.removeItem(at: spool)
        }
    }

    // MARK: Refresh

    /// Reads the registry and drains the spool once, then republishes. Safe to call repeatedly.
    public func refresh() async {
        guard let registryReader, let spoolReader else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            let now = clock()
            let (snapshot, events) = await Task.detached { (registryReader.read(), spoolReader.drain(now: now)) }.value
            reducer.applyRegistry(snapshot, now: now)
            for event in events { reducer.apply(event) }
            reducer.prune(now: now)
            publish(now: clock())
        } while refreshAgain
        refreshing = false
    }

    private func publish(now: Date) {
        let next = reducer.sessions(now: now)
        if next != sessions { Motion.animate(Motion.morph) { sessions = next } }
        let activity = ClaudeActivity.make(for: next, now: now, showNames: showsNamesInNotch)
        if activity != liveActivity { liveActivity = activity }
    }

    private func refreshHookStatus() {
        guard let installer else { return }
        Task {
            let status = await Task.detached { installer.status() }.value
            if status != hookStatus { hookStatus = status }
            syncSpool()
        }
    }

    /// File-system events on the registry and spool folders trigger an immediate refresh; the poll covers the rest
    /// (folders that do not exist yet, processes that die without touching their file).
    private func armWatchers() {
        for url in [registryReader?.directory, spoolReader?.directory].compactMap({ $0 }) where watchers[url] == nil {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let data = self.watchers[url]?.data, !data.intersection([.delete, .rename]).isEmpty {
                        self.watchers[url]?.cancel()
                        self.watchers[url] = nil
                    }
                    Task { await self.refresh() }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[url] = source
        }
    }

    // MARK: Actions

    /// Brings the app hosting the session to the front.
    public func activate(_ session: ClaudeSession) {
        guard let pid = session.pid else { return }
        activator?.activateHost(ofProcess: pid)
    }

    public func openAlertSettings() {
        services?.openSettings?(.claudeAgents)
    }

    public func reloadPlan() {
        guard let installer, !isSample else { return }
        Task {
            let (plan, status) = await Task.detached { (installer.plan(), installer.status()) }.value
            self.plan = plan
            self.hookStatus = status
        }
    }

    /// Registers the plugin with Claude Code; only on success are alerts switched on (and the spool created).
    public func installHooks() async {
        guard let installer, let settings, !isChangingHooks else { return }
        isChangingHooks = true
        let result = await installer.install()
        lastResult = result
        if result.succeeded { settings.set(Self.alertsEnabled, true) }
        await reloadStatus(installer)
        syncSpool()
        isChangingHooks = false
        armWatchers()
    }

    /// Switches alerts off first (the spool goes at once, so nothing more is collected), then asks Claude Code to
    /// forget the plugin. If that fails, alerts stay off and `alertsState` reports `.offStillRegistered`.
    public func uninstallHooks() async {
        guard let installer, !isChangingHooks else { return }
        isChangingHooks = true
        settings?.set(Self.alertsEnabled, false)
        syncSpool()
        let result = await installer.uninstall()
        lastResult = result
        await reloadStatus(installer)
        isChangingHooks = false
    }

    private func reloadStatus(_ installer: any HookInstalling) async {
        let (status, plan) = await Task.detached { (installer.status(), installer.plan()) }.value
        hookStatus = status
        self.plan = plan
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(ClaudeCard(module: self)) }

    public func settingsView() -> AnyView? { AnyView(ClaudeSettingsView(module: self)) }
}

/// Canned installer for `sample()`: a believable plan, and install/uninstall that change nothing.
struct SampleHookInstaller: HookInstalling {
    func status() -> HookInstallStatus { .notInstalled }
    func prepare() {}
    func plan() -> InstallPlan {
        let cli = URL(filePath: "/Users/dev/.local/bin/claude")
        let root = "/Users/dev/Library/Application Support/Notcher/claude-plugin"
        return InstallPlan(
            cli: cli,
            installCommands: [
                PlannedCommand(executable: cli, arguments: ["plugin", "marketplace", "add", root, "--scope", "user"]),
                PlannedCommand(executable: cli, arguments: ["plugin", "install", HookInstaller.pluginID, "--scope", "user"]),
            ],
            uninstallCommands: [
                PlannedCommand(executable: cli, arguments: ["plugin", "uninstall", HookInstaller.pluginID, "--scope", "user"]),
                PlannedCommand(executable: cli, arguments: ["plugin", "marketplace", "remove", HookInstaller.marketplace, "--scope", "user"]),
            ],
            installSteps: [
                "Copy the plugin from the app to \(root)",
                "Back up /Users/dev/.claude/settings.json to /Users/dev/Library/Application Support/Notcher/claude-settings-backups/settings-<timestamp>.json",
                "Run the two commands below (if the second fails, the first is undone)",
                "While Notcher runs with alerts on, keep /Users/dev/Library/Application Support/Notcher/claude-events for the plugin to drop events in",
            ],
            uninstallSteps: [],
            settingsFile: URL(filePath: "/Users/dev/.claude/settings.json"),
            settingsBefore: HookInstaller.render(["enabledPlugins": ["formatter@team-tools": true]]),
            settingsAfter: HookInstaller.render([
                "enabledPlugins": ["formatter@team-tools": true, HookInstaller.pluginID: true],
                "extraKnownMarketplaces": [HookInstaller.marketplace: ["source": ["source": "directory", "path": root]]],
            ])
        )
    }
    func install() async -> InstallResult { InstallResult(succeeded: false, message: "Sample data. Nothing was installed.") }
    func uninstall() async -> InstallResult { InstallResult(succeeded: false, message: "Sample data. Nothing was changed.") }
}

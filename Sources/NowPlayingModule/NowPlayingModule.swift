import AppKit
import Foundation
import NotchCore
import Observation
import os
import SwiftUI

/// Which provider to run, given what is known at start. Pure.
public enum NowPlayingSelection: Sendable, Equatable {
    case adapter
    case appleScript
    /// The fallback would prompt for Automation; wait for the user to click Connect.
    case needsConnect
    case unavailable

    public static func choose(adapterPassed: Bool, hasFallback: Bool, consented: Bool, mayPrompt: Bool) -> Self {
        if adapterPassed { return .adapter }
        guard hasFallback else { return .unavailable }
        return consented || mayPrompt ? .appleScript : .needsConnect
    }
}

/// The wing glyph for a state. Pure. `updatedAt` is passed in so equal states produce equal activities.
public enum NowPlayingActivity {
    public static let id = "nowPlaying.track"

    /// Shown only while playing (paused or nothing: `nil`). The `id` is the same for every track so the wings
    /// animate in place. Never tinted.
    /// - Parameter showText: title in the left wing, artist (or the album when there is none) in the right wing.
    public static func make(_ state: NowPlayingState?, updatedAt: Date, showText: Bool = true) -> LiveActivity? {
        guard let state, state.isPlaying else { return nil }
        let title = clean(state.title), artist = clean(state.artist), album = clean(state.album)
        var label = "Playing"
        if let title { label += " \(title)" }
        if let artist { label += " by \(artist)" } else if let album { label += " from \(album)" }
        return LiveActivity(
            id: id, module: .nowPlaying, priority: .ambient,
            leading: state.artwork.map { .image($0) } ?? .symbol("music.note", tint: .primary),
            trailing: .equalizer(playing: true),
            leadingText: showText ? title : nil,
            trailingText: showText ? (artist ?? album) : nil,
            updatedAt: updatedAt, accessibilityLabel: label
        )
    }

    /// Trimmed, single line, `nil` when empty.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

@MainActor
@Observable
public final class NowPlayingModule: NotchModule, PlaybackControlling {
    public enum Phase: Sendable, Equatable {
        /// Before `start`, or while the adapter self-test runs.
        case idle
        case active(NowPlayingSource)
        /// Only the Apple Events fallback is available and the user has not opted in yet.
        case needsConnect
        /// Automation was denied for this player app.
        case notAuthorized(app: String)
        case unavailable
    }

    /// Set once the user clicks Connect; later launches use the fallback without asking again.
    public static let automationConsent = SettingsKey("nowPlaying.automationConsent", default: false)
    /// Cached adapter self-test result. The test publishes a fake now-playing entry when nothing is playing, so it
    /// only reruns when `key` (OS build + adapter identity) changes, after the stream gives up, or on "Check again".
    public static let adapterCheck = SettingsKey<AdapterCheck?>("nowPlaying.adapterCheck", default: nil)
    /// Let the artwork's colour bloom through the card (`GlassCard(ambient:)`).
    public static let ambientArtwork = SettingsKey("nowPlaying.ambientArtwork", default: true)
    /// Title and artist as text in the wings beside the closed notch.
    public static let showTitleInNotch = SettingsKey("nowPlaying.showTitleInNotch", default: true)

    public let id = ModuleID.nowPlaying
    public let title = "Now Playing"
    public let symbol = "music.note"
    public let placement = PanelPlacement.dashboard(.center)
    public var requirements: [PermissionRequirement] {
        ScriptablePlayer.allCases.map {
            PermissionRequirement(
                .automation(bundleID: $0.bundleID), optional: true,
                rationale: "Shows the \($0.name) track and its controls when the system Now Playing source is unavailable."
            )
        }
    }

    public private(set) var state: NowPlayingState?
    public private(set) var phase: Phase = .idle
    public private(set) var liveActivity: LiveActivity?
    /// The provider feeding the card, for Settings. `nil` while none is running.
    public var activeSource: NowPlayingSource? { if case .active(let s) = phase { s } else { nil } }
    /// Whether the card shows ambient artwork (setting; on before `start` provides the store).
    public var ambientArtwork: Bool { settings?.get(Self.ambientArtwork) ?? Self.ambientArtwork.defaultValue }
    /// The store from `start`, for `settingsView()`.
    var settingsStore: SettingsStore? { settings }
    /// The app the current track plays from, when it can be brought forward. `nil` = the card is not clickable.
    public private(set) var sourceApp: SourceApp?
    /// The self-test result in use, for Settings.
    public private(set) var lastCheck: AdapterCheck?
    public private(set) var isChecking = false

    @ObservationIgnored private let adapter: (any NowPlayingProvider)?
    @ObservationIgnored private let adapterSelfTest: @Sendable () async -> AdapterTestOutcome
    @ObservationIgnored private let selfTestKey: String?
    @ObservationIgnored private let verifyAfter: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var retriedAfterGiveUp = false
    /// The stream started without a cached pass; it is confirmed by a real track or, failing that, by the self-test.
    @ObservationIgnored private var verifying = false
    @ObservationIgnored private let fallback: (any NowPlayingProvider)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var active: (any NowPlayingProvider)?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var services: AppServices?
    @ObservationIgnored private let opener: SourceAppOpener
    @ObservationIgnored private var running = false
    @ObservationIgnored private var selection: Task<Void, Never>?
    @ObservationIgnored private var log = Log.logger(for: .nowPlaying)

    /// - Parameters:
    ///   - adapter: the preferred provider (MediaRemote adapter).
    ///   - adapterSelfTest: the adapter's `test`. It may publish a fake now-playing entry, so it runs only when the
    ///     stream could not prove itself (see `AdapterCheckPolicy`).
    ///   - selfTestKey: identifies the OS build and adapter for the cached result. `nil` = never cache.
    ///   - verifyAfter: how long a stream started without a cached pass may stay silent before the self-test runs.
    ///   - fallback: used when the adapter fails, but only once the user opted in (it may prompt for Automation).
    public init(
        adapter: (any NowPlayingProvider)?, adapterSelfTest: @escaping @Sendable () async -> AdapterTestOutcome,
        selfTestKey: String? = nil, verifyAfter: Duration = .seconds(15), fallback: (any NowPlayingProvider)?,
        now: @escaping @MainActor () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        opener: SourceAppOpener = .inert
    ) {
        self.adapter = adapter; self.adapterSelfTest = adapterSelfTest; self.selfTestKey = selfTestKey
        self.verifyAfter = verifyAfter; self.fallback = fallback; self.now = now; self.sleep = sleep; self.opener = opener
    }

    /// Adapter from the app bundle (if present) with the Spotify/Music fallback.
    public static func live() -> NowPlayingModule {
        let locations = AdapterLocations.inBundle()
        let selfTest: @Sendable () async -> AdapterTestOutcome =
            if let locations { { await AdapterProvider.selfTest(locations) } } else { { .failed } }
        return NowPlayingModule(
            adapter: locations.map { AdapterProvider(locations: $0) }, adapterSelfTest: selfTest,
            selfTestKey: locations.map { AdapterCheck.key(os: ProcessInfo.processInfo.operatingSystemVersionString, adapter: $0.identity) },
            fallback: AppleScriptProvider(), opener: .live
        )
    }

    /// A fixed track with generated artwork. Spawns nothing and sends no Apple Events.
    public static func sample(_ state: NowPlayingState? = SampleProvider.track) -> NowPlayingModule {
        let provider = SampleProvider(state: state)
        let module = NowPlayingModule(adapter: provider, adapterSelfTest: { .passed }, fallback: nil)
        module.activate(provider)
        return module
    }

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        settings = context.settings
        services = context.services
        log = context.log
        retriedAfterGiveUp = false
        observeTitleSetting()
        guard adapter != nil else {
            // `mayPrompt` is honoured only here, while the user is enabling the module.
            select(adapterPassed: false, mayPrompt: context.mayPrompt)
            context.log.notice("started")
            return
        }
        let cached = settings?.get(Self.adapterCheck)
        switch AdapterCheckPolicy.decide(cached: cached, key: selfTestKey, now: now()) {
        case .usePass:
            lastCheck = cached
            select(adapterPassed: true)
        case .useFail:
            lastCheck = cached
            select(adapterPassed: false, mayPrompt: context.mayPrompt)
        case .verify:
            // Stream first: a real track proves the adapter without the self-test's fake entry.
            select(adapterPassed: true)
            scheduleVerification()
        }
        context.log.notice("started")
    }

    public func stop() {
        running = false
        verifying = false
        selection?.cancel()
        selection = nil
        isChecking = false
        active?.stop()
        active = nil
        phase = .idle
        apply(nil)
    }

    /// Runs the adapter self-test again (Settings "Check again") and switches provider accordingly.
    public func checkAgain() {
        guard adapter != nil else { return }
        retriedAfterGiveUp = false
        verifying = false
        runSelfTest { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .passed: self.select(adapterPassed: true)
            case .failed: self.select(adapterPassed: false)
            case .unknown: break
            }
        }
    }

    private func scheduleVerification() {
        verifying = true
        selection?.cancel()
        let sleep = sleep, delay = verifyAfter
        selection = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.verifying else { return }
            self.runSelfTest { [weak self] outcome in
                guard let self, self.verifying else { return }
                self.verifying = false
                if outcome == .failed {
                    self.log.error("adapter self-test failed; leaving the stream")
                    self.select(adapterPassed: false)
                }
            }
        }
    }

    /// The stream delivered a real track: the adapter works. Cached like a passing self-test.
    private func confirmAdapter() {
        verifying = false
        selection?.cancel()
        selection = nil
        isChecking = false
        record(.passed)
    }

    private func record(_ outcome: AdapterTestOutcome) {
        guard outcome != .unknown else { return }
        let check = AdapterCheck(key: selfTestKey ?? "", passed: outcome == .passed, checkedAt: now())
        lastCheck = check
        if selfTestKey != nil { settings?.set(Self.adapterCheck, check) }
    }

    private func runSelfTest(then decide: @escaping @MainActor (AdapterTestOutcome) -> Void) {
        selection?.cancel()
        isChecking = true
        selection = Task { [weak self, adapterSelfTest] in
            let outcome = await adapterSelfTest()
            guard let self else { return }
            // A finished test is evidence even if the module stopped meanwhile: record it, so the next start
            // does not test again. Only a live, non-superseded run acts on it.
            self.record(outcome)
            guard !Task.isCancelled else { return }
            self.isChecking = false
            self.log.notice("adapter self-test: \(String(describing: outcome), privacy: .public)")
            if self.running { decide(outcome) }
        }
    }

    /// The user asked to use Spotify/Music through Apple Events. Shows the system prompt on first use.
    public func connect() {
        settings?.set(Self.automationConsent, true)
        guard let fallback else { return }
        verifying = false
        activate(fallback)
    }

    /// Opens Privacy & Security › Automation, where a denied Spotify/Music permission is turned back on.
    public func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    public func send(_ command: MediaCommand) {
        active?.send(command)
    }

    /// `PlaybackControlling`: pauses only when something is known to be playing, with the pause-only command.
    public func pauseIfPlaying() {
        guard state?.isPlaying == true else { return }
        send(.pause)
    }

    /// Brings the source app forward (activates it, or launches it if it quit) and collapses the notch.
    /// Does nothing when the card is not clickable.
    public func openSourceApp() {
        guard let app = sourceApp ?? opener.resolve(state?.bundleID) else { return }
        guard opener.open(app) != .unavailable else { return }
        services?.notch?.collapse()
    }

    /// - Parameter mayPrompt: only `start` passes the context's value; later decisions never prompt on their own.
    func select(adapterPassed: Bool, mayPrompt: Bool = false) {
        let choice = NowPlayingSelection.choose(
            adapterPassed: adapterPassed && adapter != nil, hasFallback: fallback != nil,
            consented: settings?.get(Self.automationConsent) ?? false, mayPrompt: mayPrompt
        )
        log.notice("now playing source: \(String(describing: choice), privacy: .public)")
        switch choice {
        case .adapter: if let adapter { activate(adapter) }
        case .appleScript: if let fallback { activate(fallback) }
        case .needsConnect, .unavailable:
            if let active, active === adapter { active.stop(); self.active = nil; apply(nil) }
            phase = choice == .needsConnect ? .needsConnect : .unavailable
        }
    }

    private func activate(_ provider: any NowPlayingProvider) {
        if let active, active === provider, phase == .active(provider.source) { return }
        active?.stop()
        active = provider
        phase = .active(provider.source)
        provider.onUpdate = { [weak self] in self?.apply($0) }
        provider.onFailure = { [weak self, weak provider] failure in
            guard let self, let provider, self.active === provider else { return }
            self.handle(failure)
        }
        provider.start()
    }

    private func handle(_ failure: NowPlayingFailure) {
        switch failure {
        case .gaveUp:
            log.error("adapter stream gave up; testing the adapter again")
            active = nil
            phase = .idle
            verifying = false
            runSelfTest { [weak self] outcome in
                guard let self else { return }
                // One more stream attempt per session after a passing retest; otherwise the fallback path
                // (which never prompts here: only a click on Connect may).
                let retry = outcome == .passed && !self.retriedAfterGiveUp
                if retry { self.retriedAfterGiveUp = true }
                self.select(adapterPassed: retry)
            }
        case .notAuthorized(let bundleID):
            let name = ScriptablePlayer(rawValue: bundleID)?.name ?? bundleID
            if state == nil { phase = .notAuthorized(app: name) }
        }
    }

    private func apply(_ new: NowPlayingState?) {
        if new != nil, verifying, let active, active === adapter { confirmAdapter() }
        guard new != state else { return }
        let bundleChanged = new?.bundleID != state?.bundleID
        Motion.animate(Motion.morph) { state = new }
        if bundleChanged { sourceApp = opener.resolve(new?.bundleID) }
        updateActivity()
        if new != nil, case .notAuthorized = phase, let active { phase = .active(active.source) }
    }

    private var showTitleInNotch: Bool { settings?.get(Self.showTitleInNotch) ?? Self.showTitleInNotch.defaultValue }

    private func updateActivity() {
        let activity = NowPlayingActivity.make(state, updatedAt: now(), showText: showTitleInNotch)
        if !Self.sameContent(activity, liveActivity) { liveActivity = activity }
    }

    /// Re-renders the wings when "Show title and artist beside the notch" is toggled.
    private func observeTitleSetting() {
        guard running, let settings else { return }
        withObservationTracking {
            _ = settings.get(Self.showTitleInNotch)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.updateActivity()
                self.observeTitleSetting()
            }
        }
    }

    /// Equal apart from `updatedAt`, so steady playback does not keep re-arbitrating the wings.
    static func sameContent(_ a: LiveActivity?, _ b: LiveActivity?) -> Bool {
        guard var a, let b else { return a == nil && b == nil }
        a.updatedAt = b.updatedAt
        return a == b
    }

    public func panelView() -> AnyView { AnyView(NowPlayingCard(module: self)) }

    public func settingsView() -> AnyView? { AnyView(NowPlayingSettings(module: self)) }
}

/// A cached adapter self-test result.
public struct AdapterCheck: Codable, Sendable, Equatable {
    public var key: String
    public var passed: Bool
    public var checkedAt: Date
    public init(key: String, passed: Bool, checkedAt: Date) { self.key = key; self.passed = passed; self.checkedAt = checkedAt }

    public static func key(os: String, adapter: String) -> String { "\(os)|\(adapter)" }
}

/// Result of the adapter's `test` command.
public enum AdapterTestOutcome: Sendable, Equatable {
    case passed
    case failed
    /// Timed out or could not be launched (e.g. a loaded login): says nothing about MediaRemote.
    case unknown
}

/// What `start` does with a cached self-test result. Pure.
public enum AdapterCheckPolicy {
    public enum Decision: Sendable, Equatable {
        /// Matching pass: stream right away, no test.
        case usePass
        /// Recent matching failure: fallback path, no test.
        case useFail
        /// No usable result: start the stream and confirm it (a real track, else the self-test after a delay).
        case verify
    }

    /// How long a failure is trusted. Passes are trusted until the key changes.
    public static let failureLifetime: TimeInterval = 3600

    public static func decide(cached: AdapterCheck?, key: String?, now: Date) -> Decision {
        guard let key, let cached, cached.key == key else { return .verify }
        if cached.passed { return .usePass }
        let age = now.timeIntervalSince(cached.checkedAt)
        return age >= 0 && age < failureLifetime ? .useFail : .verify
    }
}

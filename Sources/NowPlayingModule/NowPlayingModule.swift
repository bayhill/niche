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

    public static func make(_ state: NowPlayingState?, updatedAt: Date) -> LiveActivity? {
        guard let state, state.isPlaying else { return nil }
        let label = [state.title, state.artist].compactMap(\.self).joined(separator: " by ")
        return LiveActivity(
            id: id, module: .nowPlaying, priority: .ambient,
            leading: state.artwork.map { .image($0) } ?? .symbol("music.note", tint: .primary),
            trailing: .equalizer(playing: true),
            updatedAt: updatedAt, accessibilityLabel: "Playing \(label)"
        )
    }
}

@MainActor
@Observable
public final class NowPlayingModule: NotchModule {
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
    /// The self-test result in use, for Settings.
    public private(set) var lastCheck: AdapterCheck?
    public private(set) var isChecking = false

    @ObservationIgnored private let adapter: (any NowPlayingProvider)?
    @ObservationIgnored private let adapterSelfTest: @Sendable () async -> Bool
    @ObservationIgnored private let selfTestKey: String?
    @ObservationIgnored private var retriedAfterGiveUp = false
    @ObservationIgnored private let fallback: (any NowPlayingProvider)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var active: (any NowPlayingProvider)?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var mayPrompt = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var selection: Task<Void, Never>?
    @ObservationIgnored private var log = Log.logger(for: .nowPlaying)

    /// - Parameters:
    ///   - adapter: the preferred provider (MediaRemote adapter), used when `adapterSelfTest` passes.
    ///   - fallback: used otherwise, but only once the user opted in (it may prompt for Automation).
    ///   - selfTestKey: identifies the OS build and adapter; a cached result with the same key is reused instead of
    ///     testing again. `nil` = do not cache (always test at start).
    public init(
        adapter: (any NowPlayingProvider)?, adapterSelfTest: @escaping @Sendable () async -> Bool,
        selfTestKey: String? = nil, fallback: (any NowPlayingProvider)?, now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.adapter = adapter; self.adapterSelfTest = adapterSelfTest; self.selfTestKey = selfTestKey
        self.fallback = fallback; self.now = now
    }

    /// Adapter from the app bundle (if present) with the Spotify/Music fallback.
    public static func live() -> NowPlayingModule {
        let locations = AdapterLocations.inBundle()
        let selfTest: @Sendable () async -> Bool = if let locations { { await AdapterProvider.selfTest(locations) } } else { { false } }
        return NowPlayingModule(
            adapter: locations.map { AdapterProvider(locations: $0) }, adapterSelfTest: selfTest,
            selfTestKey: locations.map { AdapterCheck.key(os: ProcessInfo.processInfo.operatingSystemVersionString, adapter: $0.identity) },
            fallback: AppleScriptProvider()
        )
    }

    /// A fixed track with generated artwork. Spawns nothing and sends no Apple Events.
    public static func sample(_ state: NowPlayingState? = SampleProvider.track) -> NowPlayingModule {
        let provider = SampleProvider(state: state)
        let module = NowPlayingModule(adapter: provider, adapterSelfTest: { true }, fallback: nil)
        module.activate(provider)
        return module
    }

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        settings = context.settings
        mayPrompt = context.mayPrompt
        log = context.log
        if adapter == nil {
            select(adapterPassed: false)
        } else if let key = selfTestKey, let cached = settings?.get(Self.adapterCheck), cached.key == key {
            lastCheck = cached
            select(adapterPassed: cached.passed)
        } else {
            runSelfTest()
        }
        context.log.notice("started")
    }

    public func stop() {
        running = false
        selection?.cancel()
        selection = nil
        active?.stop()
        active = nil
        phase = .idle
        apply(nil)
    }

    /// Runs the adapter self-test again (Settings "Check again") and switches provider accordingly.
    public func checkAgain() {
        guard adapter != nil else { return }
        retriedAfterGiveUp = false
        runSelfTest()
    }

    private func runSelfTest(then decide: (@MainActor (Bool) -> Void)? = nil) {
        selection?.cancel()
        isChecking = true
        selection = Task { [weak self, adapterSelfTest] in
            let passed = await adapterSelfTest()
            guard !Task.isCancelled, let self else { return }
            self.isChecking = false
            let check = AdapterCheck(key: self.selfTestKey ?? "", passed: passed, checkedAt: self.now())
            self.lastCheck = check
            if self.selfTestKey != nil { self.settings?.set(Self.adapterCheck, check) }
            if let decide { decide(passed) } else { self.select(adapterPassed: passed) }
        }
    }

    /// The user asked to use Spotify/Music through Apple Events. Shows the system prompt on first use.
    public func connect() {
        settings?.set(Self.automationConsent, true)
        guard let fallback else { return }
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

    func select(adapterPassed: Bool) {
        let choice = NowPlayingSelection.choose(
            adapterPassed: adapterPassed && adapter != nil, hasFallback: fallback != nil,
            consented: settings?.get(Self.automationConsent) ?? false, mayPrompt: mayPrompt
        )
        log.notice("now playing source: \(String(describing: choice), privacy: .public)")
        switch choice {
        case .adapter: if let adapter { activate(adapter) }
        case .appleScript: if let fallback { activate(fallback) }
        case .needsConnect: phase = .needsConnect
        case .unavailable: phase = .unavailable
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
            runSelfTest { [weak self] passed in
                guard let self else { return }
                // One more stream attempt per session after a passing retest; otherwise the fallback path.
                let retry = passed && !self.retriedAfterGiveUp
                if retry { self.retriedAfterGiveUp = true }
                self.select(adapterPassed: retry)
            }
        case .notAuthorized(let bundleID):
            let name = ScriptablePlayer(rawValue: bundleID)?.name ?? bundleID
            if state == nil { phase = .notAuthorized(app: name) }
        }
    }

    private func apply(_ new: NowPlayingState?) {
        guard new != state else { return }
        Motion.animate(Motion.morph) { state = new }
        let activity = NowPlayingActivity.make(new, updatedAt: now())
        if !Self.sameContent(activity, liveActivity) { liveActivity = activity }
        if new != nil, case .notAuthorized = phase, let active { phase = .active(active.source) }
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

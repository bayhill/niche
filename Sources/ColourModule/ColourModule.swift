import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// Pick a colour anywhere on screen; copy it in the format needed; check the contrast of two picks.
@MainActor
@Observable
public final class ColourModule: NotchModule {
    /// The format a click (and a fresh pick) copies.
    public static let formatKey = SettingsKey<ColourFormat>("colour.format", default: .hex)
    /// Copy each pick in the current format as soon as it is made, so pick-then-paste works with the panel closed.
    public static let copyOnPickKey = SettingsKey<Bool>("colour.copyOnPick", default: true)

    public let id: ModuleID = .colour
    public let title = "Colour"
    public let symbol = "eyedropper"
    public let placement: PanelPlacement = .page(order: 40)
    public private(set) var liveActivity: LiveActivity?

    /// Newest first.
    public var picks: [ColourPick] { history.picks }
    public var capacity: Int { history.capacity }
    public private(set) var history: ColourHistory
    /// True while the system magnifier is up.
    public private(set) var isPicking = false
    /// Selection mode: a click on a swatch chooses it for the contrast card instead of copying it.
    public private(set) var isComparing = false
    public private(set) var selection = ContrastSelection()
    /// The pick that was just copied, for a brief confirmation.
    public private(set) var copiedID: ColourPick.ID?
    private var settings: SettingsStore?

    @ObservationIgnored private let sampler: any ColourSampling
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let activityDuration: Duration
    @ObservationIgnored private let copiedDuration: Duration
    /// Fixture mode: no loading or saving.
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private var context: ModuleContext?
    @ObservationIgnored private var storeURL: URL?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sampler: shows the magnifier (`SystemColourSampler` in the app).
    ///   - copy: puts text on the clipboard (`ColourModule.copyToGeneralPasteboard` in the app).
    ///   - now: clock for pick times and the live activity.
    ///   - activityDuration: how long the pick stays beside the notch.
    ///   - copiedDuration: how long a swatch shows "Copied".
    ///   - capacity: how many picks are kept.
    public init(
        sampler: any ColourSampling,
        copy: @escaping @MainActor (String) -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        activityDuration: Duration = .seconds(4),
        copiedDuration: Duration = .seconds(1.2),
        capacity: Int = ColourHistory.defaultCapacity
    ) {
        self.sampler = sampler
        self.copyText = copy
        self.now = now
        self.activityDuration = activityDuration
        self.copiedDuration = copiedDuration
        self.history = ColourHistory(capacity: capacity)
        self.isFixture = false
    }

    private init(fixture picks: [ColourPick]) {
        sampler = SampleSampler()
        copyText = { _ in }
        now = { Date() }
        activityDuration = .seconds(4)
        copiedDuration = .seconds(1.2)
        history = ColourHistory(picks)
        isFixture = true
    }

    /// The module the app runs: the system magnifier, the general pasteboard, history under `appSupport`.
    public static func live() -> ColourModule {
        ColourModule(sampler: SystemColourSampler(), copy: ColourModule.copyToGeneralPasteboard)
    }

    /// Invented picks, one outside sRGB. Touches no files, never shows the magnifier, never writes the pasteboard.
    public static func sample() -> ColourModule { ColourModule(fixture: ColourSamples.picks(now: Date())) }

    /// The app's copy: replaces the general pasteboard's contents with the text.
    public static func copyToGeneralPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        self.context = context
        settings = context.settings
        if !isFixture {
            let url = ColourFiles.storeURL(in: context.directories)
            // Anything picked before start is kept in front of what was on disk.
            history.replace(with: history.picks + ColourFiles.load(from: url))
            storeURL = url
        }
        context.log.notice("started")
    }

    /// Flushes the history and clears transient state. `start` on the same instance resumes.
    public func stop() {
        save()
        running = false
        activityTask?.cancel(); activityTask = nil
        copiedTask?.cancel(); copiedTask = nil
        liveActivity = nil
        copiedID = nil
    }

    // MARK: Settings

    public var format: ColourFormat { settings?.get(Self.formatKey) ?? Self.formatKey.defaultValue }
    public var copiesOnPick: Bool { settings?.get(Self.copyOnPickKey) ?? Self.copyOnPickKey.defaultValue }

    public func setFormat(_ format: ColourFormat) { settings?.set(Self.formatKey, format) }

    // MARK: Picking

    /// Collapses the panel, shows the magnifier and records the pick. A cancelled pick changes nothing.
    public func pick() async {
        guard !isPicking else { return }
        isPicking = true
        defer { isPicking = false }
        // Out of the way of the loupe. Looked up now: the notch controller may come and go.
        context?.services.notch?.collapse()
        guard let colour = await sampler.sample() else { return }
        record(colour)
    }

    /// Adds a picked colour: front of the history, copied when the setting says so, shown beside the notch.
    func record(_ colour: Colour) {
        let stamp = now()
        var stored = ColourPick(colour: colour, pickedAt: stamp)
        Motion.animate(Motion.morph) {
            stored = history.add(stored)
            // A fresh pick returns the contrast card to the two newest picks, unless a pair is being chosen.
            if !isComparing { selection.clear() }
            selection.keep(history)
        }
        save()
        let copied = copiesOnPick
        let text = colour.formatted(format).text
        if copied { copyText(text) }
        publishActivity(for: stored, copied: copied, at: stamp)
    }

    private func publishActivity(for pick: ColourPick, copied: Bool, at stamp: Date) {
        let hex = pick.colour.hex
        let glyph: ActivityGlyph = SwatchImage.make(pick.colour).map(ActivityGlyph.image) ?? .symbol("eyedropper")
        liveActivity = LiveActivity(
            id: "colour.picked", module: .colour, priority: .passive, leading: glyph,
            leadingText: copied ? "Copied" : nil, trailingText: hex,
            expiresAt: stamp.addingTimeInterval(Self.seconds(activityDuration)), updatedAt: stamp,
            accessibilityLabel: copied ? "Picked \(hex), copied as \(format.label)" : "Picked \(hex)"
        )
        activityTask?.cancel()
        let duration = activityDuration
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.liveActivity = nil
        }
    }

    // MARK: Swatches

    /// Copies the pick in the current format, with a brief "Copied" on its swatch.
    public func copy(_ pick: ColourPick) {
        copyText(pick.colour.formatted(format).text)
        Motion.animate(Motion.morph) { copiedID = pick.id }
        Haptics.tick()
        copiedTask?.cancel()
        let duration = copiedDuration
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            Motion.animate(Motion.morph) { self.copiedID = nil }
        }
    }

    /// What a click on a swatch does: copy, or choose it for contrast in selection mode.
    public func activate(_ pick: ColourPick) {
        if isComparing {
            Motion.animate(Motion.morph) { selection.toggle(pick.id) }
        } else {
            copy(pick)
        }
    }

    /// Enters or leaves selection mode. Entering starts from the pair on show, so it can be adjusted;
    /// leaving with fewer than two chosen returns the card to the two newest picks.
    public func setComparing(_ on: Bool) {
        Motion.animate(Motion.morph) {
            if on, selection.isEmpty, let (a, b) = selection.pair(in: history, fallbackToNewest: true) {
                selection = ContrastSelection(chosen: [a.id, b.id])
            }
            if !on, selection.pair(in: history, fallbackToNewest: false) == nil { selection.clear() }
            isComparing = on
        }
    }

    /// The two picks the contrast card compares, or `nil`.
    public var contrastPair: (ColourPick, ColourPick)? {
        selection.pair(in: history, fallbackToNewest: !isComparing)
    }

    /// Empties the history and saves.
    public func clear() {
        Motion.animate(Motion.morph) {
            history.removeAll()
            selection.clear()
            isComparing = false
            copiedID = nil
        }
        save()
    }

    private func save() {
        guard !isFixture, let storeURL else { return }
        do { try ColourFiles.save(history.picks, to: storeURL) } catch {
            context?.log.error("saving colour history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(ColourPage(module: self)) }

    public func settingsView() -> AnyView? {
        guard let settings else { return nil }
        return AnyView(ColourSettings(settings: settings))
    }
}

/// The fixture's magnifier: hands out invented colours in turn, never shows anything.
@MainActor
final class SampleSampler: ColourSampling {
    private var next = 0
    func sample() async -> Colour? {
        let colours = ColourSamples.extraPicks
        defer { next += 1 }
        return colours[next % colours.count]
    }
}

import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// Recent screenshots, ready to drag out, convert or shelve.
///
/// Dormant until the user asks for it (`enabledKey`): until then neither Spotlight nor any file is touched. Once on,
/// a live Spotlight query lists screenshots wherever they are saved; only a thumbnail opens a file. Nothing is
/// persisted, and no screenshot is ever moved, renamed, copied or deleted.
@MainActor
@Observable
public final class ScreenshotsModule: NotchModule {
    /// The user's consent to look for screenshots. Off by default.
    public static let enabledKey = SettingsKey<Bool>("screenshots.enabled", default: false)
    /// Show a new screenshot beside the notch for a few seconds.
    public static let showBesideNotchKey = SettingsKey<Bool>("screenshots.showBesideNotch", default: true)
    /// Longer side of a thumbnail, in pixels: a 157 pt tile at 2x, with room to spare.
    nonisolated static let thumbnailPixels = 360
    static let activityID = "screenshots.new"

    public let id: ModuleID = .screenshots
    public let title = "Screenshots"
    public let symbol = "camera.viewfinder"
    public let placement: PanelPlacement = .page(order: 30)

    public enum Status: Sendable, Equatable {
        /// Not asked for yet (or switched off): no query, no file access. The page offers "Show screenshots".
        case off
        /// The Spotlight query is live.
        case watching
    }

    public private(set) var status: Status = .off
    /// Newest first.
    public var screenshots: [Screenshot] { list.items }
    /// The most screenshots listed.
    public var capacity: Int { list.capacity }
    /// What touching the screenshot folder found on the last click this session; `nil` before one.
    public private(set) var folderAccess: FolderAccess?
    /// True when a converter is available (the Convert module is enabled). Looked up at use time.
    public var canConvert: Bool { context?.services.converter != nil }
    /// True when the Shelf is available.
    public var canShelve: Bool { context?.services.shelf != nil }
    /// A listed screenshot could not be read: the page explains how to allow access.
    public var needsAccess: Bool {
        list.items.contains { thumbnails[ThumbnailKey($0)] == .unreadable }
    }

    public var liveActivity: LiveActivity? {
        guard let announcement, context?.settings.get(Self.showBesideNotchKey) == true else { return nil }
        let shot = announcement.screenshot
        let image = thumbnails[ThumbnailKey(shot)]?.image
        return LiveActivity(
            id: Self.activityID, module: .screenshots, priority: .passive,
            leading: image.map(ActivityGlyph.image) ?? .symbol(symbol, tint: .accent),
            trailing: .text(Format.age(seconds: announcement.at.timeIntervalSince(shot.createdAt)), tint: .secondary),
            files: [shot.url],
            expiresAt: announcement.at.addingTimeInterval(Self.seconds(activityDuration)),
            updatedAt: announcement.at,
            accessibilityLabel: "New screenshot"
        )
    }

    private var list: ScreenshotList
    private var thumbnails: [ThumbnailKey: ThumbnailResult] = [:]
    private var announcement: Announcement?
    private var context: ModuleContext?

    @ObservationIgnored let source: any ScreenshotSource
    @ObservationIgnored private let thumbnailer: any ScreenshotThumbnailing
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let revealInFinder: @MainActor ([URL]) -> Void
    @ObservationIgnored private let openPrivacyPane: @MainActor () -> Void
    @ObservationIgnored private let activityDuration: Duration
    @ObservationIgnored private let pruneInterval: Duration
    @ObservationIgnored private let newWindow: TimeInterval
    /// Fixture mode: sample data, no source, no files.
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private var log: Logger?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var gathered = false
    /// Everything the source reported last, before the list's rules.
    @ObservationIgnored private var latest: [Screenshot] = []
    /// Files seen since watching began, so only screenshots taken from then on are announced.
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var inFlight: Set<ThumbnailKey> = []
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?

    /// - Parameters:
    ///   - source: finds screenshots (a live Spotlight query in the app).
    ///   - thumbnails: makes tile pictures (ImageIO in the app).
    ///   - now: clock for the 24-hour window and the live activity.
    ///   - reveal: selects files in Finder.
    ///   - openPrivacySettings: opens System Settings › Privacy & Security › Files and Folders.
    ///   - activityDuration: how long a new screenshot stays beside the notch.
    ///   - pruneInterval: how often screenshots that aged out of the window are dropped while running.
    ///   - newWindow: a file first reported later than this after it was taken (moved or copied in) is listed, not announced.
    ///   - capacity: the most screenshots listed.
    public init(
        source: any ScreenshotSource = SpotlightScreenshotSource(),
        thumbnails: any ScreenshotThumbnailing = ImageIOThumbnails(),
        now: @escaping @MainActor () -> Date = { Date() },
        reveal: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openPrivacySettings: @escaping @MainActor () -> Void = ScreenshotsModule.openFilesAndFoldersSettings,
        activityDuration: Duration = .seconds(6),
        pruneInterval: Duration = .seconds(60),
        newWindow: TimeInterval = 120,
        capacity: Int = ScreenshotList.defaultCapacity
    ) {
        self.source = source
        self.thumbnailer = thumbnails
        self.now = now
        self.revealInFinder = reveal
        self.openPrivacyPane = openPrivacySettings
        self.activityDuration = activityDuration
        self.pruneInterval = pruneInterval
        self.newWindow = newWindow
        self.list = ScreenshotList(capacity: capacity)
        self.isFixture = false
    }

    private init(fixture screenshots: [Screenshot], thumbnails: [String: SendableImage], now: Date) {
        source = NoScreenshotSource()
        thumbnailer = PreparedThumbnails(images: thumbnails)
        self.now = { Date() }
        revealInFinder = { _ in }
        openPrivacyPane = {}
        activityDuration = .seconds(6)
        pruneInterval = .seconds(3600)
        newWindow = 120
        list = ScreenshotList(screenshots, now: now)
        isFixture = true
        var prepared: [ThumbnailKey: ThumbnailResult] = [:]
        for shot in screenshots {
            if let image = thumbnails[shot.url.path] { prepared[ThumbnailKey(shot)] = .image(image) }
        }
        self.thumbnails = prepared
        latest = screenshots
        status = .watching
    }

    /// The module the app runs: Spotlight and ImageIO. Dormant until the user asks for screenshots.
    public static func live() -> ScreenshotsModule { ScreenshotsModule() }

    /// Invented screenshots with generated pictures, already showing. Touches no files and no Spotlight.
    public static func sample() -> ScreenshotsModule {
        let now = Date()
        let (screenshots, thumbnails) = ScreenshotSamples.make(now: now)
        return ScreenshotsModule(fixture: screenshots, thumbnails: thumbnails, now: now)
    }

    public static func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        self.context = context
        log = context.log
        if !isFixture {
            // `mayPrompt` means the user asked for this module's feature in onboarding or Settings: that is the
            // consent the "Show screenshots" button would otherwise collect.
            if context.mayPrompt, !context.settings.get(Self.enabledKey) { context.settings.set(Self.enabledKey, true) }
            if context.settings.get(Self.enabledKey) {
                // Without `mayPrompt` only the query runs here: it reads the Spotlight index, never a file.
                beginWatching(requestingAccess: context.mayPrompt)
            }
            schedulePruning()
        }
        context.log.notice("started")
    }

    /// Stops the query and every task. `start` on the same instance picks up again from the settings.
    public func stop() {
        running = false
        pruneTask?.cancel(); pruneTask = nil
        stopWatching()
    }

    // MARK: User actions

    /// The click on "Show screenshots" (or the Settings switch): the consent to search and to read the files.
    public func enable() {
        guard let context, !isFixture else { return }
        context.settings.set(Self.enabledKey, true)
        beginWatching(requestingAccess: true)
    }

    /// Stops looking and forgets everything listed. No file is touched.
    public func disable() {
        guard !isFixture else { return }
        context?.settings.set(Self.enabledKey, false)
        stopWatching()
    }

    /// "Try again" after macOS refused access: asks again and restarts the query.
    public func retry() {
        guard !isFixture, context?.settings.get(Self.enabledKey) == true else { return }
        stopWatching()
        beginWatching(requestingAccess: true)
    }

    public func reveal(_ shot: Screenshot) { revealInFinder([shot.url]) }

    /// The WebP lands next to the screenshot (the converter's rule for files).
    public func convert(_ shot: Screenshot) {
        context?.services.converter?.convert([.file(shot.url)])
    }

    /// Puts a reference on the shelf. `.dropped` is the origin for a file the user put there by hand.
    public func addToShelf(_ shot: Screenshot) {
        context?.services.shelf?.add([shot.url], origin: .dropped)
    }

    public func openPrivacySettings() { openPrivacyPane() }

    /// Reads the tiles that could not be read once more (access may have been allowed since). Each keeps its
    /// lock until a read succeeds, so the page does not flicker.
    public func retryUnreadable() async {
        for shot in list.items where thumbnails[ThumbnailKey(shot)] == .unreadable {
            await loadThumbnail(for: shot, retrying: true)
        }
    }

    // MARK: Watching

    private func beginWatching(requestingAccess: Bool) {
        guard !isFixture else { status = .watching; return }
        guard status != .watching else { return }
        Motion.animate(Motion.morph) { status = .watching }
        gathered = false
        guard requestingAccess else { startSource(); return }
        accessTask?.cancel()
        accessTask = Task { [weak self] in
            guard let self else { return }
            // Touch the folder first, so that if Spotlight leaves out folders the app may not read,
            // the first results already include it once access is allowed.
            let access = await self.source.requestFolderAccess()
            guard !Task.isCancelled, self.status == .watching else { return }
            self.folderAccess = access
            self.startSource()
        }
    }

    private func startSource() {
        source.start { [weak self] batch in self?.receive(batch) }
    }

    private func stopWatching() {
        accessTask?.cancel(); accessTask = nil
        announceTask?.cancel(); announceTask = nil
        source.stop()
        guard !isFixture else { announcement = nil; return }
        Motion.animate(Motion.morph) {
            status = .off
            list.removeAll()
        }
        announcement = nil
        thumbnails.removeAll()
        latest = []
        seen = []
        gathered = false
        folderAccess = nil
    }

    private func receive(_ batch: ScreenshotBatch) {
        guard status == .watching, !isFixture else { return }
        let known = seen
        for shot in batch.screenshots { seen.insert(shot.dedupeKey) }
        latest = batch.screenshots
        rebuild()
        if batch.isInitial { gathered = true; return }
        // What was there when watching began is listed, never announced.
        guard gathered else { return }
        let stamp = now()
        let fresh = list.items.filter { !known.contains($0.dedupeKey) && stamp.timeIntervalSince($0.createdAt) <= newWindow }
        if let newest = fresh.first {
            log?.info("new screenshot \(newest.name, privacy: .private)")
            announce(newest)
        }
    }

    /// Applies the list's rules to the latest results, leaving out files found to be gone.
    private func rebuild() {
        let current = latest.filter { thumbnails[ThumbnailKey($0)] != .missing }
        var next = list
        next.replace(with: current, now: now())
        if next != list { Motion.animate(Motion.morph) { list = next } }
        dropUnusedThumbnails()
    }

    private func schedulePruning() {
        pruneTask?.cancel()
        let interval = pruneInterval
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if self.status == .watching { self.rebuild() }
            }
        }
    }

    // MARK: Live activity

    private struct Announcement: Equatable {
        let screenshot: Screenshot
        let at: Date
    }

    private func announce(_ shot: Screenshot) {
        announceTask?.cancel()
        let duration = activityDuration
        announceTask = Task { [weak self] in
            // The picture first, so the wing opens with the thumbnail rather than swapping a symbol for it.
            await self?.loadThumbnail(for: shot)
            guard let self, !Task.isCancelled, self.status == .watching,
                  self.thumbnails[ThumbnailKey(shot)] != .missing
            else { return }
            self.announcement = Announcement(screenshot: shot, at: self.now())
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.announcement = nil
            self.dropUnusedThumbnails()
        }
    }

    // MARK: Thumbnails

    struct ThumbnailKey: Hashable {
        let path: String
        let modified: Date?
        init(_ shot: Screenshot) { path = shot.dedupeKey; modified = shot.modifiedAt }
    }

    func thumbnail(for shot: Screenshot) -> ThumbnailResult? { thumbnails[ThumbnailKey(shot)] }

    /// Reads the file for its picture, off the main actor, once per file and modification date.
    /// The only place the module opens a screenshot; never before the user asked for screenshots.
    /// - Parameter retrying: read again a file that could not be read before; the old result stays until this one is better.
    func loadThumbnail(for shot: Screenshot, retrying: Bool = false) async {
        guard status == .watching else { return }
        let key = ThumbnailKey(shot)
        let wanted = thumbnails[key] == nil || (retrying && thumbnails[key] == .unreadable)
        guard wanted, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let result = await thumbnailer.thumbnail(for: shot.url, maxPixelSize: Self.thumbnailPixels)
        guard status == .watching, latest.contains(where: { ThumbnailKey($0) == key }), thumbnails[key] != result else { return }
        Motion.animate(Motion.quick) { thumbnails[key] = result }
        switch result {
        case .missing:
            log?.info("screenshot gone \(shot.name, privacy: .private)")
            rebuild()
        case .unreadable:
            log?.info("screenshot unreadable \(shot.name, privacy: .private)")
        case .image:
            break
        }
    }

    /// Keeps pictures for listed screenshots and the one beside the notch, and the "gone" marks the source still reports.
    private func dropUnusedThumbnails() {
        var keep = Set(list.items.map(ThumbnailKey.init))
        if let announcement { keep.insert(ThumbnailKey(announcement.screenshot)) }
        let reported = Set(latest.map(ThumbnailKey.init))
        for (key, value) in thumbnails where !keep.contains(key) && !(value == .missing && reported.contains(key)) {
            thumbnails[key] = nil
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(ScreenshotsPage(module: self)) }

    public func settingsView() -> AnyView? {
        guard let settings = context?.settings else { return nil }
        return AnyView(ScreenshotsSettings(module: self, settings: settings))
    }
}

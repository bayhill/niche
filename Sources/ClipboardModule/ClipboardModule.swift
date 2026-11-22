import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// Where the history stands.
public enum ClipboardStatus: Sendable, Equatable {
    /// The user has not turned it on (the default). The pasteboard is not touched at all.
    case off
    /// Turned on earlier, but reading now could raise the system's paste alert and nobody asked this session.
    /// Waits for a click on "Resume".
    case paused
    /// Polling the change count and recording copies.
    case monitoring
    /// macOS denies Niche pasteboard access (System Settings). Nothing is read.
    case denied
}

/// The app in front when something was copied.
public struct FrontmostApp: Sendable, Equatable {
    public var bundleID: String?
    /// Display name, e.g. "Safari".
    public var name: String?
    public init(bundleID: String?, name: String?) { self.bundleID = bundleID; self.name = name }

    @MainActor public static func current() -> FrontmostApp? {
        NSWorkspace.shared.frontmostApplication.map { FrontmostApp(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
    }
}

/// Recent copied text and images, in memory only. Click to copy again; convert a copied image to WebP.
@MainActor
@Observable
public final class ClipboardModule: NotchModule {
    public static let enabledKey = SettingsKey<Bool>("clipboard.enabled", default: false)
    /// Number of text entries kept; image entries scale with it (see `ClipboardLimits(historySize:)`).
    public static let historySizeKey = SettingsKey<Int>("clipboard.historySize", default: 50)
    public static let historySizes = [10, 25, 50]
    /// Put files copied in Finder on the Shelf. Off by default: the Shelf keeps its items on disk until they are removed.
    public static let filesToShelfKey = SettingsKey<Bool>("clipboard.filesToShelf", default: false)

    public let id: ModuleID = .clipboard
    public let title = "Clipboard"
    public let symbol = "doc.on.clipboard"
    public let placement: PanelPlacement = .page(order: 20)
    public let requirements = [
        PermissionRequirement(
            .pasteboard, optional: true,
            rationale: "Keeps recently copied text and images in memory so they can be pasted again."
        ),
    ]

    public private(set) var status: ClipboardStatus = .off
    public private(set) var history: ClipboardHistory
    /// The entry that was just copied back, for a brief confirmation.
    public private(set) var confirmedID: ClipboardEntry.ID?
    public var entries: [ClipboardEntry] { history.entries }
    /// The most entries kept (the "history size").
    public var capacity: Int { history.limits.maxEntries }
    /// True when a converter is available (the Convert module is enabled).
    public var canConvert: Bool { context?.services.converter != nil }

    private var thumbnails: [ClipboardEntry.ID: SendableImage] = [:]
    private var context: ModuleContext?

    @ObservationIgnored private let pasteboard: any PasteboardAccessing
    @ObservationIgnored private let frontmostApp: @MainActor () -> FrontmostApp?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let openPrivacySettings: @MainActor () -> Void
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var confirmTask: Task<Void, Never>?
    @ObservationIgnored private var lastChangeCount: Int?
    @ObservationIgnored private var ownChangeCount: Int?
    /// Why the most recent change was not recorded (for tests and debugging).
    @ObservationIgnored public private(set) var lastSkip: ClipboardSkip?

    /// - Parameters:
    ///   - pasteboard: the general pasteboard in the app; a fake or a uniquely named pasteboard in tests.
    ///   - frontmostApp: the app in front, for the password-manager rule and the clip's source.
    ///   - now: clock for entry timestamps.
    ///   - pollInterval: how often the change count is checked while monitoring.
    ///   - openPrivacySettings: opens System Settings › Privacy & Security.
    public init(
        pasteboard: any PasteboardAccessing,
        frontmostApp: @escaping @MainActor () -> FrontmostApp? = { FrontmostApp.current() },
        now: @escaping @MainActor () -> Date = { Date() },
        pollInterval: Duration = .milliseconds(500),
        openPrivacySettings: @escaping @MainActor () -> Void = ClipboardModule.openSystemPrivacySettings
    ) {
        self.pasteboard = pasteboard
        self.frontmostApp = frontmostApp
        self.now = now
        self.pollInterval = pollInterval
        self.openPrivacySettings = openPrivacySettings
        self.history = ClipboardHistory()
        self.isFixture = false
    }

    private init(fixture entries: [ClipboardEntry], thumbnails: [ClipboardEntry.ID: SendableImage]) {
        pasteboard = InMemoryPasteboard()
        frontmostApp = { nil }
        now = { Date() }
        pollInterval = .seconds(3600)
        openPrivacySettings = {}
        history = ClipboardHistory(entries: entries)
        self.thumbnails = thumbnails
        status = .monitoring
        isFixture = true
    }

    /// The history the app runs, over the general pasteboard. Off until the user turns it on.
    public static func live() -> ClipboardModule { ClipboardModule(pasteboard: SystemPasteboard.general()) }

    /// Built-in sample entries over an in-memory pasteboard. Never touches the real pasteboard.
    public static func sample() -> ClipboardModule {
        let (entries, thumbnails) = ClipboardSamples.make(now: Date())
        return ClipboardModule(fixture: entries, thumbnails: thumbnails)
    }

    public static func openSystemPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        self.context = context
        if !isFixture {
            history.limits = ClipboardLimits(historySize: context.settings.get(Self.historySizeKey))
            if context.settings.get(Self.enabledKey) {
                // Reading could raise the system alert; only do it unprompted if macOS already allows it silently.
                if context.mayPrompt || pasteboard.access == .allowed { beginMonitoring() } else { status = pasteboard.access == .denied ? .denied : .paused }
            } else {
                status = .off
            }
        }
        context.log.notice("started")
    }

    /// Stops polling at once and, outside fixtures, forgets every clip: a switched-off module keeps nothing.
    /// `start` on the same instance picks up again from the settings.
    public func stop() {
        running = false
        stopPolling()
        confirmTask?.cancel(); confirmTask = nil
        confirmedID = nil
        guard !isFixture else { return }
        history.clear()
        thumbnails.removeAll()
        status = .off
        lastChangeCount = nil
        ownChangeCount = nil
    }

    // MARK: User actions

    /// The user's click on "Turn on" is the consent to read the pasteboard.
    public func turnOn() {
        context?.settings.set(Self.enabledKey, true)
        beginMonitoring()
    }

    /// Stops reading and forgets everything.
    public func turnOff() {
        context?.settings.set(Self.enabledKey, false)
        stopPolling()
        Motion.animate(Motion.morph) {
            history.clear()
            status = .off
        }
        thumbnails.removeAll()
    }

    /// Resume after a relaunch (`paused`) or retry after a denial.
    public func resume() { beginMonitoring() }

    public func openSettings() { openPrivacySettings() }

    public func setHistorySize(_ size: Int) {
        context?.settings.set(Self.historySizeKey, size)
        Motion.animate(Motion.morph) { history.limits = ClipboardLimits(historySize: size) }
        dropUnusedThumbnails()
    }

    public func clear() {
        Motion.animate(Motion.morph) { history.clear() }
        thumbnails.removeAll()
    }

    public func remove(_ id: ClipboardEntry.ID) {
        Motion.animate(Motion.morph) { history.remove(id) }
        dropUnusedThumbnails()
    }

    /// Puts the entry back on the pasteboard and moves it to the front. Our own write is not recorded again.
    public func copy(_ entry: ClipboardEntry) {
        let count = pasteboard.write(entry.content)
        ownChangeCount = count
        lastChangeCount = count
        Motion.animate(Motion.morph) {
            history.promote(entry.id)
            confirmedID = entry.id
        }
        Haptics.tick()
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            Motion.animate(Motion.morph) { self.confirmedID = nil }
        }
    }

    /// Hands a copied image to the Convert module; the WebP lands in Downloads.
    public func convert(_ entry: ClipboardEntry) {
        guard case .image(let data, _) = entry.content else { return }
        context?.services.converter?.convert([.imageData(data, name: Self.conversionName(for: entry.copiedAt))])
    }

    static func conversionName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Clipboard \(formatter.string(from: date))"
    }

    // MARK: Monitoring

    private func beginMonitoring() {
        guard !isFixture else { status = .monitoring; return }
        stopPolling()
        if pasteboard.access == .denied {
            status = .denied
            return
        }
        // What was on the pasteboard before monitoring began is not recorded.
        lastChangeCount = pasteboard.changeCount
        Motion.animate(Motion.morph) { status = .monitoring }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll: reads the contents only when the change count moved. Called by the timer; tests call it directly.
    public func poll() {
        guard status == .monitoring, !isFixture else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == ownChangeCount { return }
        if pasteboard.access == .denied {
            stopPolling()
            status = .denied
            return
        }
        let app = frontmostApp()
        let acceptFiles = context?.settings.get(Self.filesToShelfKey) == true && context?.services.shelf != nil
        switch ClipboardPolicy.evaluate(pasteboard, frontmostBundleID: app?.bundleID, limits: history.limits, acceptFiles: acceptFiles) {
        case .skip(let reason):
            lastSkip = reason
        case .files(let urls):
            // Opted in: Finder copies go to the Shelf as references; they never become clipboard entries.
            lastSkip = nil
            context?.services.shelf?.add(urls, origin: .clipboard)
        case .record(let content):
            lastSkip = nil
            record(content, from: app?.name)
        }
    }

    private func record(_ content: ClipboardContent, from sourceApp: String?) {
        let entry = ClipboardEntry(content: content, copiedAt: now(), sourceApp: sourceApp)
        var added = false
        Motion.animate(Motion.morph) { added = history.record(entry) }
        guard added else { return }
        dropUnusedThumbnails()
        if case .image(let data, _) = content { loadThumbnail(for: entry.id, data: data) }
    }

    // MARK: Thumbnails

    func thumbnail(for id: ClipboardEntry.ID) -> SendableImage? { thumbnails[id] }

    private func loadThumbnail(for id: ClipboardEntry.ID, data: Data) {
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { ClipboardImages.thumbnail(of: data, maxPixels: 360) }.value
            guard let self, let image, self.history.entries.contains(where: { $0.id == id }) else { return }
            Motion.animate(Motion.quick) { self.thumbnails[id] = image }
        }
    }

    private func dropUnusedThumbnails() {
        let live = Set(history.entries.map(\.id))
        for key in thumbnails.keys where !live.contains(key) { thumbnails[key] = nil }
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(ClipboardPage(module: self)) }

    public func settingsView() -> AnyView? {
        guard let settings = context?.settings else { return nil }
        return AnyView(ClipboardSettings(module: self, settings: settings))
    }
}

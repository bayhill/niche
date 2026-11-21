import AppKit
import NotchCore
import Observation
import os
import SwiftUI

/// A temporary holding area for files: drop them on the notch, drag them out somewhere else later.
/// Stores references only. It never copies, moves, renames or deletes the files themselves.
@MainActor
@Observable
public final class ShelfModule: NotchModule, ShelfAccepting {
    public let id: ModuleID = .shelf
    public let title = "Shelf"
    public let symbol = "tray.full"
    public let placement: PanelPlacement = .page(order: 10)
    public private(set) var liveActivity: LiveActivity?

    /// Newest first.
    public var items: [ShelfItem] { list.items }
    /// The most items the shelf keeps.
    public var capacity: Int { list.capacity }

    private var list: ShelfList
    private var thumbnailCache: [String: SendableImage] = [:]

    @ObservationIgnored private let thumbnailer: any ShelfThumbnailing
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let revealInFinder: @MainActor ([URL]) -> Void
    @ObservationIgnored private let pruneInterval: Duration
    @ObservationIgnored private let confirmationDuration: Duration
    /// Fixture mode: no loading, saving or pruning.
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private var storeURL: URL?
    @ObservationIgnored private var log: Logger?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var recentlyAdded = 0
    @ObservationIgnored private var thumbnailsInFlight: Set<String> = []

    /// - Parameters:
    ///   - thumbnails: makes tile pictures (QuickLook in the app).
    ///   - now: clock for `addedAt` and the confirmation activity.
    ///   - reveal: what a click on a tile does (select in Finder in the app).
    ///   - pruneInterval: how often entries whose file disappeared are dropped while running.
    ///   - confirmationDuration: how long the "+3" confirmation stays beside the notch after a drop.
    ///   - capacity: maximum number of items.
    public init(
        thumbnails: any ShelfThumbnailing = QuickLookThumbnails(),
        now: @escaping @MainActor () -> Date = { Date() },
        reveal: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        pruneInterval: Duration = .seconds(60),
        confirmationDuration: Duration = .seconds(2),
        capacity: Int = ShelfList.defaultCapacity
    ) {
        self.thumbnailer = thumbnails
        self.now = now
        self.revealInFinder = reveal
        self.pruneInterval = pruneInterval
        self.confirmationDuration = confirmationDuration
        self.list = ShelfList(capacity: capacity)
        self.isFixture = false
    }

    private init(fixtureItems: [ShelfItem], thumbnails: [String: SendableImage]) {
        self.thumbnailer = NoThumbnails()
        self.now = { Date() }
        self.revealInFinder = { _ in }
        self.pruneInterval = .seconds(3600)
        self.confirmationDuration = .seconds(2)
        self.list = ShelfList(fixtureItems)
        self.thumbnailCache = thumbnails
        self.isFixture = true
    }

    /// The shelf the app runs: QuickLook thumbnails, persisted under `appSupport`.
    public static func live() -> ShelfModule { ShelfModule() }

    /// Built-in sample items with generated thumbnails. Touches no files.
    public static func sample() -> ShelfModule {
        let (items, thumbnails) = ShelfSamples.make()
        return ShelfModule(fixtureItems: items, thumbnails: thumbnails)
    }

    // MARK: Lifecycle

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        log = context.log
        if !isFixture {
            let url = ShelfFiles.storeURL(in: context.directories)
            storeURL = url
            let loaded = await Task.detached { ShelfFiles.resolve(ShelfFiles.load(from: url)) }.value
            // Anything added before start (unlikely) stays in front of what was saved.
            list.replace(with: list.items + loaded)
            save()
            schedulePruning()
        }
        context.log.notice("started")
    }

    public func stop() {
        running = false
        pruneTask?.cancel(); pruneTask = nil
        activityTask?.cancel(); activityTask = nil
        liveActivity = nil
        recentlyAdded = 0
    }

    private func schedulePruning() {
        pruneTask?.cancel()
        let interval = pruneInterval
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.prune()
            }
        }
    }

    // MARK: Shelf operations

    /// `ShelfAccepting`: other modules (Convert) put their outputs here. Non-file URLs are ignored.
    public func add(_ urls: [URL], origin: ShelfOrigin) {
        let fresh = urls.filter(\.isFileURL).map { ShelfFiles.makeItem(for: $0, origin: origin, now: now()) }
        guard !fresh.isEmpty else { return }
        Motion.animate(Motion.morph) { list.add(fresh) }
        dropUnusedThumbnails()
        save()
    }

    /// Forgets one item. The file is not touched.
    public func remove(_ id: ShelfItem.ID) {
        Motion.animate(Motion.morph) { _ = list.remove(id: id) }
        dropUnusedThumbnails()
        save()
    }

    /// Forgets every item. No file is touched.
    public func clear() {
        Motion.animate(Motion.morph) { list.removeAll() }
        thumbnailCache.removeAll()
        save()
    }

    public func reveal(_ item: ShelfItem) { revealInFinder([item.url]) }

    /// Drops entries whose file is gone or in the Trash and follows files that moved.
    public func prune() async {
        guard !isFixture else { return }
        let snapshot = list.items
        let resolved = await Task.detached { ShelfFiles.resolve(snapshot) }.value
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let checked = Set(snapshot.map(\.id))
        // Items added while resolving were not checked; keep them as they are.
        let merged = list.items.compactMap { checked.contains($0.id) ? byID[$0.id] : $0 }
        guard merged != list.items else { return }
        Motion.animate(Motion.morph) { list.replace(with: merged) }
        dropUnusedThumbnails()
        save()
    }

    private func save() {
        guard !isFixture, let storeURL else { return }
        do { try ShelfFiles.save(list.items, to: storeURL) } catch {
            log?.error("saving shelf failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Thumbnails

    static let thumbnailSide: CGFloat = 96

    private static func cacheKey(_ item: ShelfItem) -> String { "\(item.path)|\(item.size ?? -1)" }

    func thumbnail(for item: ShelfItem) -> SendableImage? { thumbnailCache[Self.cacheKey(item)] }

    func loadThumbnail(for item: ShelfItem) async {
        let key = Self.cacheKey(item)
        guard thumbnailCache[key] == nil, !thumbnailsInFlight.contains(key) else { return }
        thumbnailsInFlight.insert(key)
        defer { thumbnailsInFlight.remove(key) }
        guard let image = await thumbnailer.thumbnail(for: item.url, side: Self.thumbnailSide, scale: 2) else { return }
        guard list.items.contains(where: { Self.cacheKey($0) == key }) else { return }
        Motion.animate(Motion.quick) { thumbnailCache[key] = image }
    }

    private func dropUnusedThumbnails() {
        let live = Set(list.items.map(Self.cacheKey))
        for key in thumbnailCache.keys where !live.contains(key) { thumbnailCache[key] = nil }
    }

    // MARK: Drops

    public func dropAcceptance(for item: DropItem) -> DropAcceptance {
        item.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject
    }

    public func dropHint(for items: [DropItem]) -> DropHint? {
        let count = items.filter { $0.fileURL != nil }.count
        guard count > 0 else { return nil }
        return DropHint(title: "Add to Shelf", subtitle: count == 1 ? "1 item" : "\(count) items", symbol: "tray.and.arrow.down")
    }

    public func handleDrop(_ payload: DropPayload) async {
        let urls = payload.items.compactMap(\.fileURL)
        guard !urls.isEmpty else { return }
        let before = Set(list.items.map(\.id))
        add(urls, origin: .dropped)
        let added = list.items.filter { !before.contains($0.id) }.count
        if added > 0 { confirmAdded(added) }
    }

    /// A brief "+3" beside the notch. Consecutive drops add up while it is showing.
    private func confirmAdded(_ count: Int) {
        recentlyAdded += count
        let stamp = now()
        let total = recentlyAdded
        liveActivity = LiveActivity(
            id: "shelf.added", module: .shelf, priority: .passive,
            leading: .symbol("tray.and.arrow.down.fill", tint: .accent), trailing: .text("+\(total)"),
            expiresAt: stamp.addingTimeInterval(Self.seconds(confirmationDuration)), updatedAt: stamp,
            accessibilityLabel: total == 1 ? "Added 1 item to the Shelf" : "Added \(total) items to the Shelf"
        )
        activityTask?.cancel()
        let duration = confirmationDuration
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.liveActivity = nil
            self.recentlyAdded = 0
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    // MARK: UI

    public func panelView() -> AnyView { AnyView(ShelfPage(module: self)) }
}

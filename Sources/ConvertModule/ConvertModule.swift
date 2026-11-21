import AppKit
import Foundation
import ImageEngine
import NotchCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Runs conversions. `ConversionQueue` in the app; scripted fakes in tests; a simulation in `sample()`.
public protocol ConversionRunning: Sendable {
    func submit(_ jobs: [ConversionJob], options: EncodeOptions) -> AsyncStream<ConversionEvent>
}

extension ConversionQueue: ConversionRunning {}

/// One file on the card, from the moment it is queued until it scrolls out of the history.
public struct ConvertRow: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        /// `nil` until the engine reports progress.
        case converting(Double?)
        case done(output: URL, inputBytes: Int64, outputBytes: Int64)
        /// A short reason.
        case failed(String)
    }

    /// The conversion job's id.
    public let id: UUID
    /// Rows from one batch share this; a batch that grows while running keeps it.
    public let batch: Int
    /// The source file name (or the suggested name of dropped image data).
    public var name: String
    public var state: State
    public var notes: [String] = []
    public var thumbnail: SendableImage?

    public init(id: UUID = UUID(), batch: Int, name: String, state: State, notes: [String] = [], thumbnail: SendableImage? = nil) {
        self.id = id; self.batch = batch; self.name = name; self.state = state; self.notes = notes; self.thumbnail = thumbnail
    }

    public var output: URL? { if case .done(let url, _, _) = state { url } else { nil } }
    public var isActive: Bool {
        switch state {
        case .waiting, .converting: true
        case .done, .failed: false
        }
    }
    /// `1 - output/input` for a finished row.
    public var savedFraction: Double? {
        guard case .done(_, let input, let output) = state, input > 0 else { return nil }
        return 1 - Double(output) / Double(input)
    }

    /// The row's second line.
    public var detail: String {
        switch state {
        case .waiting: "Waiting"
        case .converting: "Converting\u{2026}"
        case .done(_, let input, let output): "\(Format.bytes(input)) \u{2192} \(Format.bytes(output))"
        case .failed(let reason): reason
        }
    }

    /// The trailing figure: the saving for a finished row.
    public var figure: String? { savedFraction.map(Format.saving) }

    /// A saving is `success`; no change or growth is information, so `secondary`.
    public var figureTint: TintRole { (savedFraction ?? 0) >= 0.005 ? .success : .secondary }
}

/// Counters for the batch in flight (or the one whose summary is still showing).
public struct BatchProgress: Equatable, Sendable {
    public var id: Int
    public var total = 0
    public var succeeded = 0
    public var failed = 0
    public var inputBytes: Int64 = 0
    public var outputBytes: Int64 = 0

    public init(id: Int, total: Int = 0) { self.id = id; self.total = total }

    public var completed: Int { succeeded + failed }
    public var isRunning: Bool { completed < total }
    /// Over the successful files; `nil` when nothing succeeded.
    public var savedFraction: Double? { inputBytes > 0 && succeeded > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : nil }
}

/// Drop images on the notch, get WebPs next to them with the last-used settings.
@MainActor
@Observable
public final class ConvertModule: NotchModule, ImageConverting {
    public let id: ModuleID = .convert
    public let title = "Convert"
    public let symbol = "photo"
    public let placement: PanelPlacement = .dashboard(.trailing)

    public private(set) var liveActivity: LiveActivity?
    /// Newest batch first, files in drop order within a batch. Older batches keep at most `visibleLimit` rows.
    public private(set) var rows: [ConvertRow] = []
    public private(set) var batch: BatchProgress?
    /// The card is showing its inline options.
    public var showingOptions = false

    /// Rows that fit the card.
    public static let visibleLimit = 3
    /// How long the finished summary stays beside the notch.
    public static let summaryDuration: TimeInterval = 4
    static let activityID = "convert.batch"

    @ObservationIgnored private let runner: any ConversionRunning
    @ObservationIgnored private var injectedSettings: SettingsStore?
    @ObservationIgnored private let injectedFallback: URL?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let thumbnailer: @Sendable (URL) async -> SendableImage?
    @ObservationIgnored private let reveal: @MainActor (URL) -> Void
    @ObservationIgnored private let haptic: @MainActor () -> Void
    @ObservationIgnored private let forwardsToShelf: Bool
    @ObservationIgnored private var context: ModuleContext?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var nextBatchID = 0
    @ObservationIgnored private lazy var detachedSettings = SettingsStore.ephemeral()

    /// - Parameters:
    ///   - runner: does the work.
    ///   - settings: overrides the store from `ModuleContext` (tests, sample).
    ///   - fallbackDirectory: overrides `ModuleContext.directories.downloads`.
    ///   - now: clock for activity timestamps and expiry.
    ///   - sleep: waits before clearing the finished summary.
    ///   - thumbnailer: makes a row thumbnail from an output file.
    ///   - reveal: shows a file in Finder.
    public init(
        runner: any ConversionRunning,
        settings: SettingsStore? = nil,
        fallbackDirectory: URL? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        thumbnailer: @escaping @Sendable (URL) async -> SendableImage? = ConvertModule.makeThumbnail,
        reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        haptic: @escaping @MainActor () -> Void = { Haptics.success() },
        forwardsToShelf: Bool = true
    ) {
        self.runner = runner; self.injectedSettings = settings; self.injectedFallback = fallbackDirectory
        self.now = now; self.sleep = sleep; self.thumbnailer = thumbnailer; self.reveal = reveal; self.haptic = haptic
        self.forwardsToShelf = forwardsToShelf
    }

    /// The app's module: a real `ConversionQueue`, settings and Downloads from the `ModuleContext`.
    public static func live() -> ConvertModule {
        ConvertModule(runner: ConversionQueue(maxConcurrent: ConversionQueue.defaultConcurrency))
    }

    // MARK: - Settings

    public var settings: SettingsStore { injectedSettings ?? context?.settings ?? detachedSettings }
    public var options: EncodeOptions { ConvertSettings.options(from: settings) }

    public func setQuality(_ value: Int) { settings.set(ConvertSettings.quality, min(100, max(0, value))) }
    public func stepQuality(by steps: Int) {
        let step = ConvertSettings.qualityStep
        let current = options.quality
        let snapped = steps > 0 ? (current / step + steps) * step : ((current + step - 1) / step + steps) * step
        setQuality(snapped)
    }
    public func toggleLossless() { settings.set(ConvertSettings.lossless, !options.lossless) }
    public func toggleStripMetadata() { settings.set(ConvertSettings.stripMetadata, !options.stripMetadata) }
    public func cycleMaxEdge() {
        let choices = ConvertSettings.maxEdgeChoices
        let i = choices.firstIndex(of: options.maxPixelEdge) ?? 0
        settings.set(ConvertSettings.maxPixelEdge, choices[(i + 1) % choices.count])
    }

    // MARK: - Card state

    /// What the header shows on the right: "2/5" while working, otherwise the format label ("WebP", "WebP 60").
    public var headerTrailing: String {
        if let batch, batch.isRunning { return "\(batch.completed)/\(batch.total)" }
        return ConvertSettings.formatLabel(options)
    }

    /// The rows that fit the card. While working, the window follows the work: the last finished file, then
    /// the files converting, then those waiting. At rest it shows the end of the newest batch.
    public var visibleRows: [ConvertRow] {
        let limit = Self.visibleLimit
        guard rows.count > limit else { return rows }
        var start: Int
        if let firstActive = rows.firstIndex(where: \.isActive) {
            start = max(0, firstActive - 1)
        } else {
            let newest = rows[0].batch
            let end = rows.firstIndex { $0.batch != newest } ?? rows.count
            start = max(0, end - limit)
        }
        start = min(start, rows.count - limit)
        return Array(rows[start..<start + limit])
    }

    /// The row whose ring the wing's progress ring flies into.
    public var heroRowID: UUID? {
        rows.first { if case .converting = $0.state { true } else { false } }?.id
    }

    /// Batch progress including the files part-way through.
    var batchFraction: Double {
        guard let batch, batch.total > 0 else { return 0 }
        let partial = rows.lazy.filter { $0.batch == batch.id }.reduce(0.0) { sum, row in
            if case .converting(let p?) = row.state { sum + p } else { sum }
        }
        return min(1, (Double(batch.completed) + partial) / Double(batch.total))
    }

    // MARK: - NotchModule

    public func start(_ context: ModuleContext) async {
        guard self.context == nil else { return }
        self.context = context
        context.log.notice("started")
    }

    public func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        expiryTask?.cancel()
        expiryTask = nil
        if batch?.isRunning == true {
            rows.removeAll(where: \.isActive)
            batch = nil
            liveActivity = nil
        }
        context = nil
    }

    public func panelView() -> AnyView { AnyView(ConvertCard(module: self)) }

    public func settingsView() -> AnyView? { AnyView(ConvertSettingsForm(settings: settings)) }

    public func dropAcceptance(for item: DropItem) -> DropAcceptance {
        switch item {
        case .file(let url):
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), ImageDecoder.canConvert(type) else { return .reject }
            return .accept(weight: DropWeight.preferred)
        case .imageData:
            return .accept(weight: DropWeight.preferred)
        case .text:
            return .reject
        }
    }

    /// "Convert to WebP" / "3 images · ⌥ to shelve".
    public func dropHint(for items: [DropItem]) -> DropHint? {
        let count = max(1, items.count)
        let noun = count == 1 ? "image" : "images"
        return DropHint(title: "Convert to WebP", subtitle: "\(count) \(noun) \u{00B7} \u{2325} to shelve", symbol: symbol)
    }

    public func handleDrop(_ payload: DropPayload) async {
        let sources: [ConversionSource] = payload.items.compactMap { item in
            guard case .accept = dropAcceptance(for: item) else { return nil }
            switch item {
            case .file(let url): return .file(url)
            case .imageData(let data, let name): return .imageData(data, name: name ?? "Image")
            case .text: return nil
            }
        }
        convert(sources)
    }

    // MARK: - ImageConverting

    public func convert(_ sources: [ConversionSource]) {
        guard !sources.isEmpty else { return }
        let fallback = injectedFallback ?? context?.directories.downloads ?? AppDirectories.live.downloads
        let jobs = sources.map { source -> ConversionJob in
            switch source {
            case .file(let url): ConversionJob(source: .file(url), fallbackDirectory: fallback)
            case .imageData(let data, let name): ConversionJob(source: .data(data, name: name), fallbackDirectory: fallback)
            }
        }
        enqueue(jobs)
        let stream = runner.submit(jobs, options: options)
        let token = UUID()
        tasks[token] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
            self?.tasks[token] = nil
        }
    }

    // MARK: - Events

    private func enqueue(_ jobs: [ConversionJob]) {
        expiryTask?.cancel()
        expiryTask = nil
        Motion.animate(Motion.morph) {
            let batchID: Int
            let insertAt: Int
            if var current = batch, current.isRunning {
                // Files dropped while working join the batch, after its files.
                current.total += jobs.count
                batch = current
                batchID = current.id
                insertAt = rows.firstIndex { $0.batch != batchID } ?? rows.count
            } else {
                nextBatchID += 1
                batchID = nextBatchID
                batch = BatchProgress(id: batchID, total: jobs.count)
                insertAt = 0
            }
            let fresh = jobs.map { ConvertRow(id: $0.id, batch: batchID, name: $0.source.displayName, state: .waiting) }
            rows.insert(contentsOf: fresh, at: insertAt)
            trimHistory(keeping: batchID)
        }
        updateActivity()
    }

    /// Keeps every row of the current batch and at most `visibleLimit` older ones.
    private func trimHistory(keeping batchID: Int) {
        let current = rows.filter { $0.batch == batchID }
        let older = rows.filter { $0.batch != batchID }.prefix(Self.visibleLimit)
        rows = current + older
    }

    func handle(_ event: ConversionEvent) {
        let wasRunning = batch?.isRunning ?? false
        defer {
            if wasRunning, let batch, !batch.isRunning, batch.succeeded > 0 { haptic() }
        }
        switch event {
        case .progress:
            return
        case .started(let job):
            update(job.id, animation: Motion.morph) { $0.state = .converting(nil) }
        case .fileProgress(let job, let fraction):
            update(job.id, animation: Motion.morph) { row in
                if case .converting = row.state { row.state = .converting(fraction) }
            }
        case .succeeded(let job, let result):
            Motion.animate(Motion.morph) {
                if batch?.id == rowBatch(job.id) {
                    batch?.succeeded += 1
                    batch?.inputBytes += result.inputBytes
                    batch?.outputBytes += result.outputBytes
                }
                modify(job.id) { row in
                    row.state = .done(output: result.output, inputBytes: result.inputBytes, outputBytes: result.outputBytes)
                    row.notes = result.notes
                }
            }
            if forwardsToShelf { context?.services.shelf?.add([result.output], origin: .converted) }
            loadThumbnail(for: job.id, from: result.output)
        case .failed(let job, let error):
            Motion.animate(Motion.morph) {
                if batch?.id == rowBatch(job.id) { batch?.failed += 1 }
                modify(job.id) { $0.state = .failed(error.message) }
            }
        }
        updateActivity()
    }

    private func rowBatch(_ id: UUID) -> Int? { rows.first { $0.id == id }?.batch }

    private func modify(_ id: UUID, _ change: (inout ConvertRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }

    private func update(_ id: UUID, animation: Animation, _ change: (inout ConvertRow) -> Void) {
        Motion.animate(animation) { modify(id, change) }
    }

    private func loadThumbnail(for id: UUID, from url: URL) {
        let thumbnailer = self.thumbnailer
        Task { [weak self] in
            guard let image = await thumbnailer(url), let self else { return }
            self.update(id, animation: Motion.quick) { $0.thumbnail = image }
        }
    }

    private func updateActivity() {
        guard let batch else { liveActivity = nil; return }
        let stamp = now()
        if batch.isRunning {
            liveActivity = LiveActivity(
                id: Self.activityID, module: id, priority: .progress,
                leading: .progress(batchFraction), trailing: .text("\(batch.completed)/\(batch.total)"),
                updatedAt: stamp, accessibilityLabel: "Converting images to WebP, \(batch.completed) of \(batch.total) done"
            )
            return
        }
        guard liveActivity?.expiresAt == nil else { return }  // summary already showing

        let leading: ActivityGlyph
        let trailing: ActivityGlyph
        var label: String
        if let saved = batch.savedFraction {
            // A saving is success; growth is information (secondary); failures need a look (warning).
            let tint: TintRole = batch.failed > 0 ? .warning : (saved >= 0.005 ? .success : .secondary)
            leading = .symbol(batch.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", tint: tint)
            trailing = .text(Format.saving(saved))
            label = "Converted \(batch.succeeded) of \(batch.total) images to WebP, size \(Format.saving(saved))"
            if batch.failed > 0 { label += ", \(batch.failed) failed" }
        } else {
            leading = .symbol("exclamationmark.triangle.fill", tint: .warning)
            trailing = .text("Failed")
            label = batch.total == 1 ? "Conversion failed" : "All \(batch.total) conversions failed"
        }
        liveActivity = LiveActivity(
            id: Self.activityID, module: id, priority: .progress, leading: leading, trailing: trailing,
            expiresAt: stamp.addingTimeInterval(Self.summaryDuration), updatedAt: stamp, accessibilityLabel: label
        )
        scheduleExpiry(batch: batch.id)
    }

    private func scheduleExpiry(batch batchID: Int) {
        expiryTask?.cancel()
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            await sleep(.seconds(Self.summaryDuration))
            guard !Task.isCancelled, let self, self.batch?.id == batchID, self.batch?.isRunning == false else { return }
            Motion.animate(Motion.morph) {
                self.batch = nil
                self.liveActivity = nil
            }
        }
    }

    // MARK: - Card actions

    func open(_ row: ConvertRow) {
        guard let url = row.output else { return }
        reveal(url)
    }

    @concurrent
    public nonisolated static func makeThumbnail(_ url: URL) async -> SendableImage? {
        ImageDecoder.thumbnail(of: url, maxPixelSize: 56).map(SendableImage.init)
    }

    // MARK: - Sample state

    /// Replaces the visible state; used by `sample()`.
    func load(rows: [ConvertRow], batch: BatchProgress?) {
        self.rows = rows
        self.batch = batch
        nextBatchID = max(nextBatchID, (rows.map(\.batch) + [batch?.id ?? 0]).max() ?? 0)
        liveActivity = nil
        updateActivity()
    }
}

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

/// One line in the card's recent list.
public struct ConvertedItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Output file name on success; source name on failure.
    public var name: String
    public var output: URL?
    public var inputBytes: Int64
    public var outputBytes: Int64
    public var failure: String?
    public var notes: [String]
    public var thumbnail: SendableImage?

    public var savedFraction: Double { inputBytes > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : 0 }
    /// "1.2 MB → 264 KB" or the failure reason.
    public var detail: String { failure ?? "\(Format.bytes(inputBytes)) \u{2192} \(Format.bytes(outputBytes))" }

    public init(id: UUID = UUID(), name: String, output: URL?, inputBytes: Int64, outputBytes: Int64,
                failure: String? = nil, notes: [String] = [], thumbnail: SendableImage? = nil) {
        self.id = id; self.name = name; self.output = output; self.inputBytes = inputBytes; self.outputBytes = outputBytes
        self.failure = failure; self.notes = notes; self.thumbnail = thumbnail
    }
}

/// Counters for the batch in flight (or the one whose summary is still showing).
public struct BatchProgress: Equatable, Sendable {
    public var total = 0
    public var succeeded = 0
    public var failed = 0
    public var inputBytes: Int64 = 0
    public var outputBytes: Int64 = 0

    public init(total: Int = 0) { self.total = total }

    public var completed: Int { succeeded + failed }
    public var isRunning: Bool { completed < total }
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    /// Over the successful files; `nil` when nothing succeeded.
    public var savedFraction: Double? { inputBytes > 0 && succeeded > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : nil }
}

/// Drop images on the notch, get WebPs next to them with the last-used settings.
@MainActor
@Observable
public final class ConvertModule: NotchModule, ImageConverting {
    public let id: ModuleID = .convert
    public let title = "Convert"
    public let symbol = "photo.badge.arrow.down"
    public let placement: PanelPlacement = .dashboard(.center)

    public private(set) var liveActivity: LiveActivity?
    /// Newest first, at most `recentLimit`.
    public private(set) var recent: [ConvertedItem] = []
    public private(set) var batch: BatchProgress?
    /// The card is showing its inline options.
    public var showingOptions = false

    public static let recentLimit = 3
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
    @ObservationIgnored private var batchGeneration = 0
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
        if batch?.isRunning == true { batch = nil; liveActivity = nil }
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

    public func dropHint(for items: [DropItem]) -> DropHint? {
        DropHint(title: "Drop to convert to WebP", subtitle: ConvertSettings.summary(options), symbol: symbol)
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
        beginBatch(adding: jobs.count)
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

    private func beginBatch(adding count: Int) {
        expiryTask?.cancel()
        expiryTask = nil
        Motion.animate(Motion.morph) {
            if var current = batch, current.isRunning {
                current.total += count
                batch = current
            } else {
                batchGeneration += 1
                batch = BatchProgress(total: count)
            }
        }
        updateActivity()
    }

    func handle(_ event: ConversionEvent) {
        let wasRunning = batch?.isRunning ?? false
        defer {
            if wasRunning, let batch, !batch.isRunning, batch.succeeded > 0 { haptic() }
        }
        switch event {
        case .started, .progress:
            return
        case .succeeded(_, let result):
            let item = ConvertedItem(
                name: result.output.lastPathComponent, output: result.output,
                inputBytes: result.inputBytes, outputBytes: result.outputBytes, notes: result.notes
            )
            Motion.animate(Motion.morph) {
                batch?.succeeded += 1
                batch?.inputBytes += result.inputBytes
                batch?.outputBytes += result.outputBytes
                push(item)
            }
            if forwardsToShelf { context?.services.shelf?.add([result.output], origin: .converted) }
            loadThumbnail(for: item.id, from: result.output)
        case .failed(let job, let error):
            let item = ConvertedItem(name: job.source.displayName, output: nil, inputBytes: 0, outputBytes: 0, failure: error.message)
            Motion.animate(Motion.morph) {
                batch?.failed += 1
                push(item)
            }
        }
        updateActivity()
    }

    private func push(_ item: ConvertedItem) {
        recent.insert(item, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    private func loadThumbnail(for id: UUID, from url: URL) {
        let thumbnailer = self.thumbnailer
        Task { [weak self] in
            guard let image = await thumbnailer(url), let self, let i = self.recent.firstIndex(where: { $0.id == id }) else { return }
            Motion.animate(Motion.quick) { self.recent[i].thumbnail = image }
        }
    }

    private func updateActivity() {
        guard let batch else { liveActivity = nil; return }
        let stamp = now()
        if batch.isRunning {
            liveActivity = LiveActivity(
                id: Self.activityID, module: id, priority: .progress,
                leading: .progress(batch.fraction), trailing: .text("\(batch.completed)/\(batch.total)"),
                updatedAt: stamp, accessibilityLabel: "Converting images to WebP, \(batch.completed) of \(batch.total) done"
            )
            return
        }

        let leading: ActivityGlyph
        let trailing: ActivityGlyph?
        var label: String
        if let saved = batch.savedFraction {
            let grew = saved < 0
            let tint: TintRole = batch.failed > 0 || grew ? .warning : .success
            let symbol = batch.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            leading = .symbol(symbol, tint: tint)
            trailing = .text(Format.saving(saved))
            label = "Converted \(batch.succeeded) of \(batch.total) images, " + (grew ? "\(Format.saving(saved)) larger" : "\(Format.saving(saved)) smaller")
            if batch.failed > 0 { label += ", \(batch.failed) failed" }
        } else {
            leading = .symbol("exclamationmark.triangle.fill", tint: .warning)
            trailing = .text("Failed")
            label = batch.total == 1 ? "Conversion failed" : "All \(batch.total) conversions failed"
        }
        let expires = stamp.addingTimeInterval(Self.summaryDuration)
        liveActivity = LiveActivity(
            id: Self.activityID, module: id, priority: .progress, leading: leading, trailing: trailing,
            expiresAt: expires, updatedAt: stamp, accessibilityLabel: label
        )
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let generation = batchGeneration
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            await sleep(.seconds(Self.summaryDuration))
            guard !Task.isCancelled, let self, self.batchGeneration == generation, self.batch?.isRunning == false else { return }
            Motion.animate(Motion.morph) {
                self.batch = nil
                self.liveActivity = nil
            }
        }
    }

    // MARK: - Card actions

    func open(_ item: ConvertedItem) {
        guard let url = item.output else { return }
        reveal(url)
    }

    @concurrent
    public nonisolated static func makeThumbnail(_ url: URL) async -> SendableImage? {
        ImageDecoder.thumbnail(of: url, maxPixelSize: 56).map(SendableImage.init)
    }

    // MARK: - Sample state

    /// Replaces the visible state; used by `sample()`.
    func load(recent: [ConvertedItem], batch: BatchProgress?) {
        self.recent = recent
        self.batch = batch
        batchGeneration += 1
        updateActivity()
    }
}

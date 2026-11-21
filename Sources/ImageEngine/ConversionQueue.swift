import Darwin
import Foundation

/// Converts jobs with bounded concurrency off the main actor. Output names are reserved across every
/// submission in flight, so two sources that map to the same name never race for it.
public actor ConversionQueue {
    public let maxConcurrent: Int
    public let budgetBytes: Int64
    private var admission: Admission<UUID>
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reserved: Set<URL> = []

    /// - Parameters:
    ///   - maxConcurrent: most jobs at once, however small.
    ///   - budgetBytes: estimated peak memory of the jobs running together; a job larger than this runs alone.
    public init(maxConcurrent: Int = 2, budgetBytes: Int64 = Admission<UUID>.defaultBudget) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.budgetBytes = budgetBytes
        admission = Admission(budgetBytes: budgetBytes, maxConcurrent: maxConcurrent)
    }

    /// Jobs decoding, encoding or writing right now.
    public var runningCount: Int { admission.running.count }

    /// A sensible default for this machine. Memory is limited separately by `budgetBytes`.
    public static var defaultConcurrency: Int { min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 3)) }

    /// Starts converting and returns the events. The stream ends after the last job; cancelling its consumer
    /// cancels the jobs that have not started.
    public nonisolated func submit(_ jobs: [ConversionJob], options: EncodeOptions) -> AsyncStream<ConversionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConversionEvent.self, bufferingPolicy: .unbounded)
        let task = Task { await self.run(jobs, options: options, events: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Running

    private func run(_ jobs: [ConversionJob], options: EncodeOptions, events: AsyncStream<ConversionEvent>.Continuation) async {
        // Reserve every name up front so names follow submission order.
        let plans = jobs.map { job in (job, reserveInitial(for: job)) }
        let total = jobs.count
        await withTaskGroup(of: Void.self) { group in
            for (job, plan) in plans {
                group.addTask { await self.process(job, plan: plan, options: options, events: events) }
            }
            var completed = 0
            for await _ in group {
                completed += 1
                events.yield(.progress(completed: completed, total: total))
            }
        }
        events.finish()
    }

    private func process(_ job: ConversionJob, plan: Plan, options: EncodeOptions, events: AsyncStream<ConversionEvent>.Continuation) async {
        var destination = plan.destination
        defer { reserved.remove(destination) }
        let cost = await Self.estimateCost(job.source, options: options)
        await acquire(job.id, cost: cost)
        defer { release(job.id) }
        if Task.isCancelled { events.yield(.failed(job, .cancelled)); return }
        events.yield(.started(job))

        let encoded: Encoded
        let report: @Sendable (Double) -> Void = { events.yield(.fileProgress(job, $0)) }
        do { encoded = try await Self.encode(job.source, options: options, progress: report) } catch {
            events.yield(.failed(job, error)); return
        }

        if Task.isCancelled { events.yield(.failed(job, .cancelled)); return }
        var notes = encoded.notes
        if plan.usesFallback, case .file = job.source { notes.append(Self.fallbackNote(job.fallbackDirectory)) }
        var usingFallback = plan.usesFallback
        var attempts = 0
        while true {
            attempts += 1
            switch await Self.write(encoded.data, to: destination) {
            case .written:
                let result = ConversionResult(
                    input: job.source.fileURL, inputName: job.source.displayName, output: destination,
                    inputBytes: encoded.inputBytes, outputBytes: Int64(encoded.data.count),
                    pixelSize: encoded.pixelSize, originalPixelSize: encoded.originalPixelSize, notes: notes
                )
                events.yield(.succeeded(job, result))
                return
            case .exists where attempts < 50:
                // Someone created the file after we reserved the name: take the next one.
                let next = OutputNamer.destination(baseName: plan.baseName, in: destination.deletingLastPathComponent(), reserved: reserved)
                reserved.remove(destination); reserved.insert(next); destination = next
            case .failed(let reason) where !usingFallback:
                let next = OutputNamer.destination(baseName: plan.baseName, in: job.fallbackDirectory, reserved: reserved)
                reserved.remove(destination); reserved.insert(next); destination = next
                usingFallback = true
                notes.append(Self.fallbackNote(job.fallbackDirectory))
                _ = reason
            case .cancelled:
                events.yield(.failed(job, .cancelled)); return
            case .exists:
                events.yield(.failed(job, .writeFailed("No free file name"))); return
            case .failed(let reason):
                events.yield(.failed(job, .writeFailed(reason))); return
            }
        }
    }

    private struct Plan: Sendable {
        let destination: URL
        let baseName: String
        let usesFallback: Bool
    }

    private func reserveInitial(for job: ConversionJob) -> Plan {
        let directory: URL, base: String, fallback: Bool
        switch job.source {
        case .file(let url):
            let parent = url.deletingLastPathComponent()
            fallback = !FileManager.default.isWritableFile(atPath: parent.path)
            directory = fallback ? job.fallbackDirectory : parent
            base = OutputNamer.baseName(for: url.lastPathComponent)
        case .data(_, let name):
            directory = job.fallbackDirectory; base = OutputNamer.baseName(for: name); fallback = true
        }
        let destination = OutputNamer.destination(baseName: base, in: directory, reserved: reserved)
        reserved.insert(destination)
        return Plan(destination: destination, baseName: base, usesFallback: fallback)
    }

    private static func fallbackNote(_ folder: URL) -> String {
        "Saved to \(folder.lastPathComponent): the source folder is not writable"
    }

    // MARK: - Admission

    private func acquire(_ id: UUID, cost: Int64) async {
        if admission.request(id, cost: cost) { return }
        await withCheckedContinuation { waiters[id] = $0 }  // resumed by `release` once admitted
    }

    private func release(_ id: UUID) {
        for next in admission.finish(id) { waiters.removeValue(forKey: next)?.resume() }
    }

    @concurrent
    static func estimateCost(_ source: ImageSource, options: EncodeOptions) async -> Int64 {
        guard let px = ImageDecoder.estimatePixels(source, maxPixelEdge: options.maxPixelEdge) else { return 0 }
        return Admission<UUID>.cost(sourcePixels: px.source, outputPixels: px.output, lossless: options.lossless)
    }

    // MARK: - Off-actor work

    struct Encoded: Sendable {
        let data: Data
        let inputBytes: Int64
        let pixelSize: PixelSize
        let originalPixelSize: PixelSize
        let notes: [String]
    }

    /// Runs `convert` off the actor; cancelling the task stops libwebp mid-encode.
    @concurrent
    static func encode(_ source: ImageSource, options: EncodeOptions, progress: (@Sendable (Double) -> Void)?) async throws(ConversionError) -> Encoded {
        let flag = CancellationFlag()
        let result = await withTaskCancellationHandler {
            Result { () throws(ConversionError) in try convert(source, options: options, progress: progress, cancellation: flag) }
        } onCancel: {
            flag.cancel()
        }
        return try result.get()
    }

    /// The whole decode → encode pipeline for one source, synchronously.
    static func convert(
        _ source: ImageSource, options: EncodeOptions, progress: (@Sendable (Double) -> Void)? = nil,
        cancellation: CancellationFlag? = nil
    ) throws(ConversionError) -> Encoded {
        let inputBytes: Int64
        switch source {
        case .file(let url):
            if let problem = FileAvailability.problem(at: url) { throw problem }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let size else { throw .decodeFailed }
            inputBytes = Int64(size)
        case .data(let data, _):
            inputBytes = Int64(data.count)
        }
        if cancellation?.isCancelled == true { throw .cancelled }
        let keep = !options.stripMetadata
        // The decoded image lives only inside `rasterise`, so it is freed before libwebp copies the pixels.
        let prepared = try rasterise(source, options: options, includeMetadata: keep)
        progress?(0.1)
        var scaled: (@Sendable (Double) -> Void)?
        if let progress { scaled = { progress(0.1 + 0.9 * $0) } }
        let data = try WebPEncoder.encode(
            raster: prepared.raster, options: options, iccProfile: keep ? WebPEncoder.sRGBProfile : nil,
            exif: keep ? prepared.exif : nil, progress: scaled, cancellation: cancellation
        )
        progress?(1)  // libwebp's last report can stop short of 100
        return Encoded(data: data, inputBytes: inputBytes, pixelSize: prepared.pixelSize, originalPixelSize: prepared.originalPixelSize, notes: prepared.notes)
    }

    struct Prepared {
        let raster: Raster
        let exif: Data?
        let pixelSize: PixelSize
        let originalPixelSize: PixelSize
        let notes: [String]
    }

    static func rasterise(_ source: ImageSource, options: EncodeOptions, includeMetadata: Bool) throws(ConversionError) -> Prepared {
        let decoded = try ImageDecoder.load(source, maxPixelEdge: options.maxPixelEdge, includeMetadata: includeMetadata)
        let raster = try Raster.make(decoded.image)
        return Prepared(raster: raster, exif: decoded.exif, pixelSize: decoded.pixelSize, originalPixelSize: decoded.originalPixelSize, notes: decoded.notes)
    }

    enum WriteOutcome: Sendable { case written, exists, cancelled, failed(String) }

    /// Writes to a hidden temporary file beside `destination`, then renames it into place without ever replacing
    /// an existing file (`RENAME_EXCL`).
    @concurrent
    static func write(_ data: Data, to destination: URL) async -> WriteOutcome {
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        if Task.isCancelled { return .cancelled }
        do { try data.write(to: temp) } catch {
            try? FileManager.default.removeItem(at: temp)
            return .failed((error as NSError).localizedDescription)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temp)
            return .cancelled
        }
        let rc = temp.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(-1) }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if rc == 0 { return .written }
        let code = errno
        try? FileManager.default.removeItem(at: temp)
        return code == EEXIST ? .exists : .failed(String(cString: strerror(code)))
    }
}

extension ImageSource {
    var fileURL: URL? { if case .file(let url) = self { url } else { nil } }
}

import Foundation
import ImageEngine
import NotchCore
import NotchCoreTesting
import Synchronization
import Testing
@testable import ConvertModule

/// A runner the test drives by hand.
final class ScriptedRunner: ConversionRunning {
    struct Submission: Sendable {
        let jobs: [ConversionJob]
        let options: EncodeOptions
        let events: AsyncStream<ConversionEvent>.Continuation
    }
    private let state = Mutex<[Submission]>([])
    var submissions: [Submission] { state.withLock { $0 } }

    func submit(_ jobs: [ConversionJob], options: EncodeOptions) -> AsyncStream<ConversionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConversionEvent.self)
        state.withLock { $0.append(Submission(jobs: jobs, options: options, events: continuation)) }
        return stream
    }
}

/// Lets a test decide when the "4 s" summary timer fires.
final class Gate: Sendable {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let opened = Mutex(false)
    func wait() async {
        await withCheckedContinuation { c in
            let resumeNow = opened.withLock { $0 }
            if resumeNow { c.resume() } else { waiters.withLock { $0.append(c) } }
        }
    }
    func open() {
        opened.withLock { $0 = true }
        waiters.withLock { $0.forEach { $0.resume() }; $0.removeAll() }
    }
}

@MainActor
func eventually(_ what: String = "condition", timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func result(_ job: ConversionJob, input: Int64, output: Int64) -> ConversionResult {
    let name = job.source.displayName
    return ConversionResult(
        input: job.source.fileURLForTests, inputName: name,
        output: URL(fileURLWithPath: "/out/\(OutputNamer.baseName(for: name)).webp"),
        inputBytes: input, outputBytes: output, pixelSize: .init(width: 10, height: 10), originalPixelSize: .init(width: 10, height: 10)
    )
}

extension ImageSource {
    var fileURLForTests: URL? { if case .file(let u) = self { u } else { nil } }
}

@MainActor
@Suite struct ConvertModuleTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    struct Rig {
        let env: TestEnvironment
        let module: ConvertModule
        let runner: ScriptedRunner
        let clock: Clock
        let gate: Gate
        let haptics: Counter
    }

    final class Counter { var count = 0 }

    func rig() async throws -> Rig {
        let env = try TestEnvironment()
        let runner = ScriptedRunner(), clock = Clock(), gate = Gate(), haptics = Counter()
        let module = ConvertModule(
            runner: runner, now: { clock.now }, sleep: { _ in await gate.wait() }, thumbnailer: { _ in nil },
            reveal: { _ in }, haptic: { haptics.count += 1 }
        )
        await module.start(env.context(for: .convert))
        return Rig(env: env, module: module, runner: runner, clock: clock, gate: gate, haptics: haptics)
    }

    let png = DropItem.file(URL(fileURLWithPath: "/tmp/a.png"))

    @Test func basics() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        #expect(r.module.id == .convert)
        #expect(r.module.placement == .dashboard(.center))
        #expect(r.module.liveActivity == nil)
        #expect(r.module.settingsView() != nil)
        await r.module.start(r.env.context(for: .convert))  // idempotent
    }

    @Test func acceptsImagesAndRejectsEverythingElse() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        for name in ["a.png", "b.JPG", "c.jpeg", "d.heic", "e.tiff", "f.gif", "g.bmp"] {
            #expect(m.dropAcceptance(for: .file(URL(fileURLWithPath: "/tmp/\(name)"))) == .accept(weight: DropWeight.preferred), "\(name)")
        }
        #expect(m.dropAcceptance(for: .imageData(Data([1, 2]), suggestedName: nil)) == .accept(weight: DropWeight.preferred))
        for name in ["done.webp", "doc.pdf", "notes.txt", "folder", "movie.mov"] {
            #expect(m.dropAcceptance(for: .file(URL(fileURLWithPath: "/tmp/\(name)"))) == .reject, "\(name)")
        }
        #expect(m.dropAcceptance(for: .text("hi")) == .reject)

        // Images beat the shelf; other files fall through to it.
        let shelf = FakeModule(.shelf)
        shelf.acceptance = { $0.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject }
        let pdf = DropItem.file(URL(fileURLWithPath: "/tmp/doc.pdf"))
        let routes = DropRouter.route(DropPayload(items: [png, pdf]), among: [m, shelf])
        #expect(routes.map(\.module) == [.convert, .shelf])
        #expect(routes.first?.payload.items == [png])
    }

    @Test func hintFollowsSettings() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        #expect(m.dropHint(for: [png]) == DropHint(title: "Drop to convert to WebP", subtitle: "Quality 80", symbol: m.symbol))
        m.cycleMaxEdge(); m.cycleMaxEdge()
        #expect(m.dropHint(for: [png])?.subtitle == "Quality 80 \u{00B7} max 2560 px")
        m.stepQuality(by: 2)
        #expect(m.dropHint(for: [png])?.subtitle == "Quality 90 \u{00B7} max 2560 px")
        m.toggleLossless()
        #expect(m.dropHint(for: [png])?.subtitle == "Lossless \u{00B7} max 2560 px")
        m.toggleStripMetadata()
        #expect(m.dropHint(for: [png])?.subtitle == "Lossless \u{00B7} max 2560 px \u{00B7} keep metadata")
    }

    @Test func settingsPersistUnderConvertKeys() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module, s = r.env.settings
        for key in [ConvertSettings.quality.name, ConvertSettings.lossless.name, ConvertSettings.maxPixelEdge.name, ConvertSettings.stripMetadata.name] {
            #expect(key.hasPrefix("convert."))
        }
        #expect(m.options == EncodeOptions())
        m.setQuality(55); m.toggleLossless(); m.cycleMaxEdge(); m.toggleStripMetadata()
        #expect(s.get(ConvertSettings.quality) == 55)
        #expect(s.get(ConvertSettings.lossless))
        #expect(s.get(ConvertSettings.maxPixelEdge) == 1920)
        #expect(!s.get(ConvertSettings.stripMetadata))
        m.cycleMaxEdge(); m.cycleMaxEdge(); m.cycleMaxEdge()
        #expect(s.get(ConvertSettings.maxPixelEdge) == nil)
        m.setQuality(140)
        #expect(m.options.quality == 100)
        m.stepQuality(by: 1)
        #expect(m.options.quality == 100)
        m.setQuality(3); m.stepQuality(by: -1)
        #expect(m.options.quality == 0)
        m.setQuality(82); m.stepQuality(by: 1)
        #expect(m.options.quality == 85)
    }

    @Test func convertSubmitsWithCurrentSettingsAndFallbackFolder() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        r.module.setQuality(60)
        r.module.convert([.file(URL(fileURLWithPath: "/tmp/a.png")), .imageData(Data([1]), name: "clip")])
        let sub = try #require(r.runner.submissions.first)
        #expect(sub.options.quality == 60)
        #expect(sub.jobs.map(\.source) == [.file(URL(fileURLWithPath: "/tmp/a.png")), .data(Data([1]), name: "clip")])
        #expect(sub.jobs.allSatisfy { $0.fallbackDirectory == r.env.directories.downloads })
    }

    @Test func handleDropEnqueuesOnlyAcceptedItemsAndReturns() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        await r.module.handleDrop(DropPayload(items: [png, .text("x"), .imageData(Data([9]), suggestedName: nil)]))
        let sub = try #require(r.runner.submissions.first)
        #expect(sub.jobs.map(\.source) == [.file(URL(fileURLWithPath: "/tmp/a.png")), .data(Data([9]), name: "Image")])
        #expect(r.module.batch?.isRunning == true)
    }

    @Test func activityProgressesThenSummarisesAndExpires() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert(["a.png", "b.png", "c.png"].map { .file(URL(fileURLWithPath: "/tmp/\($0)")) })
        let sub = try #require(r.runner.submissions.first)
        var a = try #require(m.liveActivity)
        #expect(a.priority == .progress && a.leading == .progress(0) && a.trailing == .text("0/3") && a.expiresAt == nil)

        r.clock.now += 1
        sub.events.yield(.started(sub.jobs[0]))
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 1000, output: 200)))
        await eventually("1/3") { m.liveActivity?.trailing == .text("1/3") }
        a = try #require(m.liveActivity)
        #expect(a.leading == .progress(1.0 / 3))
        #expect(a.updatedAt == r.clock.now)
        #expect(r.env.shelf.added.count == 1)
        #expect(r.env.shelf.added.first?.urls == [URL(fileURLWithPath: "/out/a.webp")])
        #expect(r.env.shelf.added.first?.origin == .converted)

        sub.events.yield(.succeeded(sub.jobs[1], result(sub.jobs[1], input: 1000, output: 240)))
        await eventually("2/3") { m.liveActivity?.trailing == .text("2/3") }
        #expect(r.haptics.count == 0)

        r.clock.now += 1
        sub.events.yield(.succeeded(sub.jobs[2], result(sub.jobs[2], input: 2000, output: 440)))
        await eventually("done") { m.batch?.isRunning == false }
        a = try #require(m.liveActivity)
        #expect(a.leading == .symbol("checkmark.circle.fill", tint: .success))
        #expect(a.trailing == .text(Format.saving(0.78)))   // 880 of 4000 bytes
        #expect(a.trailing == .text("\u{2212}78%"))
        #expect(a.expiresAt == r.clock.now.addingTimeInterval(4))
        #expect(a.id == "convert.batch")
        #expect(r.haptics.count == 1)
        #expect(m.recent.map(\.name) == ["c.webp", "b.webp", "a.webp"])
        #expect(m.recent.first?.detail == "2 KB \u{2192} 440 B")
        #expect(r.env.shelf.added.count == 3)

        // The arbiter drops it at the expiry instant even before the module clears it.
        #expect(ActivityArbiter.select([a], now: r.clock.now.addingTimeInterval(3.9))?.id == a.id)
        #expect(ActivityArbiter.select([a], now: r.clock.now.addingTimeInterval(4)) == nil)

        r.gate.open()
        await eventually("cleared") { m.liveActivity == nil }
        #expect(m.batch == nil)
        #expect(m.recent.count == 3)
    }

    @Test func growthAndFailuresWarn() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert([.file(URL(fileURLWithPath: "/tmp/tiny.png"))])
        var sub = try #require(r.runner.submissions.last)
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 100, output: 112)))
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.leading == .symbol("checkmark.circle.fill", tint: .warning))
        #expect(m.liveActivity?.trailing == .text("+12%"))

        m.convert([.file(URL(fileURLWithPath: "/tmp/x.png")), .file(URL(fileURLWithPath: "/tmp/y.png"))])
        #expect(m.batch?.total == 2)  // a finished batch is replaced, not extended
        sub = try #require(r.runner.submissions.last)
        sub.events.yield(.failed(sub.jobs[0], .decodeFailed))
        sub.events.yield(.succeeded(sub.jobs[1], result(sub.jobs[1], input: 1000, output: 500)))
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.leading == .symbol("exclamationmark.triangle.fill", tint: .warning))
        #expect(m.liveActivity?.trailing == .text("\u{2212}50%"))
        #expect(m.recent.contains { $0.failure == ConversionError.decodeFailed.message && $0.name == "x.png" })

        m.convert([.file(URL(fileURLWithPath: "/tmp/z.webp"))])
        sub = try #require(r.runner.submissions.last)
        sub.events.yield(.failed(sub.jobs[0], .alreadyWebP))
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.leading == .symbol("exclamationmark.triangle.fill", tint: .warning))
        #expect(m.liveActivity?.trailing == .text("Failed"))
        #expect(r.haptics.count == 2)  // not for the all-failed batch
        #expect(m.recent.count == ConvertModule.recentLimit)
    }

    @Test func dropsDuringABatchExtendIt() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert([.file(URL(fileURLWithPath: "/tmp/a.png"))])
        m.convert([.file(URL(fileURLWithPath: "/tmp/b.png")), .file(URL(fileURLWithPath: "/tmp/c.png"))])
        #expect(m.batch?.total == 3)
        #expect(m.liveActivity?.trailing == .text("0/3"))
        let first = r.runner.submissions[0], second = r.runner.submissions[1]
        first.events.yield(.succeeded(first.jobs[0], result(first.jobs[0], input: 10, output: 5)))
        await eventually { m.batch?.completed == 1 }
        #expect(m.batch?.isRunning == true)
        #expect(m.liveActivity?.expiresAt == nil)
        for job in second.jobs { second.events.yield(.succeeded(job, result(job, input: 10, output: 5))) }
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.trailing == .text("\u{2212}50%"))
    }

    @Test func realConversionEndToEnd() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = ConvertModule(runner: ConversionQueue(maxConcurrent: 2), reveal: { _ in }, haptic: {})
        await module.start(env.context(for: .convert))
        let folder = env.root.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let src = try TestImage.write(TestImage.solid(width: 64, height: 40), to: folder.appending(path: "hero.png"))
        let clip = TestImage.data(TestImage.solid(width: 8, height: 8, green: 1), type: .png)

        await module.handleDrop(DropPayload(items: [.file(src), .imageData(clip, suggestedName: "pasted.png")]))
        await eventually("batch done") { module.batch?.isRunning == false }
        let outputs = Set(env.shelf.added.flatMap(\.urls).map(\.standardizedFileURL))
        #expect(outputs == [folder.appending(path: "hero.webp").standardizedFileURL, env.directories.downloads.appending(path: "pasted.webp").standardizedFileURL])
        #expect(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await eventually("thumbnails") { module.recent.allSatisfy { $0.thumbnail != nil } }
        #expect(module.recent.count == 2)
    }

    // MARK: - Looking at the card

    @Test func snapshots() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "convert-snapshots", directoryHint: .isDirectory)
        let r = try await rig(); defer { r.env.cleanUp() }
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "1-empty.png"))
        r.module.showingOptions = true
        r.module.cycleMaxEdge(); r.module.cycleMaxEdge()
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "2-options.png"))
        r.module.toggleLossless(); r.module.toggleStripMetadata()
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "3-options-lossless.png"))
        let sample = ConvertModule.sample()
        try ViewSnapshot.write(module: sample, to: dir.appending(path: "4-sample-running.png"))
        let done = ConvertModule.sample(inFlight: false)
        try ViewSnapshot.write(module: done, to: dir.appending(path: "5-sample-idle.png"))
        #expect(sample.liveActivity?.trailing == .text("3/12"))
        #expect(done.liveActivity == nil)
        r.module.showingOptions = false
        r.module.convert([.file(URL(fileURLWithPath: "/tmp/Screenshot 2026-11-21 at 10.42.png")), .file(URL(fileURLWithPath: "/tmp/broken.jpg"))])
        let sub = try #require(r.runner.submissions.last)
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 2_400_000, output: 310_000)))
        sub.events.yield(.failed(sub.jobs[1], .decodeFailed))
        await eventually { r.module.batch?.isRunning == false }
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "6-done-with-failure.png"))
        print("snapshots in \(dir.path)")
    }
}

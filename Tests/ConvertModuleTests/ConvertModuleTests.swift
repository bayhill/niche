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
        #expect(r.module.title == "Convert")
        #expect(r.module.placement == .dashboard(.trailing))
        #expect(r.module.liveActivity == nil)
        #expect(r.module.rows.isEmpty)
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

    @Test func hintNamesTheActionCountAndOptionKey() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        #expect(m.dropHint(for: [png]) == DropHint(title: "Convert to WebP", subtitle: "1 image \u{00B7} \u{2325} to shelve", symbol: "photo"))
        #expect(m.dropHint(for: [png, png, png])?.subtitle == "3 images \u{00B7} \u{2325} to shelve")
        m.toggleLossless()
        #expect(m.dropHint(for: [png])?.title == "Convert to WebP")  // settings are not repeated
        // Through the router, the count is what Convert would receive.
        let routed = DropRouter.hint(for: DropPayload(items: [png, .text("x"), png]), among: [m])
        #expect(routed?.subtitle == "2 images \u{00B7} \u{2325} to shelve")
    }

    @Test func headerShowsFormatAtRestAndCountWhileWorking() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        #expect(m.headerTrailing == "WebP")
        m.setQuality(60)
        #expect(m.headerTrailing == "WebP 60")
        m.cycleMaxEdge(); m.cycleMaxEdge()
        #expect(m.headerTrailing == "WebP 60 \u{00B7} 2560")
        m.toggleLossless()
        #expect(m.headerTrailing == "Lossless \u{00B7} 2560")
        m.cycleMaxEdge(); m.cycleMaxEdge()
        #expect(m.headerTrailing == "Lossless")
        m.toggleLossless(); m.setQuality(80); m.toggleStripMetadata()
        #expect(m.headerTrailing == "WebP")  // metadata is not shown on the card

        m.convert((1...5).map { .file(URL(fileURLWithPath: "/tmp/\($0).png")) })
        #expect(m.headerTrailing == "0/5")
        let sub = try #require(r.runner.submissions.first)
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 10, output: 5)))
        sub.events.yield(.failed(sub.jobs[1], .decodeFailed))
        await eventually { m.batch?.completed == 2 }
        #expect(m.headerTrailing == "2/5")
        for job in sub.jobs.dropFirst(2) { sub.events.yield(.succeeded(job, result(job, input: 10, output: 5))) }
        await eventually { m.batch?.isRunning == false }
        #expect(m.headerTrailing == "WebP")
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
        #expect(r.module.rows.map(\.id) == sub.jobs.map(\.id))
    }

    @Test func handleDropEnqueuesOnlyAcceptedItemsAndReturns() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        await r.module.handleDrop(DropPayload(items: [png, .text("x"), .imageData(Data([9]), suggestedName: nil)]))
        let sub = try #require(r.runner.submissions.first)
        #expect(sub.jobs.map(\.source) == [.file(URL(fileURLWithPath: "/tmp/a.png")), .data(Data([9]), name: "Image")])
        #expect(r.module.batch?.isRunning == true)
        #expect(r.module.rows.map(\.name) == ["a.png", "Image"])
    }

    @Test func rowsGoFromWaitingToConvertingToDoneOrFailed() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert(["hero.png", "broken.jpg"].map { .file(URL(fileURLWithPath: "/tmp/\($0)")) })
        let sub = try #require(r.runner.submissions.first)
        let (hero, broken) = (sub.jobs[0], sub.jobs[1])
        func row(_ job: ConversionJob) -> ConvertRow? { m.rows.first { $0.id == job.id } }

        #expect(m.rows.map(\.state) == [.waiting, .waiting])
        #expect(row(hero)?.detail == "Waiting")
        #expect(m.heroRowID == nil)

        sub.events.yield(.started(hero))
        await eventually { row(hero)?.state == .converting(nil) }
        #expect(row(hero)?.detail == "Converting\u{2026}")
        #expect(m.heroRowID == hero.id)
        #expect(row(broken)?.state == .waiting)

        sub.events.yield(.fileProgress(hero, 0.4))
        await eventually { row(hero)?.state == .converting(0.4) }
        #expect(m.liveActivity?.leading == .progress(0.2))  // 0.4 of one file out of two

        sub.events.yield(.succeeded(hero, result(hero, input: 1_200_000, output: 264_000)))
        await eventually { row(hero)?.output != nil }
        #expect(row(hero)?.state == .done(output: URL(fileURLWithPath: "/out/hero.webp"), inputBytes: 1_200_000, outputBytes: 264_000))
        #expect(row(hero)?.detail == "1.2 MB \u{2192} 264 KB")
        #expect(row(hero)?.figure == "\u{2212}78%")
        #expect(row(hero)?.figureTint == .success)
        #expect(row(hero)?.name == "hero.png")
        #expect(m.heroRowID == nil)

        sub.events.yield(.started(broken))
        sub.events.yield(.failed(broken, .decodeFailed))
        await eventually { row(broken)?.isActive == false }
        #expect(row(broken)?.state == .failed("Couldn\u{2019}t read image"))
        #expect(row(broken)?.detail == "Couldn\u{2019}t read image")
        #expect(row(broken)?.figure == nil)
        #expect(row(broken)?.output == nil)
        // Order never changes as states change.
        #expect(m.rows.map(\.id) == [hero.id, broken.id])
    }

    @Test func grownFileReadsAsInformation() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert([.file(URL(fileURLWithPath: "/tmp/settings-panel.png"))])
        let sub = try #require(r.runner.submissions.last)
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 86_000, output: 91_000)))
        await eventually { m.batch?.isRunning == false }
        let row = try #require(m.rows.first)
        #expect(row.figure == "+6%")
        #expect(row.figureTint == .secondary)
        #expect(m.liveActivity?.leading == .symbol("checkmark.circle.fill", tint: .secondary))
        #expect(m.liveActivity?.trailing == .text("+6%"))
        #expect(r.haptics.count == 1)
    }

    @Test func visibleWindowFollowsTheWork() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert((1...6).map { .file(URL(fileURLWithPath: "/tmp/f\($0).png")) })
        let sub = try #require(r.runner.submissions.first)
        #expect(m.visibleRows.map(\.name) == ["f1.png", "f2.png", "f3.png"])
        for job in sub.jobs.prefix(3) { sub.events.yield(.succeeded(job, result(job, input: 10, output: 5))) }
        sub.events.yield(.started(sub.jobs[3]))
        await eventually { m.batch?.completed == 3 && m.heroRowID == sub.jobs[3].id }
        #expect(m.visibleRows.map(\.name) == ["f3.png", "f4.png", "f5.png"])
        for job in sub.jobs.dropFirst(3) { sub.events.yield(.succeeded(job, result(job, input: 10, output: 5))) }
        await eventually { m.batch?.isRunning == false }
        #expect(m.visibleRows.map(\.name) == ["f4.png", "f5.png", "f6.png"])

        // A new batch goes on top; older history is trimmed to what fits.
        m.convert([.file(URL(fileURLWithPath: "/tmp/new.png"))])
        #expect(m.rows.map(\.name) == ["new.png", "f1.png", "f2.png", "f3.png"])
        #expect(m.visibleRows.map(\.name) == ["new.png", "f1.png", "f2.png"])
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
        #expect(a.trailing == .text("\u{2212}78%"))   // 880 of 4000 bytes
        #expect(a.expiresAt == r.clock.now.addingTimeInterval(4))
        #expect(a.id == "convert.batch")
        #expect(r.haptics.count == 1)
        #expect(r.env.shelf.added.count == 3)

        // The arbiter drops it at the expiry instant even before the module clears it.
        #expect(ActivityArbiter.select([a], now: r.clock.now.addingTimeInterval(3.9))?.id == a.id)
        #expect(ActivityArbiter.select([a], now: r.clock.now.addingTimeInterval(4)) == nil)

        r.gate.open()
        await eventually("cleared") { m.liveActivity == nil }
        #expect(m.batch == nil)
        #expect(m.rows.count == 3)
        #expect(m.headerTrailing == "WebP")
    }

    @Test func failuresWarn() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert([.file(URL(fileURLWithPath: "/tmp/x.png")), .file(URL(fileURLWithPath: "/tmp/y.png"))])
        var sub = try #require(r.runner.submissions.last)
        sub.events.yield(.failed(sub.jobs[0], .decodeFailed))
        sub.events.yield(.succeeded(sub.jobs[1], result(sub.jobs[1], input: 1000, output: 500)))
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.leading == .symbol("exclamationmark.triangle.fill", tint: .warning))
        #expect(m.liveActivity?.trailing == .text("\u{2212}50%"))

        m.convert([.file(URL(fileURLWithPath: "/tmp/z.webp"))])
        #expect(m.batch?.total == 1)  // a finished batch is replaced, not extended
        sub = try #require(r.runner.submissions.last)
        sub.events.yield(.failed(sub.jobs[0], .alreadyWebP))
        await eventually { m.batch?.isRunning == false }
        #expect(m.liveActivity?.leading == .symbol("exclamationmark.triangle.fill", tint: .warning))
        #expect(m.liveActivity?.trailing == .text("Failed"))
        #expect(r.haptics.count == 1)  // not for the all-failed batch
    }

    @Test func dropsDuringABatchExtendIt() async throws {
        let r = try await rig(); defer { r.env.cleanUp() }
        let m = r.module
        m.convert([.file(URL(fileURLWithPath: "/tmp/a.png"))])
        m.convert([.file(URL(fileURLWithPath: "/tmp/b.png")), .file(URL(fileURLWithPath: "/tmp/c.png"))])
        #expect(m.batch?.total == 3)
        #expect(m.liveActivity?.trailing == .text("0/3"))
        #expect(m.rows.map(\.name) == ["a.png", "b.png", "c.png"])
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
        await eventually("thumbnails") { module.rows.allSatisfy { $0.thumbnail != nil } }
        #expect(module.rows.map(\.name) == ["hero.png", "pasted.png"])
    }

    @Test func samplesShowTheThreeStates() {
        #expect(ConvertModule.sample(.empty).rows.isEmpty)
        let converting = ConvertModule.sample(.converting)
        #expect(converting.headerTrailing == "2/5")
        #expect(converting.visibleRows.map(\.detail) == ["1.2 MB \u{2192} 264 KB", "Converting\u{2026}", "Waiting"])
        #expect(converting.liveActivity?.trailing == .text("2/5"))
        let done = ConvertModule.sample(.done)
        #expect(done.headerTrailing == "WebP")
        #expect(done.visibleRows.compactMap(\.figure) == ["\u{2212}78%", "\u{2212}73%", "+6%"])
        #expect(done.liveActivity == nil)
    }

    // MARK: - Looking at the card

    @Test func snapshots() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "convert-snapshots-v2", directoryHint: .isDirectory)
        try ViewSnapshot.write(module: ConvertModule.sample(.empty), to: dir.appending(path: "1-empty.png"))
        try ViewSnapshot.write(module: ConvertModule.sample(.converting), to: dir.appending(path: "2-converting.png"))
        try ViewSnapshot.write(module: ConvertModule.sample(.done), to: dir.appending(path: "3-done-grown.png"))

        let r = try await rig(); defer { r.env.cleanUp() }
        r.module.convert(["Screenshot 2026-11-21 at 10.42.png", "broken.jpg", "spinner.png"].map { .file(URL(fileURLWithPath: "/tmp/\($0)")) })
        let sub = try #require(r.runner.submissions.last)
        sub.events.yield(.succeeded(sub.jobs[0], result(sub.jobs[0], input: 2_400_000, output: 310_000)))
        sub.events.yield(.failed(sub.jobs[1], .decodeFailed))
        sub.events.yield(.started(sub.jobs[2]))
        await eventually { r.module.heroRowID == sub.jobs[2].id }
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "4-failed-spinner.png"))
        sub.events.yield(.succeeded(sub.jobs[2], result(sub.jobs[2], input: 2_400_000, output: 2_400_000)))
        await eventually { r.module.batch?.isRunning == false }
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "5-failed-done.png"))
        r.module.setQuality(60)
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "6-header-quality.png"))
        r.module.showingOptions = true
        try ViewSnapshot.write(module: r.module, to: dir.appending(path: "7-options.png"))
        print("snapshots in \(dir.path)")
    }
}

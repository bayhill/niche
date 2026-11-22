import CoreGraphics
import Foundation
import NotchCore
import NotchCoreTesting
import Testing
@testable import ColourModule

/// Hands out scripted results; `nil` is a cancelled pick. Never shows anything.
@MainActor
private final class FakeSampler: ColourSampling {
    var results: [Colour?]
    private(set) var calls = 0
    /// Runs as the magnifier would appear, before the result.
    var onSample: (() -> Void)?

    init(_ results: [Colour?]) { self.results = results }

    func sample() async -> Colour? {
        calls += 1
        onSample?()
        return results.isEmpty ? nil : results.removeFirst()
    }
}

@MainActor
private final class Clipboard { var texts: [String] = [] }

@MainActor
private func makeModule(
    _ results: [Colour?], clipboard: Clipboard = Clipboard(), activity: Duration = .seconds(60), now: Date = Date()
) -> (ColourModule, FakeSampler) {
    let sampler = FakeSampler(results)
    let module = ColourModule(sampler: sampler, copy: { clipboard.texts.append($0) }, now: { now }, activityDuration: activity)
    return (module, sampler)
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(15)) async {
    let clock = ContinuousClock(), end = clock.now + timeout
    while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
}

private let red = Colour(rgb8: 255, 0, 0)
private let ink = Colour(rgb8: 0x1F, 0x2A, 0x44)
private let paper = Colour(rgb8: 0xF4, 0xF1, 0xEA)

@MainActor @Suite struct ColourModuleTests {
    @Test func isAPage() {
        let module = ColourModule.sample()
        #expect(module.id == .colour)
        #expect(module.placement == .page(order: 40))
    }

    @Test func basics() {
        let (module, _) = makeModule([])
        #expect(module.title == "Colour")
        #expect(module.symbol == "eyedropper")
        #expect(module.liveActivity == nil)
        #expect(module.picks.isEmpty)
        #expect(module.capacity == 12)
        #expect(module.format == .hex)
        #expect(module.copiesOnPick)
        #expect(module.settingsView() == nil)  // no settings before start
    }

    @Test func pickLandsAtTheFrontAndCopiesInTheCurrentFormat() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clipboard = Clipboard()
        let (module, sampler) = makeModule([ink, red], clipboard: clipboard)
        await module.start(env.context(for: .colour))
        await module.pick()
        env.settings.set(ColourModule.formatKey, .oklch)
        await module.pick()
        #expect(sampler.calls == 2)
        #expect(module.picks.map(\.colour) == [red, ink])
        #expect(clipboard.texts == ["#1F2A44", "oklch(62.8% 0.258 29.2)"])
        #expect(module.isPicking == false)
        module.stop()
    }

    @Test func copyOnPickOffCopiesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(ColourModule.copyOnPickKey, false)
        let clipboard = Clipboard()
        let (module, _) = makeModule([red], clipboard: clipboard)
        await module.start(env.context(for: .colour))
        await module.pick()
        #expect(module.picks.map(\.colour) == [red])
        #expect(clipboard.texts.isEmpty)
        #expect(module.liveActivity?.leadingText == nil)
        #expect(module.liveActivity?.trailingText == "#FF0000")
        module.stop()
    }

    @Test func collapsesTheNotchBeforeSampling() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, sampler) = makeModule([red])
        var callsWhenShown: [RecordingNotchController.Call]?
        var pickingWhenShown = false
        sampler.onSample = {
            callsWhenShown = env.notch.calls
            pickingWhenShown = module.isPicking
        }
        await module.start(env.context(for: .colour))
        await module.pick()
        #expect(callsWhenShown == [.collapse])
        #expect(pickingWhenShown)
        #expect(module.isPicking == false)
        module.stop()
    }

    @Test func cancelledPickChangesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clipboard = Clipboard()
        let (module, _) = makeModule([red, nil], clipboard: clipboard)
        await module.start(env.context(for: .colour))
        await module.pick()
        let before = module.picks
        let activity = module.liveActivity
        let saved = try Data(contentsOf: ColourFiles.storeURL(in: env.directories))
        await module.pick()
        #expect(module.picks == before)
        #expect(module.liveActivity == activity)
        #expect(clipboard.texts == ["#FF0000"])
        #expect(try Data(contentsOf: ColourFiles.storeURL(in: env.directories)) == saved)
        module.stop()
    }

    @Test func publishesTheActivityAndItExpires() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let (module, _) = makeModule([Colour(displayP3: 0, 1, 0)], activity: .milliseconds(80), now: stamp)
        await module.start(env.context(for: .colour))
        await module.pick()
        let activity = try #require(module.liveActivity)
        #expect(activity.id == "colour.picked")
        #expect(activity.module == .colour)
        #expect(activity.priority == .passive)
        #expect(activity.trailing == nil)
        #expect(activity.trailingText == "#00FF00")
        #expect(activity.leadingText == "Copied")
        #expect(activity.updatedAt == stamp)
        #expect(activity.expiresAt == stamp.addingTimeInterval(0.08))
        #expect(activity.accessibilityLabel == "Picked #00FF00, copied as Hex")
        guard case .image(let image) = activity.leading else { Issue.record("leading is not a swatch image"); return }
        #expect(image.cgImage.width == 40)
        #expect(image.cgImage.colorSpace?.name == CGColorSpace.displayP3)
        // Equal across refreshes: reading again, or changing the format, gives the same value.
        env.settings.set(ColourModule.formatKey, .displayP3)
        #expect(module.liveActivity == activity)
        await waitUntil { module.liveActivity == nil }
        #expect(module.liveActivity == nil)
        module.stop()
    }

    @Test func swatchImageIsTheColour() throws {
        let image = try #require(SwatchImage.make(Colour(rgb8: 0x3D, 0x8B, 0x7A))).cgImage
        let data = try #require(image.dataProvider?.data as Data?)
        let middle = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        // The bitmap is Display P3; convert the expected sRGB colour to P3 8-bit for comparison.
        let p3 = Colour(rgb8: 0x3D, 0x8B, 0x7A).displayP3.map { Int(($0 * 255).rounded()) }
        for channel in 0..<3 { #expect(abs(Int(data[middle + channel]) - p3[channel]) <= 1) }
    }

    @Test func repeatedPickMovesToTheFront() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([red, ink, Colour(red: 1, green: 0.0001, blue: 0)])
        await module.start(env.context(for: .colour))
        await module.pick(); await module.pick()
        let redID = module.picks[1].id
        await module.pick()
        #expect(module.picks.count == 2)
        #expect(module.picks.first?.id == redID)
        module.stop()
    }

    @Test func clickCopiesWithBriefConfirmation() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clipboard = Clipboard()
        let sampler = FakeSampler([red])
        let module = ColourModule(sampler: sampler, copy: { clipboard.texts.append($0) }, copiedDuration: .milliseconds(50))
        await module.start(env.context(for: .colour))
        await module.pick()
        env.settings.set(ColourModule.formatKey, .rgb)
        module.activate(module.picks[0])
        #expect(clipboard.texts == ["#FF0000", "rgb(255 0 0)"])
        #expect(module.copiedID == module.picks[0].id)
        await waitUntil { module.copiedID == nil }
        #expect(module.copiedID == nil)
        module.stop()
    }

    @Test func setFormatWritesTheSetting() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([])
        await module.start(env.context(for: .colour))
        module.setFormat(.displayP3)
        #expect(env.settings.get(ColourModule.formatKey) == .displayP3)
        #expect(module.format == .displayP3)
        #expect(module.settingsView() != nil)
        module.stop()
    }

    @Test func comparingChoosesInsteadOfCopying() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clipboard = Clipboard()
        let white = Colour(rgb8: 255, 255, 255), grey = Colour(hex: "#767676")!
        let (module, _) = makeModule([white, grey, ink], clipboard: clipboard)
        await module.start(env.context(for: .colour))
        await module.pick(); await module.pick()
        // Without a choice the card compares the two newest.
        #expect(module.contrastPair.map { [$0.0.colour, $0.1.colour] } == [grey, white])
        await module.pick()
        #expect(module.contrastPair.map { [$0.0.colour, $0.1.colour] } == [ink, grey])
        let copies = clipboard.texts.count

        module.setComparing(true)
        #expect(module.selection.chosen == [module.picks[0].id, module.picks[1].id])
        module.activate(module.picks[0])  // un-choose ink
        #expect(module.contrastPair == nil)
        module.activate(module.picks[2])  // choose white
        #expect(module.contrastPair.map { [$0.0.colour, $0.1.colour] } == [grey, white])
        #expect(clipboard.texts.count == copies)  // nothing copied while choosing

        module.setComparing(false)
        #expect(module.contrastPair.map { [$0.0.colour, $0.1.colour] } == [grey, white])
        module.stop()
    }

    @Test func leavingComparingWithOneChosenFallsBackToNewest() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([red, ink, paper])
        await module.start(env.context(for: .colour))
        await module.pick(); await module.pick(); await module.pick()
        module.setComparing(true)
        module.activate(module.picks[0])
        #expect(module.selection.chosen.count == 1)
        module.setComparing(false)
        #expect(module.selection.isEmpty)
        #expect(module.contrastPair.map { [$0.0.colour, $0.1.colour] } == [paper, ink])
        module.stop()
    }

    @Test func clearEmptiesAndSaves() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([red, ink])
        await module.start(env.context(for: .colour))
        await module.pick(); await module.pick()
        module.setComparing(true)
        module.clear()
        #expect(module.picks.isEmpty)
        #expect(module.isComparing == false)
        #expect(module.selection.isEmpty)
        let url = ColourFiles.storeURL(in: env.directories)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(ColourFiles.load(from: url).isEmpty)
        module.stop()
    }

    @Test func persistenceRoundTrip() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (first, _) = makeModule([red, Colour(displayP3: 0, 1, 0)])
        await first.start(env.context(for: .colour))
        await first.pick(); await first.pick()
        let saved = first.picks
        first.stop()

        let (second, _) = makeModule([])
        await second.start(env.context(for: .colour))
        #expect(second.picks == saved)
        #expect(second.picks.first?.colour.isInSRGBGamut == false)  // unclamped components survive the file
        second.stop()
    }

    @Test func startIsIdempotent() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([red])
        await module.start(env.context(for: .colour))
        await module.pick()
        await module.start(env.context(for: .colour))
        #expect(module.picks.count == 1)
        module.stop()
        module.stop()
    }

    @Test func corruptFileIsTolerated() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let url = ColourFiles.storeURL(in: env.directories)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let (module, _) = makeModule([red])
        await module.start(env.context(for: .colour))
        #expect(module.picks.isEmpty)
        await module.pick()
        #expect(ColourFiles.load(from: url).map(\.colour) == [red])
        module.stop()
    }

    @Test func missingFileIsTolerated() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let (module, _) = makeModule([])
        await module.start(env.context(for: .colour))
        #expect(module.picks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ColourFiles.storeURL(in: env.directories).path))
        module.stop()
    }

    @Test func sampleTouchesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = ColourModule.sample()
        #expect(module.picks.count >= 3)
        #expect(module.picks.contains { !$0.colour.isInSRGBGamut })
        await module.start(env.context(for: .colour))
        await module.pick()
        module.copy(module.picks[0])
        module.clear()
        module.stop()
        for dir in [env.directories.appSupport, env.directories.caches, env.directories.downloads, env.directories.home] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "\(dir.lastPathComponent)")
        }
    }

    @Test func sampleSamplerHandsOutInventedColours() async {
        let module = ColourModule.sample()
        let before = module.picks.count
        await module.pick()
        #expect(module.picks.count == before + 1)
    }
}

@Suite struct ColourHistoryTests {
    private func pick(_ colour: Colour, at seconds: Double = 0) -> ColourPick {
        ColourPick(colour: colour, pickedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @Test func newestFirst() {
        var history = ColourHistory()
        history.add(pick(red, at: 1))
        history.add(pick(ink, at: 2))
        #expect(history.picks.map(\.colour) == [ink, red])
    }

    @Test func repeatMovesToFrontKeepingItsID() {
        var history = ColourHistory()
        let first = history.add(pick(red, at: 1))
        history.add(pick(ink, at: 2))
        let again = history.add(pick(Colour(red: 1, green: 0.00001, blue: 0), at: 3))
        #expect(history.picks.count == 2)
        #expect(again.id == first.id)
        #expect(history.picks.first?.id == first.id)
        #expect(history.picks.first?.pickedAt == Date(timeIntervalSince1970: 1_800_000_003))
    }

    @Test func cappedAtTwelve() {
        var history = ColourHistory()
        for i in 0..<15 { history.add(pick(Colour(rgb8: i, 0, 0), at: Double(i))) }
        #expect(history.picks.count == 12)
        #expect(history.picks.first?.colour == Colour(rgb8: 14, 0, 0))
        #expect(history.picks.last?.colour == Colour(rgb8: 3, 0, 0))
    }

    @Test func replaceNormalises() {
        var history = ColourHistory(capacity: 3)
        history.replace(with: [
            pick(red, at: 1), pick(ink, at: 5), pick(red, at: 3), pick(Colour(red: .nan, green: 0, blue: 0), at: 9),
            pick(paper, at: 2), pick(Colour(rgb8: 1, 2, 3), at: 0),
        ])
        #expect(history.picks.map(\.colour) == [ink, red, paper])
    }

    @Test func removeAll() {
        var history = ColourHistory([pick(red)])
        history.removeAll()
        #expect(history.picks.isEmpty)
    }
}

@Suite struct ContrastSelectionTests {
    private let picks = [red, ink, paper].enumerated().map { ColourPick(colour: $1, pickedAt: Date(timeIntervalSince1970: Double(10 - $0))) }
    private var history: ColourHistory { ColourHistory(picks) }

    @Test func fallsBackToTheTwoNewest() {
        let selection = ContrastSelection()
        #expect(selection.pair(in: history, fallbackToNewest: true).map { [$0.0.id, $0.1.id] } == [picks[0].id, picks[1].id])
        #expect(selection.pair(in: history, fallbackToNewest: false) == nil)
        #expect(selection.pair(in: ColourHistory([picks[0]]), fallbackToNewest: true) == nil)
    }

    @Test func toggleKeepsTwoReplacingTheFirstChosen() {
        var selection = ContrastSelection()
        selection.toggle(picks[0].id)
        #expect(selection.pair(in: history, fallbackToNewest: true) == nil)  // one chosen: no pair, no fallback
        selection.toggle(picks[2].id)
        #expect(selection.pair(in: history, fallbackToNewest: false).map { [$0.0.id, $0.1.id] } == [picks[0].id, picks[2].id])
        selection.toggle(picks[1].id)
        #expect(selection.chosen == [picks[2].id, picks[1].id])
        selection.toggle(picks[2].id)
        #expect(selection.chosen == [picks[1].id])
    }

    @Test func forgetsPicksThatAreGone() {
        var selection = ContrastSelection(chosen: [picks[0].id, picks[1].id])
        selection.keep(ColourHistory([picks[1], picks[2]]))
        #expect(selection.chosen == [picks[1].id])
    }
}

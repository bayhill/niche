import Foundation
import NotchCore
import NotchCoreTesting
import Testing
import UniformTypeIdentifiers

private func activity(_ id: String, _ p: LiveActivity.Priority, updated: TimeInterval = 0, expires: TimeInterval? = nil) -> LiveActivity {
    LiveActivity(
        id: id, module: ModuleID(id), priority: p, leading: .text(id),
        expiresAt: expires.map { Date(timeIntervalSince1970: $0) }, updatedAt: Date(timeIntervalSince1970: updated),
        accessibilityLabel: id
    )
}

@Suite struct ActivityArbiterTests {
    let now = Date(timeIntervalSince1970: 100)

    @Test func emptyGivesNil() { #expect(ActivityArbiter.select([], now: now) == nil) }

    @Test func highestPriorityWins() {
        let picked = ActivityArbiter.select([activity("a", .ambient, updated: 99), activity("b", .attention, updated: 1), activity("c", .progress, updated: 50)], now: now)
        #expect(picked?.id == "b")
    }

    @Test func newestWinsWithinPriority() {
        #expect(ActivityArbiter.select([activity("a", .progress, updated: 10), activity("b", .progress, updated: 20)], now: now)?.id == "b")
    }

    @Test func idBreaksExactTies() {
        #expect(ActivityArbiter.select([activity("b", .passive), activity("a", .passive)], now: now)?.id == "a")
    }

    @Test func expiredIsIgnored() {
        let picked = ActivityArbiter.select([activity("a", .attention, expires: 100), activity("b", .ambient, expires: 101)], now: now)
        #expect(picked?.id == "b")
    }

    @Test func fullscreenShowsOnlyAttention() {
        #expect(ActivityArbiter.select([activity("a", .progress)], now: now, fullscreen: true) == nil)
        #expect(ActivityArbiter.select([activity("a", .progress), activity("b", .attention)], now: now, fullscreen: true)?.id == "b")
    }
}

@Suite struct NudgeArbiterTests {
    let now = Date(timeIntervalSince1970: 100)

    func nudge(_ id: String, expires: TimeInterval? = nil) -> Nudge {
        Nudge(
            id: id, module: .calendar, symbol: "calendar", title: id, message: "m",
            expiresAt: expires.map { Date(timeIntervalSince1970: $0) }, accessibilityLabel: id
        )
    }

    @Test func emptyGivesNil() { #expect(NudgeArbiter.select([], now: now) == nil) }

    @Test func expiredIsIgnored() {
        #expect(NudgeArbiter.select([nudge("a", expires: 100)], now: now) == nil)
        #expect(NudgeArbiter.select([nudge("a", expires: 100), nudge("b", expires: 101)], now: now)?.id == "b")
    }

    @Test func soonestExpiryWinsAndNoExpiryComesLast() {
        #expect(NudgeArbiter.select([nudge("a"), nudge("b", expires: 500), nudge("c", expires: 200)], now: now)?.id == "c")
        #expect(NudgeArbiter.select([nudge("b"), nudge("a")], now: now)?.id == "a")
    }

    @Test func sampleIsShowable() {
        let sample = Nudge.sample(now: now)
        #expect(NudgeArbiter.select([sample], now: now) == sample)
        #expect(sample.actionTitle == "Join")
    }
}

@MainActor @Suite struct DropRouterTests {
    let png = DropItem.file(URL(fileURLWithPath: "/tmp/a.png"))
    let jpg = DropItem.file(URL(fileURLWithPath: "/tmp/b.JPG"))
    let pdf = DropItem.file(URL(fileURLWithPath: "/tmp/c.pdf"))
    let text = DropItem.text("hello")

    func modules() -> [FakeModule] {
        let convert = FakeModule(.convert)
        convert.acceptance = { $0.isImage ? .accept(weight: DropWeight.preferred) : .reject }
        let shelf = FakeModule(.shelf)
        shelf.acceptance = { $0.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject }
        return [convert, shelf]
    }

    @Test func contentTypes() {
        #expect(png.isImage && jpg.isImage)
        #expect(!pdf.isImage && !text.isImage)
        #expect(DropItem.imageData(Data(), suggestedName: nil).isImage)
    }

    @Test func imagesGoToConvertOthersToShelf() {
        let routes = DropRouter.route(DropPayload(items: [png, pdf, jpg, text]), among: modules())
        #expect(routes.map(\.module) == [.convert, .shelf])
        #expect(routes[0].payload.items == [png, jpg])
        #expect(routes[1].payload.items == [pdf])
    }

    @Test func optionKeySendsEverythingAcceptableToShelf() {
        let routes = DropRouter.route(DropPayload(items: [png, text], optionKey: true), among: modules())
        #expect(routes.count == 1)
        #expect(routes[0].module == .shelf)
        #expect(routes[0].payload.items == [png])
        #expect(routes[0].payload.optionKey)
    }

    @Test func explicitModuleTargetWins() {
        let routes = DropRouter.route(DropPayload(items: [png, pdf], target: .module(.shelf)), among: modules())
        #expect(routes.map(\.module) == [.shelf])
        #expect(routes[0].payload.items == [png, pdf])
    }

    @Test func unknownTargetOrNothingAcceptedGivesNoRoutes() {
        #expect(DropRouter.route(DropPayload(items: [png], target: .module("nope")), among: modules()).isEmpty)
        #expect(DropRouter.route(DropPayload(items: [text]), among: modules()).isEmpty)
    }

    @Test func tieGoesToEarlierModule() {
        let a = FakeModule("a"), b = FakeModule("b")
        a.acceptance = { _ in .accept(weight: 5) }
        b.acceptance = { _ in .accept(weight: 5) }
        #expect(DropRouter.route(DropPayload(items: [png]), among: [a, b]).map(\.module) == ["a"])
    }

    @Test func hintComesFromModuleReceivingMostItems() {
        let m = modules()
        m[0].hint = DropHint(title: "Drop to convert to WebP", symbol: "photo")
        m[1].hint = DropHint(title: "Add to Shelf", symbol: "tray")
        #expect(DropRouter.hint(for: DropPayload(items: [png, jpg, pdf]), among: m)?.title == "Drop to convert to WebP")
        #expect(DropRouter.hint(for: DropPayload(items: [pdf]), among: m)?.title == "Add to Shelf")
        #expect(DropRouter.hint(for: DropPayload(items: [text]), among: m) == nil)
    }
}

@MainActor @Suite struct SettingsStoreTests {
    static let quality = SettingsKey<Int>("test.quality", default: 80)
    struct Options: Codable, Sendable, Equatable { var lossless = false; var maxEdge: Int? }
    static let options = SettingsKey<Options>("test.options", default: Options())

    @Test func defaultsThenRoundTrip() {
        let store = SettingsStore.ephemeral()
        #expect(store.get(Self.quality) == 80)
        store.set(Self.quality, 65)
        #expect(store.get(Self.quality) == 65)
        store.set(Self.options, Options(lossless: true, maxEdge: 2560))
        #expect(store.get(Self.options) == Options(lossless: true, maxEdge: 2560))
        store.reset(Self.quality)
        #expect(store.get(Self.quality) == 80)
    }

    @Test func bindingWritesThrough() {
        let store = SettingsStore.ephemeral()
        store.binding(Self.quality).wrappedValue = 42
        #expect(store.get(Self.quality) == 42)
    }

    @Test func changesAreObservable() async {
        let store = SettingsStore.ephemeral()
        await confirmation { changed in
            withObservationTracking { _ = store.get(Self.quality) } onChange: { changed() }
            store.set(Self.quality, 1)
        }
    }
}

@Suite struct ScreenMetricsTests {
    @Test func realNotch() {
        let m = ScreenMetrics.mbp14MoreSpace
        #expect(m.hasNotch)
        #expect(m.notchRect == CGRect(x: 790, y: 1131, width: 220, height: 38))
        #expect(m.effectiveNotchRect() == m.notchRect)
        #expect(m.menuBarHeight == 39)  // the menu bar is 1 pt taller than the notch
        #expect(ScreenMetrics.mbp14Default.notchRect == CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    @Test func noNotchUsesVirtualPill() {
        let m = ScreenMetrics.external1080p
        #expect(!m.hasNotch && m.notchRect == nil)
        #expect(m.menuBarHeight == 25)
        #expect(m.effectiveNotchRect() == CGRect(x: 1512 + 960 - 90, y: 1080 - 24, width: 180, height: 24))
        #expect(ScreenMetrics.externalHiddenMenuBar.menuBarHeight == 0)
    }

    @Test func simulatedNotchOverridesPhysical() {
        let r = ScreenMetrics.mbp14MoreSpace.effectiveNotchRect(simulated: CGSize(width: 200, height: 30))
        #expect(r == CGRect(x: 800, y: 1139, width: 200, height: 30))
    }
}

@Suite struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(999) == "999 B")
        #expect(Format.bytes(264_000) == "264 KB")
        #expect(Format.bytes(1_200_000) == "1.2 MB")
        #expect(Format.bytes(150_000_000) == "150 MB")
        #expect(Format.bytes(2_500_000_000) == "2.5 GB")
    }

    @Test func saving() {
        #expect(Format.saving(0.78) == "\u{2212}78%")
        #expect(Format.saving(-0.12) == "+12%")
        #expect(Format.saving(0.001) == "0%")
    }

    @Test func playback() {
        #expect(Format.playback(seconds: 84) == "1:24")
        #expect(Format.playback(seconds: 0) == "0:00")
        #expect(Format.playback(seconds: 3723) == "1:02:03")
        #expect(Format.playback(seconds: 137, remaining: true) == "\u{2212}2:17")
        #expect(Format.playback(seconds: -.infinity) == "0:00")
    }

    @Test func age() {
        #expect(Format.age(seconds: 12) == "now")
        #expect(Format.age(seconds: 4 * 60 + 59) == "4m")
        #expect(Format.age(seconds: 3600) == "1h")
        #expect(Format.age(seconds: 3 * 86400 + 5) == "3d")
    }

    @Test func countdown() {
        #expect(Format.countdown(seconds: -5) == "now")
        #expect(Format.countdown(seconds: 45) == "45s")
        #expect(Format.countdown(seconds: 60) == "1m")
        #expect(Format.countdown(seconds: 12 * 60) == "12m")
        #expect(Format.countdown(seconds: 3600) == "1h")
        #expect(Format.countdown(seconds: 65 * 60) == "1h 5m")
    }
}

@MainActor @Suite struct FileDragTests {
    @Test func providerOffersTheFilesNameWithoutItsExtension() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let url = try TestImage.write(TestImage.solid(), to: env.root.appending(path: "Shot 2026-11-21 at 19.13.31.png"))
        let provider = FileDrag.provider(for: url)
        // The receiver appends ".png" for the registered type; a name that already ends in it lands as ".png.png".
        #expect(provider.suggestedName == "Shot 2026-11-21 at 19.13.31")
        #expect(provider.registeredTypeIdentifiers.first == "public.png")
    }

    @Test func missingFileStillGetsAName() {
        let provider = FileDrag.provider(for: URL(fileURLWithPath: "/nonexistent/report.pdf"))
        #expect(provider.suggestedName == "report")
    }

    @Test(arguments: [
        ("Marketing & Demo Stuff.pdf", "Marketing & Demo Stuff"),
        ("IMG_0772.HEIC", "IMG_0772"),
        ("photo.jpg", "photo"),
        ("archive.tar.gz", "archive.tar"),
        ("Shot 2026-11-21 at 19.13.31.png", "Shot 2026-11-21 at 19.13.31"),
        // Nothing is appended to a name without an extension, so it is offered whole.
        ("Makefile", "Makefile"),
        ("v1.2 notes", "v1.2 notes"),
        (".hidden", ".hidden"),
        ("trailing.", "trailing."),
    ])
    func suggestedNameDropsOnlyARealExtension(name: String, expected: String) {
        #expect(FileDrag.suggestedName(for: URL(fileURLWithPath: "/tmp/\(name)")) == expected)
    }

    /// The extension the receiver appends comes from the provider's first registered type. Offered name plus that
    /// extension must be the file's own name (case aside), never a doubled one.
    @Test(arguments: ["Marketing & Demo Stuff.pdf", "IMG_0772.HEIC", "hero.webp", "archive.tar.gz", "data.xyz"])
    func offeredNamePlusTheTypesExtensionIsTheOriginalName(name: String) throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let url = env.root.appending(path: name)
        try Data([1]).write(to: url)
        let provider = FileDrag.provider(for: url)
        let type = try #require(provider.registeredTypeIdentifiers.first.flatMap { UTType($0) })
        let appended = try #require(type.preferredFilenameExtension)
        let landed = "\(try #require(provider.suggestedName)).\(appended)"
        #expect(landed.lowercased() == name.lowercased())
    }
}

@Suite struct IdentityTests {
    /// `Log.subsystem` is the Swift-side copy of the bundle identifier; Info.plist is the source the build uses.
    @Test func subsystemMatchesInfoPlist() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == Log.subsystem)
    }
}

@Suite struct DebugOptionsTests {
    @Test func parses() {
        let o = DebugOptions(arguments: ["--simulate-notch", "220x38", "--force-state", "expanded", "--page", "shelf", "--fps", "--fixtures", "--junk"])
        #expect(o.simulateNotch == CGSize(width: 220, height: 38))
        #expect(o.forceState == "expanded")
        #expect(o.page == .shelf)
        #expect(o.fps && o.fixtures && !o.demo && !o.dumpMetrics)
    }

    @Test func ignoresMalformedNotch() {
        #expect(DebugOptions(arguments: ["--simulate-notch", "wide"]).simulateNotch == nil)
        #expect(DebugOptions(arguments: []) == DebugOptions())
    }
}

@MainActor @Suite struct TestEnvironmentTests {
    @Test func isIsolated() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        #expect(env.directories.appSupport.path.hasPrefix(env.root.path))
        #expect(FileManager.default.fileExists(atPath: env.directories.downloads.path))
        let url = try TestImage.write(TestImage.solid(), to: env.root.appending(path: "x.png"))
        #expect((try Data(contentsOf: url)).count > 0)
    }
}

@MainActor @Suite struct ModuleSwitchTests {
    @Test func ordinaryModulesAreOnUntilSwitchedOff() {
        let settings = SettingsStore.ephemeral()
        #expect(CoreSettings.isEnabled(.shelf, in: settings))
        CoreSettings.setEnabled(.shelf, false, in: settings)
        #expect(!CoreSettings.isEnabled(.shelf, in: settings))
        #expect(settings.get(CoreSettings.disabledModules) == ["shelf"])
        #expect(!CoreSettings.isEnabled(.shelf, in: settings, fixtures: true))
        CoreSettings.setEnabled(.shelf, true, in: settings)
        #expect(CoreSettings.isEnabled(.shelf, in: settings))
        #expect(settings.get(CoreSettings.disabledModules).isEmpty)
    }

    @Test func optInModulesAreOffUntilSwitchedOn() {
        let settings = SettingsStore.ephemeral()
        for id in CoreSettings.optInModules {
            #expect(!CoreSettings.isEnabled(id, in: settings))
            // A fixtures run shows every module with its sample data.
            #expect(CoreSettings.isEnabled(id, in: settings, fixtures: true))
        }
        CoreSettings.setEnabled(.builds, true, in: settings)
        #expect(CoreSettings.isEnabled(.builds, in: settings))
        #expect(!CoreSettings.isEnabled(.devServers, in: settings))
        #expect(settings.get(CoreSettings.enabledModules) == ["builds"])
        #expect(settings.get(CoreSettings.disabledModules).isEmpty)
        CoreSettings.setEnabled(.builds, false, in: settings)
        #expect(!CoreSettings.isEnabled(.builds, in: settings))
        #expect(settings.get(CoreSettings.enabledModules).isEmpty)
    }
}

@Suite struct CommandRunnerTests {
    @Test func capturesOutputAndStatus() async {
        let runner = ProcessCommandRunner()
        let echo = await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: .seconds(5))
        #expect(echo.succeeded && echo.text == "hello\n")
        let failing = await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo oops >&2; exit 3"], timeout: .seconds(5))
        #expect(failing.status == 3 && !failing.succeeded)
        #expect(String(decoding: failing.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func passesTheEnvironmentGiven() async {
        let result = await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["NOTCHER_TEST": "1"], timeout: .seconds(5)
        )
        #expect(result.text == "NOTCHER_TEST=1\n")
    }

    @Test func stopsACommandThatRunsTooLong() async {
        let result = await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(100))
        #expect(result.timedOut && !result.succeeded)
    }

    @Test func aMissingToolIsAResultNotACrash() async {
        let result = await ProcessCommandRunner().run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1))
        #expect(result.status == -1 && !result.succeeded)
    }

    @Test func theScriptedRunnerRecordsAndAnswers() async {
        let runner = ScriptedCommandRunner { call in CommandResult(status: 0, stdout: Data(call.arguments.joined(separator: " ").utf8)) }
        let result = await runner.run(URL(fileURLWithPath: "/usr/bin/tool"), arguments: ["a", "b"], timeout: .seconds(1))
        #expect(result.text == "a b")
        #expect(runner.calls.map(\.arguments) == [["a", "b"]])
    }
}

import Foundation
import NotchCore
import NotchCoreTesting
import Testing
@testable import ScreenshotsModule

// MARK: - Fakes

/// Stands in for Spotlight: records what the module asked for and delivers whatever the test sends.
@MainActor
final class FakeSource: ScreenshotSource {
    private(set) var calls: [String] = []
    private var deliver: (@MainActor (ScreenshotBatch) -> Void)?
    var access: FolderAccess = .granted
    var isRunning: Bool { deliver != nil }
    var startCount: Int { calls.filter { $0 == "start" }.count }
    var accessRequests: Int { calls.filter { $0 == "access" }.count }

    func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void) {
        calls.append("start")
        self.deliver = deliver
    }

    func stop() {
        if deliver != nil { calls.append("stop") }
        deliver = nil
    }

    func requestFolderAccess() async -> FolderAccess {
        calls.append("access")
        return access
    }

    func send(_ shots: [Screenshot], initial: Bool = false) {
        deliver?(ScreenshotBatch(screenshots: shots, isInitial: initial))
    }
}

/// Never decodes a file: hands back a generated picture, or whatever result the test set for a path.
actor FakeThumbnails: ScreenshotThumbnailing {
    private(set) var requests: [URL] = []
    private var results: [String: ThumbnailResult] = [:]
    nonisolated let image = SendableImage(TestImage.solid(width: 16, height: 10))

    func set(_ result: ThumbnailResult, for url: URL) { results[url.path] = result }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> ThumbnailResult {
        requests.append(url)
        return results[url.path] ?? .image(image)
    }
}

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date = Date()) { self.now = now }
}

@MainActor
final class Revealed { var urls: [[URL]] = [] }

@MainActor
struct Rig {
    let env: TestEnvironment
    let source = FakeSource()
    let thumbnails = FakeThumbnails()
    let clock = TestClock()
    let revealed = Revealed()
    let module: ScreenshotsModule

    init(enabled: Bool = false, activityDuration: Duration = .seconds(30)) throws {
        env = try TestEnvironment()
        if enabled { env.settings.set(ScreenshotsModule.enabledKey, true) }
        let clock = clock, revealed = revealed
        module = ScreenshotsModule(
            source: source, thumbnails: thumbnails, now: { clock.now }, reveal: { revealed.urls.append($0) },
            openPrivacySettings: {}, activityDuration: activityDuration, pruneInterval: .seconds(3600)
        )
    }

    func start(mayPrompt: Bool = false) async { await module.start(env.context(for: .screenshots, mayPrompt: mayPrompt)) }

    /// A screenshot taken `minutesAgo` before the rig's clock, at an invented path.
    func shot(_ name: String, minutesAgo: Double = 0) -> Screenshot {
        let taken = clock.now.addingTimeInterval(-minutesAgo * 60)
        return Screenshot(
            url: URL(fileURLWithPath: "/Users/Shared/Notcher Tests/\(name).png"), createdAt: taken, modifiedAt: taken,
            pixelSize: PixelSize(width: 1200, height: 800), bytes: 240_000
        )
    }

    func cleanUp() {
        module.stop()
        env.cleanUp()
    }
}

/// Waits for something the module does in a task (generous: parallel tests share the main actor).
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

// MARK: - The list

@MainActor @Suite struct ScreenshotListTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func shot(_ name: String, minutesAgo: Double) -> Screenshot {
        Screenshot(url: URL(fileURLWithPath: "/tmp/shots/\(name).png"), createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func newestFirstAndCapped() {
        let shots = (0..<15).map { shot("s\($0)", minutesAgo: Double($0)) }.shuffled()
        let list = ScreenshotList(shots, now: now)
        #expect(list.items.count == 12)
        #expect(list.items.map(\.name) == (0..<12).map { "s\($0).png" })
        #expect(ScreenshotList(shots, now: now, capacity: 3).items.map(\.name) == ["s0.png", "s1.png", "s2.png"])
    }

    @Test func onlyTheLast24Hours() {
        var list = ScreenshotList(
            [shot("hour", minutesAgo: 60), shot("almost-a-day", minutesAgo: 24 * 60 - 1), shot("over-a-day", minutesAgo: 24 * 60 + 1)],
            now: now
        )
        #expect(list.items.map(\.name) == ["hour.png", "almost-a-day.png"])
        // Two hours later the older one has aged out.
        list.prune(now: now.addingTimeInterval(2 * 3600))
        #expect(list.items.map(\.name) == ["hour.png"])
    }

    @Test func oneEntryPerFileTheNewestReport() {
        let older = shot("same", minutesAgo: 30)
        var newer = shot("same", minutesAgo: 2)
        newer.url = URL(fileURLWithPath: "/tmp/shots/./same.png")
        let list = ScreenshotList([older, shot("other", minutesAgo: 10), newer], now: now)
        #expect(list.items.map(\.dedupeKey) == ["/tmp/shots/same.png", "/tmp/shots/other.png"])
        #expect(list.items.first?.createdAt == newer.createdAt)
    }

    @Test func goneFilesAreDropped() {
        let a = shot("a", minutesAgo: 1), b = shot("b", minutesAgo: 2), c = shot("c", minutesAgo: 3)
        var list = ScreenshotList([a, b, c], now: now)
        list.remove(URL(fileURLWithPath: "/tmp/shots/./b.png"))
        #expect(list.items.map(\.name) == ["a.png", "c.png"])
        // The source stops reporting a deleted file: rebuilding from its results drops it.
        list.replace(with: [c], now: now)
        #expect(list.items.map(\.name) == ["c.png"])
        // A screenshot moved to the Trash is not listed.
        let trashed = Screenshot(url: URL(fileURLWithPath: "/Users/someone/.Trash/t.png"), createdAt: now)
        #expect(ScreenshotList([trashed, c], now: now).items.map(\.name) == ["c.png"])
    }

    @Test func spotlightAttributes() {
        let date = now
        func make(path: String? = "/tmp/a.png", type: String? = "public.png", content: Date? = date, file: Date? = nil,
                  width: Int? = 100, height: Int? = 50) -> Screenshot? {
            Screenshot.fromSpotlight(path: path, contentType: type, contentCreated: content, fileCreated: file, modified: nil,
                                     pixelWidth: width, pixelHeight: height, bytes: 1234)
        }
        #expect(make()?.pixelSize == PixelSize(width: 100, height: 50))
        #expect(make()?.bytes == 1234)
        #expect(make(type: "public.heic") != nil)
        #expect(make(type: "com.apple.quicktime-movie") == nil)  // screen recordings carry the same flag
        #expect(make(type: nil) == nil)
        #expect(make(path: nil) == nil)
        #expect(make(content: nil) == nil)
        #expect(make(content: nil, file: date.addingTimeInterval(-5))?.createdAt == date.addingTimeInterval(-5))
        #expect(make(width: 0)?.pixelSize == nil)
        #expect(PixelSize(width: 2940, height: 1912).text == "2940 \u{00D7} 1912")
    }
}

// MARK: - The module

@MainActor @Suite struct ScreenshotsModuleTests {
    @Test func isAPage() {
        let module = ScreenshotsModule.sample()
        #expect(module.id == .screenshots)
        #expect(module.placement == .page(order: 30))
    }

    @Test func settingsKeys() {
        #expect(ScreenshotsModule.enabledKey.name == "screenshots.enabled")
        #expect(ScreenshotsModule.enabledKey.defaultValue == false)
        #expect(ScreenshotsModule.showBesideNotchKey.name == "screenshots.showBesideNotch")
        #expect(ScreenshotsModule.showBesideNotchKey.defaultValue == true)
    }

    @Test func dormantUntilTheUserAsks() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        await rig.start()
        #expect(rig.module.status == .off)
        #expect(rig.source.calls.isEmpty)  // no query, no folder access
        #expect(await rig.thumbnails.requests.isEmpty)
        #expect(rig.module.settingsView() != nil)

        // The click on "Show screenshots": folder first, then the query.
        rig.module.enable()
        try await eventually { rig.source.isRunning }
        #expect(rig.source.calls == ["access", "start"])
        #expect(rig.module.status == .watching)
        #expect(rig.module.folderAccess == .granted)
        #expect(rig.env.settings.get(ScreenshotsModule.enabledKey))
    }

    @Test func mayPromptTurnsItOn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        await rig.start(mayPrompt: true)
        try await eventually { rig.source.isRunning }
        #expect(rig.source.calls == ["access", "start"])
        #expect(rig.env.settings.get(ScreenshotsModule.enabledKey))
    }

    @Test func enabledEarlierStartsOnlyTheQuery() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        // Without mayPrompt: no folder access, just the index.
        #expect(rig.source.calls == ["start"])
        rig.source.send([rig.shot("a", minutesAgo: 5), rig.shot("b", minutesAgo: 1)], initial: true)
        #expect(rig.module.screenshots.map(\.name) == ["b.png", "a.png"])
        // Nothing opened a file: thumbnails load only when a tile is shown.
        #expect(await rig.thumbnails.requests.isEmpty)
        #expect(rig.module.liveActivity == nil)
    }

    @Test func startIsIdempotent() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        await rig.start()
        #expect(rig.source.startCount == 1)
    }

    @Test func onlyNewScreenshotsAreAnnounced() async throws {
        let rig = try Rig(enabled: true, activityDuration: .milliseconds(150)); defer { rig.cleanUp() }
        await rig.start()
        let old = rig.shot("old", minutesAgo: 10)
        rig.source.send([old], initial: true)
        #expect(rig.module.liveActivity == nil)

        // A file seen for the first time, but taken an hour ago (moved in): listed, not announced.
        let movedIn = rig.shot("moved-in", minutesAgo: 60)
        rig.source.send([old, movedIn])
        #expect(rig.module.screenshots.count == 2)

        let fresh = rig.shot("fresh", minutesAgo: 0)
        rig.source.send([old, movedIn, fresh])
        try await eventually { rig.module.liveActivity != nil }
        let activity = try #require(rig.module.liveActivity)
        #expect(activity.module == .screenshots)
        #expect(activity.priority == .passive)
        #expect(activity.files == [fresh.url])
        #expect(activity.trailing == .text("now", tint: .secondary))
        let image = rig.thumbnails.image
        #expect(activity.leading == .image(image))
        #expect(activity.updatedAt == rig.clock.now)
        #expect(activity.expiresAt == rig.clock.now.addingTimeInterval(0.15))
        // Reading it again (the clock has moved on) gives the same value.
        rig.clock.now = rig.clock.now.addingTimeInterval(1)
        #expect(rig.module.liveActivity == activity)
        #expect(await rig.thumbnails.requests == [fresh.url])

        try await eventually { rig.module.liveActivity == nil }
        #expect(rig.module.liveActivity == nil)
        #expect(rig.module.screenshots.map(\.name) == ["fresh.png", "old.png", "moved-in.png"])
    }

    @Test func settingTurnsTheActivityOff() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        rig.source.send([], initial: true)
        rig.source.send([rig.shot("one")])
        try await eventually { rig.module.liveActivity != nil }
        rig.env.settings.set(ScreenshotsModule.showBesideNotchKey, false)
        #expect(rig.module.liveActivity == nil)

        rig.source.send([rig.shot("one"), rig.shot("two")])
        try await eventually { rig.module.thumbnail(for: rig.shot("two")) != nil }
        #expect(rig.module.liveActivity == nil)
        rig.env.settings.set(ScreenshotsModule.showBesideNotchKey, true)
        #expect(rig.module.liveActivity?.files == [rig.shot("two").url])
    }

    @Test func unreadableNewScreenshotStillAnnouncedWithASymbol() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        rig.source.send([], initial: true)
        let shot = rig.shot("locked")
        await rig.thumbnails.set(.unreadable, for: shot.url)
        rig.source.send([shot])
        try await eventually { rig.module.liveActivity != nil }
        #expect(rig.module.liveActivity?.leading == .symbol("camera.viewfinder", tint: .accent))
        #expect(rig.module.screenshots == [shot])
        #expect(rig.module.needsAccess)
    }

    @Test func goneFileIsDropped() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        let gone = rig.shot("gone", minutesAgo: 2), kept = rig.shot("kept", minutesAgo: 3)
        await rig.thumbnails.set(.missing, for: gone.url)
        rig.source.send([gone, kept], initial: true)
        await rig.module.loadThumbnail(for: gone)
        #expect(rig.module.screenshots == [kept])
        // Spotlight may still report it for a moment: it stays out.
        rig.source.send([gone, kept])
        #expect(rig.module.screenshots == [kept])
        #expect(rig.module.liveActivity == nil)
    }

    @Test func unreadableTileStaysAndCanRetry() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        let shot = rig.shot("locked", minutesAgo: 1)
        await rig.thumbnails.set(.unreadable, for: shot.url)
        rig.source.send([shot], initial: true)
        await rig.module.loadThumbnail(for: shot)
        #expect(rig.module.screenshots == [shot])
        #expect(rig.module.thumbnail(for: shot) == .unreadable)
        #expect(rig.module.needsAccess)

        await rig.thumbnails.set(.image(rig.thumbnails.image), for: shot.url)
        await rig.module.loadThumbnail(for: shot)
        #expect(rig.module.thumbnail(for: shot) == .unreadable)  // an ordinary load does not repeat
        await rig.module.retryUnreadable()
        #expect(rig.module.thumbnail(for: shot)?.image != nil)
        #expect(!rig.module.needsAccess)
    }

    @Test func thumbnailsAreCachedPerFileAndModification() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        var shot = rig.shot("edited", minutesAgo: 1)
        rig.source.send([shot], initial: true)
        await rig.module.loadThumbnail(for: shot)
        await rig.module.loadThumbnail(for: shot)
        #expect(await rig.thumbnails.requests.count == 1)
        // Marked up in Preview: a new modification date, a new picture.
        shot.modifiedAt = rig.clock.now
        rig.source.send([shot])
        await rig.module.loadThumbnail(for: shot)
        #expect(await rig.thumbnails.requests.count == 2)
    }

    @Test func deniedFolderAccessIsKnown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.source.access = .denied
        await rig.start()
        rig.module.enable()
        try await eventually { rig.source.isRunning }
        #expect(rig.module.folderAccess == .denied)
        rig.module.retry()
        try await eventually { rig.source.accessRequests == 2 && rig.source.isRunning }
        #expect(rig.source.calls == ["access", "start", "stop", "access", "start"])
    }

    @Test func convertAndShelfGoThroughServices() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        let shot = rig.shot("pr", minutesAgo: 1)
        #expect(rig.module.canConvert)
        #expect(rig.module.canShelve)
        rig.module.convert(shot)
        rig.module.addToShelf(shot)
        #expect(rig.env.converter.requests == [[.file(shot.url)]])
        #expect(rig.env.shelf.added.map(\.urls) == [[shot.url]])
        #expect(rig.env.shelf.added.map(\.origin) == [.dropped])

        // Looked up at use time: a disabled provider hides the button and the action does nothing.
        rig.env.services.converter = nil
        rig.env.services.shelf = nil
        #expect(!rig.module.canConvert)
        #expect(!rig.module.canShelve)
        rig.module.convert(shot)
        rig.module.addToShelf(shot)
        #expect(rig.env.converter.requests.count == 1)
        #expect(rig.env.shelf.added.count == 1)
    }

    @Test func revealGoesToTheInjectedClosure() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        let shot = rig.shot("find-me")
        rig.module.reveal(shot)
        #expect(rig.revealed.urls == [[shot.url]])
    }

    @Test func stopStopsTheSourceAndForgets() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        rig.source.send([], initial: true)
        rig.source.send([rig.shot("new")])
        try await eventually { rig.module.liveActivity != nil }
        rig.module.stop()
        #expect(!rig.source.isRunning)
        #expect(rig.source.calls == ["start", "stop"])
        #expect(rig.module.screenshots.isEmpty)
        #expect(rig.module.liveActivity == nil)
        #expect(rig.module.status == .off)
        // Started again, it rebuilds from the query: nothing was kept.
        await rig.start()
        #expect(rig.source.startCount == 2)
        rig.source.send([rig.shot("new")], initial: true)
        #expect(rig.module.screenshots.count == 1)
        #expect(rig.module.liveActivity == nil)
    }

    @Test func disableStopsAndForgets() async throws {
        let rig = try Rig(enabled: true); defer { rig.cleanUp() }
        await rig.start()
        rig.source.send([rig.shot("a")], initial: true)
        rig.module.disable()
        #expect(!rig.source.isRunning)
        #expect(rig.module.status == .off)
        #expect(rig.module.screenshots.isEmpty)
        #expect(!rig.env.settings.get(ScreenshotsModule.enabledKey))
    }

    @Test func sampleTouchesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = ScreenshotsModule.sample()
        #expect(module.source is NoScreenshotSource)
        #expect(module.status == .watching)
        #expect(module.screenshots.count >= 4)
        #expect(module.screenshots.allSatisfy { module.thumbnail(for: $0)?.image != nil })
        #expect(module.screenshots.allSatisfy { $0.url.path.hasPrefix(ScreenshotSamples.folder) })
        await module.start(env.context(for: .screenshots))
        #expect(module.liveActivity == nil)
        #expect(!env.settings.get(ScreenshotsModule.enabledKey))
        for dir in [env.directories.appSupport, env.directories.caches, env.directories.downloads, env.directories.home] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        }
        module.stop()
        #expect(!module.screenshots.isEmpty)
    }
}

// MARK: - ImageIO, on files this test writes

@Suite struct ImageIOThumbnailTests {
    @Test func downsamplesTellsGoneFromUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notcher-screenshots-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TestImage.write(TestImage.solid(width: 1200, height: 600), to: dir.appending(path: "wide.png"))

        let result = await ImageIOThumbnails().thumbnail(for: url, maxPixelSize: 360)
        let image = try #require(result.image)
        #expect(image.cgImage.width == 360)
        #expect(image.cgImage.height == 180)

        #expect(await ImageIOThumbnails().thumbnail(for: dir.appending(path: "nothing.png"), maxPixelSize: 360) == .missing)

        let locked = try TestImage.write(TestImage.solid(), to: dir.appending(path: "locked.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(await ImageIOThumbnails().thumbnail(for: locked, maxPixelSize: 360) == .unreadable)

        let notAnImage = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: notAnImage)
        #expect(await ImageIOThumbnails().thumbnail(for: notAnImage, maxPixelSize: 360) == .unreadable)
    }
}

// MARK: - Snapshots

/// Writes the page in each state to $TMPDIR/notcher-snapshots for visual review.
@MainActor @Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "notcher-snapshots", directoryHint: .isDirectory)

    @Test func pages() async throws {
        let dormant = try Rig(); defer { dormant.cleanUp() }
        await dormant.start()

        let empty = try Rig(enabled: true); defer { empty.cleanUp() }
        await empty.start()
        empty.source.send([], initial: true)

        let denied = try Rig(); defer { denied.cleanUp() }
        denied.source.access = .denied
        await denied.start()
        denied.module.enable()
        try await eventually { denied.source.isRunning }
        denied.source.send([], initial: true)

        let locked = try Rig(enabled: true); defer { locked.cleanUp() }
        await locked.start()
        let shots = [locked.shot("a", minutesAgo: 1), locked.shot("b", minutesAgo: 14)]
        await locked.thumbnails.set(.unreadable, for: shots[0].url)
        locked.source.send(shots, initial: true)
        for shot in shots { await locked.module.loadThumbnail(for: shot) }

        let sample = ScreenshotsModule.sample()
        let env = try TestEnvironment(); defer { env.cleanUp() }
        await sample.start(env.context(for: .screenshots))

        let cases: [(String, ScreenshotsModule)] = [
            ("screenshots", sample), ("screenshots-empty", empty.module), ("screenshots-prompt", dormant.module),
            ("screenshots-denied", denied.module), ("screenshots-locked", locked.module),
        ]
        for (name, module) in cases {
            // The scroll view does not render off-screen, so the row is drawn without one.
            let url = try ViewSnapshot.write(
                ScreenshotsPage(module: module, scrolls: false), size: PanelLayout.pageSize, to: Self.dir.appending(path: "\(name).png")
            )
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        try ViewSnapshot.write(module: sample, to: Self.dir.appending(path: "screenshots-module.png"))
        print("snapshots in \(Self.dir.path)")
    }
}

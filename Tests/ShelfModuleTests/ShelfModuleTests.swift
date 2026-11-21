import Foundation
import NotchCore
import NotchCoreTesting
import Testing
@testable import ShelfModule

@MainActor
private final class Revealed { var urls: [[URL]] = [] }

@MainActor
private func makeShelf(capacity: Int = ShelfList.defaultCapacity, revealed: Revealed = Revealed()) -> ShelfModule {
    ShelfModule(
        thumbnails: NoThumbnails(), reveal: { revealed.urls.append($0) },
        pruneInterval: .seconds(3600), confirmationDuration: .milliseconds(100), capacity: capacity
    )
}

/// Writes `count` small files under the environment's home folder and returns their URLs.
@MainActor
private func files(_ env: TestEnvironment, _ names: [String]) throws -> [URL] {
    try names.map { name in
        let url = env.directories.home.appending(path: name)
        try Data("contents of \(name)".utf8).write(to: url)
        return url
    }
}

@MainActor @Suite struct ShelfListTests {
    private func item(_ path: String) -> ShelfItem { ShelfItem(path: path, origin: .dropped, addedAt: .now) }

    @Test func addPutsNewestFirstInGivenOrder() {
        var list = ShelfList()
        list.add([item("/tmp/a"), item("/tmp/b")])
        list.add([item("/tmp/c")])
        #expect(list.items.map(\.path) == ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    @Test func readdingMovesToFrontWithoutDuplicates() {
        var list = ShelfList()
        list.add([item("/tmp/a"), item("/tmp/b"), item("/tmp/c")])
        list.add([item("/tmp/./b")])
        #expect(list.items.map(\.path) == ["/tmp/./b", "/tmp/a", "/tmp/c"])
        #expect(list.items.count == 3)
    }

    @Test func capDropsOldest() {
        var list = ShelfList()
        list.add((0..<60).map { item("/tmp/f\($0)") })
        #expect(list.items.count == 50)
        #expect(list.items.first?.path == "/tmp/f0")
        #expect(list.items.last?.path == "/tmp/f49")
        list.add([item("/tmp/new")])
        #expect(list.items.count == 50)
        #expect(list.items.first?.path == "/tmp/new")
        #expect(list.items.last?.path == "/tmp/f48")
    }
}

@MainActor @Suite struct ShelfModuleTests {
    @Test func basics() {
        let shelf = makeShelf()
        #expect(shelf.id == .shelf)
        #expect(shelf.placement == .page(order: 10))
        #expect(shelf.liveActivity == nil)
        #expect(shelf.items.isEmpty)
    }

    @Test func addDeduplicatesByResolvedPathAndOrders() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let urls = try files(env, ["a.txt", "b.pdf", "c.zip"])
        shelf.add(urls, origin: .dropped)
        #expect(shelf.items.map(\.name) == ["a.txt", "b.pdf", "c.zip"])

        // A symlink to b resolves to the same file: it moves b to the front instead of adding a second entry.
        let link = env.directories.home.appending(path: "link-to-b")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: urls[1])
        shelf.add([link], origin: .converted)
        #expect(shelf.items.count == 3)
        #expect(shelf.items.first?.origin == .converted)
        #expect(shelf.items.map(\.dedupeKey) == [urls[1], urls[0], urls[2]].map(ShelfItem.dedupeKey(for:)))
        #expect(shelf.items.first?.size == Int64("contents of b.pdf".utf8.count))
        shelf.stop()
    }

    @Test func capAtFiftyNewestFirst() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let urls = try files(env, (0..<55).map { "file-\($0).txt" })
        for url in urls { shelf.add([url], origin: .dropped) }
        #expect(shelf.items.count == 50)
        #expect(shelf.items.first?.name == "file-54.txt")
        #expect(shelf.items.last?.name == "file-5.txt")
        shelf.stop()
    }

    @Test func persistenceRoundTrip() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let urls = try files(env, ["one.png", "two.mov"])

        let first = makeShelf()
        await first.start(env.context(for: .shelf))
        first.add([urls[1]], origin: .dropped)
        first.add([urls[0]], origin: .converted)
        let saved = first.items
        first.stop()
        #expect(FileManager.default.fileExists(atPath: ShelfFiles.storeURL(in: env.directories).path))

        let second = makeShelf()
        await second.start(env.context(for: .shelf))
        #expect(second.items == saved)
        #expect(second.items.map(\.origin) == [.converted, .dropped])
        second.stop()
    }

    @Test func storeHoldsReferencesNotContents() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        shelf.add(try files(env, ["secret.txt"]), origin: .dropped)
        let json = try String(contentsOf: ShelfFiles.storeURL(in: env.directories), encoding: .utf8)
        #expect(json.contains("secret.txt"))
        #expect(!json.contains("contents of secret.txt"))
        shelf.stop()
    }

    @Test func deletedFilesArePrunedAtLoad() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let urls = try files(env, ["keep.txt", "gone.txt"])
        let first = makeShelf()
        await first.start(env.context(for: .shelf))
        first.add(urls, origin: .dropped)
        first.stop()

        try FileManager.default.removeItem(at: urls[1])
        let second = makeShelf()
        await second.start(env.context(for: .shelf))
        #expect(second.items.map(\.name) == ["keep.txt"])
        second.stop()
    }

    @Test func deletedFilesArePrunedWhileRunning() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let urls = try files(env, ["a.txt", "b.txt", "c.txt"])
        shelf.add(urls, origin: .dropped)
        try FileManager.default.removeItem(at: urls[0])
        await shelf.prune()
        #expect(shelf.items.map(\.name) == ["b.txt", "c.txt"])
        // The pruned list was saved too.
        #expect(ShelfFiles.load(from: ShelfFiles.storeURL(in: env.directories)).map(\.name) == ["b.txt", "c.txt"])
        shelf.stop()
    }

    @Test func movedFileIsFollowed() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let url = try files(env, ["draft.txt"])[0]
        shelf.add([url], origin: .dropped)
        let moved = env.directories.home.appending(path: "final.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        await shelf.prune()
        #expect(shelf.items.map(\.name) == ["final.txt"])
        shelf.stop()
    }

    @Test func filesInTrashArePruned() {
        let item = ShelfItem(path: "/Users/someone/.Trash/old.txt", origin: .dropped, addedAt: .now)
        #expect(ShelfFiles.isInTrash(item.path))
        #expect(ShelfFiles.resolve([item]).isEmpty)
    }

    @Test func removeAndClearNeverTouchTheFile() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let urls = try files(env, ["a.txt", "b.txt"])
        let before = try urls.map { try Data(contentsOf: $0) }
        shelf.add(urls, origin: .dropped)

        shelf.remove(shelf.items[0].id)
        #expect(shelf.items.map(\.name) == ["b.txt"])
        shelf.clear()
        #expect(shelf.items.isEmpty)

        #expect(try urls.map { try Data(contentsOf: $0) } == before)
        let listing = try FileManager.default.contentsOfDirectory(atPath: env.directories.home.path).sorted()
        #expect(listing == ["a.txt", "b.txt"])
        shelf.stop()
    }

    @Test func dropAcceptanceAndHint() {
        let shelf = makeShelf()
        let png = DropItem.file(URL(fileURLWithPath: "/tmp/x.png"))
        let pdf = DropItem.file(URL(fileURLWithPath: "/tmp/x.pdf"))
        #expect(shelf.dropAcceptance(for: png) == .accept(weight: DropWeight.fallback))
        #expect(shelf.dropAcceptance(for: pdf) == .accept(weight: DropWeight.fallback))
        #expect(shelf.dropAcceptance(for: .text("hi")) == .reject)
        #expect(shelf.dropAcceptance(for: .imageData(Data(), suggestedName: nil)) == .reject)

        #expect(shelf.dropHint(for: [pdf]) == DropHint(title: "Add to Shelf", subtitle: "1 item", symbol: "tray.and.arrow.down"))
        #expect(shelf.dropHint(for: [pdf, png, .text("x")])?.subtitle == "2 items")
        #expect(shelf.dropHint(for: [.text("x")]) == nil)
    }

    @Test func convertOutbidsShelfForImagesUnlessOptionHeld() {
        let shelf = makeShelf()
        let convert = FakeModule(.convert)
        convert.acceptance = { $0.isImage ? .accept(weight: DropWeight.preferred) : .reject }
        let png = DropItem.file(URL(fileURLWithPath: "/tmp/x.png"))
        let pdf = DropItem.file(URL(fileURLWithPath: "/tmp/x.pdf"))
        let routes = DropRouter.route(DropPayload(items: [png, pdf]), among: [convert, shelf])
        #expect(routes.map(\.module) == [.convert, .shelf])
        #expect(routes[1].payload.items == [pdf])
        let forced = DropRouter.route(DropPayload(items: [png, pdf], optionKey: true), among: [convert, shelf])
        #expect(forced.map(\.module) == [.shelf])
        #expect(forced[0].payload.items == [png, pdf])
    }

    @Test func directDropShowsBriefConfirmation() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        let urls = try files(env, ["a.txt", "b.txt", "c.txt"])

        // Adds from other modules (Convert) stay silent.
        shelf.add([urls[0]], origin: .converted)
        #expect(shelf.liveActivity == nil)

        await shelf.handleDrop(DropPayload(items: urls.map(DropItem.file)))
        #expect(shelf.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(shelf.items.allSatisfy { $0.origin == .dropped })
        let activity = try #require(shelf.liveActivity)
        #expect(activity.priority == .passive)
        #expect(activity.trailing == .text("+3"))  // counts what was dropped, including a re-add
        #expect(activity.expiresAt != nil)

        // Clears itself shortly after (generous deadline: parallel tests share the main actor).
        for _ in 0..<40 where shelf.liveActivity != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(shelf.liveActivity == nil)
        shelf.stop()
    }

    @Test func clickRevealsInFinder() {
        let revealed = Revealed()
        let shelf = makeShelf(revealed: revealed)
        let item = ShelfItem(path: "/tmp/r.txt", origin: .dropped, addedAt: .now)
        shelf.reveal(item)
        #expect(revealed.urls == [[URL(fileURLWithPath: "/tmp/r.txt")]])
    }

    @Test func startIsIdempotentAndLogsReady() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = makeShelf()
        await shelf.start(env.context(for: .shelf))
        shelf.add(try files(env, ["a.txt"]), origin: .dropped)
        await shelf.start(env.context(for: .shelf))
        #expect(shelf.items.count == 1)
        shelf.stop()
    }

    @Test func sampleTouchesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let shelf = ShelfModule.sample()
        #expect(!shelf.items.isEmpty)
        await shelf.start(env.context(for: .shelf))
        await shelf.prune()
        #expect(!shelf.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ShelfFiles.storeURL(in: env.directories).path))
        shelf.stop()
    }

    @Test func snapshots() throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let dir = ProcessInfo.processInfo.environment["NOTCHER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } ?? env.root
        // The scroll view does not render off-screen, so the row is also drawn without one.
        try ViewSnapshot.write(module: ShelfModule.sample(), to: dir.appending(path: "shelf-module.png"))
        let full = try ViewSnapshot.write(ShelfPage(module: ShelfModule.sample(), scrolls: false), size: PanelLayout.pageSize, to: dir.appending(path: "shelf.png"))
        let empty = try ViewSnapshot.write(module: makeShelf(), to: dir.appending(path: "shelf-empty.png"))
        #expect(FileManager.default.fileExists(atPath: full.path))
        #expect(FileManager.default.fileExists(atPath: empty.path))
    }
}

import Foundation
import NotchCore
import UniformTypeIdentifiers

/// One file reference on the shelf. The shelf only remembers where a file is; it never owns the file.
public struct ShelfItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Absolute path the last time the reference was resolved.
    public var path: String
    /// Bookmark that follows the file when it is renamed or moved. `nil` when one could not be made.
    public var bookmark: Data?
    public var origin: ShelfOrigin
    public var addedAt: Date
    /// Size in bytes; `nil` for folders and packages.
    public var size: Int64?

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, origin: ShelfOrigin, addedAt: Date, size: Int64? = nil) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.origin = origin; self.addedAt = addedAt; self.size = size
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }

    /// The key used for de-duplication: symlinks resolved, `.`/`..` removed.
    public var dedupeKey: String { Self.dedupeKey(for: url) }

    public static func dedupeKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The ordered list, newest first. A pure value type so the rules are testable without a module.
public struct ShelfList: Sendable, Equatable {
    public static let defaultCapacity = 50

    public private(set) var items: [ShelfItem]
    public let capacity: Int

    public init(_ items: [ShelfItem] = [], capacity: Int = ShelfList.defaultCapacity) {
        self.capacity = capacity
        self.items = Self.normalized(items, capacity: capacity)
    }

    /// Puts `newItems` at the front in the order given. An item already on the shelf (same resolved path)
    /// moves to the front instead of appearing twice. The oldest items fall off past `capacity`.
    public mutating func add(_ newItems: [ShelfItem]) {
        items = Self.normalized(newItems + items, capacity: capacity)
    }

    @discardableResult
    public mutating func remove(id: ShelfItem.ID) -> ShelfItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func removeAll() { items.removeAll() }

    /// Replaces the list wholesale (after resolving references), keeping the invariants.
    public mutating func replace(with newItems: [ShelfItem]) {
        items = Self.normalized(newItems, capacity: capacity)
    }

    /// First occurrence of each resolved path wins; then cap.
    static func normalized(_ list: [ShelfItem], capacity: Int) -> [ShelfItem] {
        var seen = Set<String>()
        var out: [ShelfItem] = []
        out.reserveCapacity(min(list.count, capacity))
        for item in list where seen.insert(item.dedupeKey).inserted {
            out.append(item)
            if out.count == capacity { break }
        }
        return out
    }
}

/// Filesystem side of the shelf: making references, resolving them, and the JSON file. Reads metadata only;
/// the only file it ever writes is its own JSON store.
public enum ShelfFiles {
    /// Builds an item for a file that is about to be shelved.
    public static func makeItem(for url: URL, origin: ShelfOrigin, now: Date) -> ShelfItem {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ShelfItem(path: fileURL.path, bookmark: bookmark, origin: origin, addedAt: now, size: size(of: fileURL))
    }

    /// Follows each bookmark to the file's current location and refreshes its size. Items whose file is gone
    /// (or sits in the Trash) are dropped. Never mounts volumes or shows UI.
    public static func resolve(_ items: [ShelfItem]) -> [ShelfItem] {
        let fileManager = FileManager.default
        return items.compactMap { item in
            var item = item
            if let bookmark = item.bookmark {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    item.path = url.standardizedFileURL.path
                    if stale {
                        item.bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark
                    }
                }
            }
            guard fileManager.fileExists(atPath: item.path), !isInTrash(item.path) else { return nil }
            item.size = size(of: item.url)
            return item
        }
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// `<appSupport>/Shelf/items.json`.
    public static func storeURL(in directories: AppDirectories) -> URL {
        directories.appSupport.appending(path: "Shelf", directoryHint: .isDirectory).appending(path: "items.json")
    }

    private struct Envelope: Codable {
        var version = 1
        var items: [ShelfItem]
    }

    public static func load(from url: URL) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.items ?? []
    }

    public static func save(_ items: [ShelfItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(items: items))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// What a shelf item is, for its card's label and symbol. Converted outputs are marked as such.
public struct ShelfItemKind: Sendable, Equatable {
    public let label: String
    public let symbol: String
    /// Whether the thumbnail is a picture that may fill the card (photos, video frames) rather than a page or icon.
    public let fillsPreview: Bool

    public init(label: String, symbol: String, fillsPreview: Bool = false) {
        self.label = label; self.symbol = symbol; self.fillsPreview = fillsPreview
    }

    public static func of(_ item: ShelfItem) -> ShelfItemKind {
        if item.origin == .converted { return ShelfItemKind(label: "Converted", symbol: "sparkles", fillsPreview: true) }
        if item.size == nil { return ShelfItemKind(label: "Folder", symbol: "folder") }
        guard let type = UTType(filenameExtension: item.url.pathExtension.lowercased()) else {
            return ShelfItemKind(label: "Document", symbol: "doc")
        }
        if type.conforms(to: .image) { return ShelfItemKind(label: "Image", symbol: "photo", fillsPreview: true) }
        if type.conforms(to: .movie) { return ShelfItemKind(label: "Movie", symbol: "film", fillsPreview: true) }
        if type.conforms(to: .audio) { return ShelfItemKind(label: "Audio", symbol: "waveform") }
        if type.conforms(to: .pdf) { return ShelfItemKind(label: "PDF", symbol: "doc.richtext") }
        if type.conforms(to: .archive) { return ShelfItemKind(label: "Archive", symbol: "doc.zipper") }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) { return ShelfItemKind(label: "Code", symbol: "curlybraces") }
        if type.conforms(to: .presentation) { return ShelfItemKind(label: "Presentation", symbol: "rectangle.on.rectangle") }
        if type.conforms(to: .text) { return ShelfItemKind(label: "Text", symbol: "doc.text") }
        return ShelfItemKind(label: "Document", symbol: "doc")
    }
}

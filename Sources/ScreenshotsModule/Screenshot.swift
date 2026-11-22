import Foundation

/// Width and height in pixels.
public struct PixelSize: Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }

    /// "2940 × 1912".
    public var text: String { "\(width) \u{00D7} \(height)" }
}

/// One screenshot file, described by its attributes.
public struct Screenshot: Sendable, Equatable, Hashable, Identifiable {
    public var url: URL
    /// When the screenshot was taken (the file's creation date).
    public var createdAt: Date
    /// Changes when the file is edited (Markup): part of the thumbnail cache key.
    public var modifiedAt: Date?
    public var pixelSize: PixelSize?
    /// Size in bytes, if known.
    public var bytes: Int64?

    public init(url: URL, createdAt: Date, modifiedAt: Date? = nil, pixelSize: PixelSize? = nil, bytes: Int64? = nil) {
        self.url = url; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.pixelSize = pixelSize; self.bytes = bytes
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The key used for de-duplication: `.`/`..` removed. Symlinks are not resolved: that would touch the disk.
    public var dedupeKey: String { url.standardizedFileURL.path }
}

/// The screenshots on the page: newest first, recent only, one entry per file, capped. A pure value type so the
/// rules are testable without a folder. Rebuilt from the source's results; never persisted.
public struct ScreenshotList: Sendable, Equatable {
    public static let defaultCapacity = 12
    /// Only screenshots taken this recently are listed.
    public static let window: TimeInterval = 24 * 3600

    public private(set) var items: [Screenshot] = []
    public let capacity: Int

    public init(capacity: Int = ScreenshotList.defaultCapacity) { self.capacity = max(0, capacity) }

    public init(_ screenshots: [Screenshot], now: Date, capacity: Int = ScreenshotList.defaultCapacity) {
        self.init(capacity: capacity)
        replace(with: screenshots, now: now)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Replaces the list with everything the source currently knows, keeping the rules.
    public mutating func replace(with screenshots: [Screenshot], now: Date) {
        items = Self.normalized(screenshots, now: now, capacity: capacity)
    }

    /// Re-applies the time window, for a list that has been sitting while the clock moved on.
    public mutating func prune(now: Date) {
        items = Self.normalized(items, now: now, capacity: capacity)
    }

    /// Forgets one file (it has gone). The file itself is never touched.
    public mutating func remove(_ url: URL) {
        let key = url.standardizedFileURL.path
        items.removeAll { $0.dedupeKey == key }
    }

    public mutating func removeAll() { items.removeAll() }

    public func contains(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return items.contains { $0.dedupeKey == key }
    }

    /// Inside the window, not in the Trash, newest first (ties by path, for a stable order), first entry per file, capped.
    static func normalized(_ list: [Screenshot], now: Date, capacity: Int) -> [Screenshot] {
        let oldest = now.addingTimeInterval(-window)
        let sorted = list
            .filter { $0.createdAt >= oldest && !isInTrash($0.dedupeKey) }
            .sorted { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.dedupeKey < b.dedupeKey }
        var seen = Set<String>()
        var out: [Screenshot] = []
        out.reserveCapacity(min(sorted.count, capacity))
        for shot in sorted where out.count < capacity && seen.insert(shot.dedupeKey).inserted {
            out.append(shot)
        }
        return out
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}

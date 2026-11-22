import Foundation
import UniformTypeIdentifiers

/// Width and height in pixels, as Spotlight reports them.
public struct PixelSize: Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }

    /// "2940 × 1912".
    public var text: String { "\(width) \u{00D7} \(height)" }
}

/// One screenshot file, described from its Spotlight attributes. Building one never opens the file.
public struct Screenshot: Sendable, Equatable, Hashable, Identifiable {
    public var url: URL
    /// When the screenshot was taken (Spotlight's content creation date, else the file's creation date).
    public var createdAt: Date
    /// Changes when the file is edited (Markup): part of the thumbnail cache key.
    public var modifiedAt: Date?
    public var pixelSize: PixelSize?
    /// Size in bytes, if Spotlight knows it.
    public var bytes: Int64?

    public init(url: URL, createdAt: Date, modifiedAt: Date? = nil, pixelSize: PixelSize? = nil, bytes: Int64? = nil) {
        self.url = url; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.pixelSize = pixelSize; self.bytes = bytes
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The key used for de-duplication: `.`/`..` removed. Symlinks are not resolved: that would touch the disk.
    public var dedupeKey: String { url.standardizedFileURL.path }

    /// A screenshot from raw Spotlight attributes, or `nil` when the item is not a still image (screen recordings
    /// carry the same screen-capture flag) or has no path or date.
    /// - Parameter contentType: `kMDItemContentType`, a uniform type identifier.
    public static func fromSpotlight(
        path: String?, contentType: String?, contentCreated: Date?, fileCreated: Date?, modified: Date?,
        pixelWidth: Int?, pixelHeight: Int?, bytes: Int64?
    ) -> Screenshot? {
        guard let path, !path.isEmpty, let created = contentCreated ?? fileCreated else { return nil }
        guard let identifier = contentType, let type = UTType(identifier), type.conforms(to: .image) else { return nil }
        let size: PixelSize? = if let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 { PixelSize(width: w, height: h) } else { nil }
        return Screenshot(url: URL(fileURLWithPath: path), createdAt: created, modifiedAt: modified, pixelSize: size, bytes: bytes)
    }
}

/// The screenshots on the page: newest first, recent only, one entry per file, capped. A pure value type so the
/// rules are testable without Spotlight. Rebuilt from the source's results; never persisted.
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

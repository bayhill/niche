import CoreGraphics
import Darwin
import Foundation
import ImageIO
import NotchCore

/// What reading a screenshot for its thumbnail found.
public enum ThumbnailResult: Sendable, Equatable {
    case image(SendableImage)
    /// The file is there but could not be read (macOS denied access to its folder) or decoded.
    case unreadable
    /// The file has gone.
    case missing

    public var image: SendableImage? { if case .image(let image) = self { image } else { nil } }
}

/// Makes the picture for a tile and the live activity. Injected so tests and fixtures never decode real files.
public protocol ScreenshotThumbnailing: Sendable {
    /// A downsampled thumbnail whose longer side is at most `maxPixelSize` pixels. Runs off the main actor.
    func thumbnail(for url: URL, maxPixelSize: Int) async -> ThumbnailResult
}

/// ImageIO thumbnails, decoded on a background task. Opening the file is the only operation in this module that
/// reads a screenshot, so it is the one that can raise the macOS folder-access prompt.
public struct ImageIOThumbnails: ScreenshotThumbnailing {
    public init() {}

    public func thumbnail(for url: URL, maxPixelSize: Int) async -> ThumbnailResult {
        await Task.detached(priority: .utility) { Self.make(url, maxPixelSize: maxPixelSize) }.value
    }

    static func make(_ url: URL, maxPixelSize: Int) -> ThumbnailResult {
        // `open` tells a missing file (ENOENT) apart from one macOS will not let us read (EPERM, EACCES).
        let descriptor = open(url.path, O_RDONLY)
        if descriptor < 0 {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .missing : .unreadable
        }
        close(descriptor)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return .unreadable }
        return .image(SendableImage(image))
    }
}

/// Pictures prepared in advance, keyed by path. For fixtures: reads nothing.
struct PreparedThumbnails: ScreenshotThumbnailing {
    let images: [String: SendableImage]
    func thumbnail(for url: URL, maxPixelSize: Int) async -> ThumbnailResult {
        images[url.path].map(ThumbnailResult.image) ?? .unreadable
    }
}

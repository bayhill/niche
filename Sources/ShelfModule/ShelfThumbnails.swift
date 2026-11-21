import CoreGraphics
import Foundation
import NotchCore
import QuickLookThumbnailing

/// Makes the picture for a shelf tile. Injected so tests and fixtures never touch QuickLook or the disk.
public protocol ShelfThumbnailing: Sendable {
    /// A thumbnail (or the file's icon) no larger than `side` points at `scale`, or `nil`.
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> SendableImage?
}

/// QuickLook thumbnails, falling back to the file's icon.
public struct QuickLookThumbnails: ShelfThumbnailing {
    public init() {}

    public func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> SendableImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation.map { SendableImage($0.cgImage) })
            }
        }
    }
}

/// Returns nothing; tiles show a symbol instead.
public struct NoThumbnails: ShelfThumbnailing {
    public init() {}
    public func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> SendableImage? { nil }
}

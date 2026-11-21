import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded source image, upright and scaled, still in its own colour space.
public struct DecodedImage: Sendable {
    public let image: CGImage
    /// Pixel size of the source after orientation, before scaling.
    public let originalPixelSize: PixelSize
    /// Uniform type identifier ImageIO detected from the content.
    public let typeIdentifier: String
    public let frameCount: Int
    /// Raw Exif (TIFF-structured, no "Exif\0\0" prefix) with orientation reset to 1. Only when requested.
    public let exif: Data?
    public let notes: [String]

    public var pixelSize: PixelSize { PixelSize(width: image.width, height: image.height) }
}

public enum ImageDecoder {
    /// WebP's hard limit for either dimension.
    public static let webPMaxEdge = 16383
    /// Sources above this many pixels are refused with `.tooLarge`.
    public static let maxSourcePixels = 1_000_000_000

    /// Types ImageIO can decode on this system.
    public static let decodableTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    /// Whether a file of this type can be converted (an image ImageIO reads, and not already WebP).
    public static func canConvert(_ type: UTType) -> Bool {
        guard type.conforms(to: .image), !type.conforms(to: .webP) else { return false }
        if decodableTypes.contains(type.identifier) { return true }
        return decodableTypes.contains { UTType($0).map { type.conforms(to: $0) } ?? false }
    }

    /// Decodes the first frame with EXIF orientation applied and the longer edge capped at
    /// `min(maxPixelEdge, webPMaxEdge)`.
    public static func load(_ source: ImageSource, maxPixelEdge: Int?, includeMetadata: Bool = false) throws(ConversionError) -> DecodedImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let bytes: Data
        var extensionType: UTType?
        switch source {
        case .file(let url):
            extensionType = UTType(filenameExtension: url.pathExtension.lowercased())
            // Never read a cloud placeholder: reading would block on a download, or decode a stub.
            if let problem = FileAvailability.problem(at: url) { throw problem }
            guard let mapped = try? Data(contentsOf: url, options: .alwaysMapped) else { throw .decodeFailed }
            bytes = mapped
        case .data(let data, _):
            bytes = data
        }
        guard !bytes.isEmpty else { throw .incomplete }

        guard let src = CGImageSourceCreateWithData(bytes as CFData, options), let type = CGImageSourceGetType(src) as String? else {
            if let t = extensionType, !t.conforms(to: .image) { throw .unsupported }
            throw .decodeFailed
        }
        if UTType(type)?.conforms(to: .webP) == true { throw .alreadyWebP }
        if let t = UTType(type), !t.conforms(to: .image) { throw .unsupported }
        // ImageIO reports most cut-off files as complete and decodes the missing part as blank, so the
        // container structure is checked as well.
        guard CGImageSourceGetStatus(src) == .statusComplete, CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              ImageCompleteness.isComplete(bytes, type: UTType(type))
        else { throw .incomplete }
        let frameCount = CGImageSourceGetCount(src)
        guard frameCount > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { throw .decodeFailed }
        guard width.multipliedReportingOverflow(by: height).partialValue <= maxSourcePixels else { throw .tooLarge }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let original = rotated ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)

        let requested = maxPixelEdge.map { max(1, $0) }
        let limit = min(requested ?? Int.max, webPMaxEdge)
        let needsScale = original.longEdge > limit

        var notes: [String] = []
        if frameCount > 1 { notes.append("Animated: converted the first frame only") }
        if needsScale, (requested ?? Int.max) > webPMaxEdge {
            notes.append("Scaled to fit WebP\u{2019}s \(webPMaxEdge) px limit")
        }

        let image: CGImage?
        if needsScale || orientation != 1 {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: needsScale ? limit : original.longEdge,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
        } else {
            // Not cached: the pixels decode straight into the encoder's raster when it draws the image.
            image = CGImageSourceCreateImageAtIndex(src, 0, options)
        }
        guard let image, image.width > 0, image.height > 0 else { throw .decodeFailed }

        let exif = includeMetadata ? exifPayload(from: props, size: PixelSize(width: image.width, height: image.height)) : nil
        return DecodedImage(image: image, originalPixelSize: original, typeIdentifier: type, frameCount: frameCount, exif: exif, notes: notes)
    }

    /// Source and output pixel counts from the header alone (no decode), for memory admission.
    /// `nil` when the header cannot be read; the conversion will report why.
    public static func estimatePixels(_ source: ImageSource, maxPixelEdge: Int?) -> (source: Int, output: Int)? {
        let src: CGImageSource?
        switch source {
        case .file(let url):
            guard FileAvailability.problem(at: url) == nil else { return nil }
            src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .data(let data, _):
            src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let src, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0
        else { return nil }
        let limit = Double(min(maxPixelEdge.map { max(1, $0) } ?? Int.max, webPMaxEdge))
        let scale = min(1, limit / Double(max(w, h)))
        let full = w.multipliedReportingOverflow(by: h).partialValue
        return (full, Int(Double(w) * scale * Double(h) * scale))
    }

    /// A small upright preview for UI rows. Decodes WebP too.
    public static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Builds a raw Exif block from ImageIO's property dictionaries by letting ImageIO serialise them into a
    /// throwaway in-memory JPEG and lifting its APP1 segment. Orientation is reset (the pixels are already upright)
    /// and pixel dimensions are updated.
    static func exifPayload(from props: [CFString: Any], size: PixelSize) -> Data? {
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        guard exif != nil || tiff != nil || gps != nil else { return nil }
        exif?[kCGImagePropertyExifPixelXDimension] = size.width
        exif?[kCGImagePropertyExifPixelYDimension] = size.height
        tiff?[kCGImagePropertyTIFFOrientation] = 1

        var meta: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let exif { meta[kCGImagePropertyExifDictionary] = exif }
        if let tiff { meta[kCGImagePropertyTIFFDictionary] = tiff }
        if let gps { meta[kCGImagePropertyGPSDictionary] = gps }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixel = ctx.makeImage()
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, pixel, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return app1Exif(inJPEG: out as Data)
    }

    /// The payload of the first `APP1 "Exif\0\0"` segment of a JPEG, without the signature.
    static func app1Exif(inJPEG jpeg: Data) -> Data? {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }  // start of scan / end of image
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let start = i + 4, end = i + 2 + length
            guard length >= 2, end <= b.count else { return nil }
            if marker == 0xE1, end - start > 6, b[start..<start + 6].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                return Data(b[(start + 6)..<end])
            }
            i = end
        }
        return nil
    }
}

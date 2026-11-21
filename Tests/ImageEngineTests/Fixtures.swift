import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ImageEngine

/// A fresh temporary folder per test, with helpers to make and inspect images using ImageIO only.
final class Fixture: Sendable {
    let dir: URL
    let fallback: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "imageengine-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fallback = dir.appending(path: "Fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func url(_ name: String) -> URL { dir.appending(path: name, directoryHint: .notDirectory) }

    func job(_ name: String) -> ConversionJob { ConversionJob(source: .file(url(name)), fallbackDirectory: fallback) }
}

enum Img {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws with a closure into a fresh context.
    static func make(
        width: Int, height: Int, space: CGColorSpace = sRGB, bits: Int = 8, alpha: CGImageAlphaInfo = .premultipliedLast,
        draw: (CGContext) -> Void
    ) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static func solid(width: Int = 16, height: Int = 16, space: CGColorSpace = sRGB, bits: Int = 8, alpha: CGImageAlphaInfo = .premultipliedLast, _ components: [CGFloat]) -> CGImage {
        make(width: width, height: height, space: space, bits: bits, alpha: alpha) { ctx in
            ctx.setFillColor(CGColor(colorSpace: space, components: components)!)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Opaque image whose every pixel differs, from an explicit buffer (so the bytes are known exactly).
    static func pattern(width: Int, height: Int, seed: UInt64 = 1, noise: Bool = false) -> (CGImage, [UInt8]) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var rng = seed
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if noise {
                    for c in 0..<3 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; bytes[i + c] = UInt8(truncatingIfNeeded: rng >> 56) }
                } else {
                    bytes[i] = UInt8(truncatingIfNeeded: x * 7); bytes[i + 1] = UInt8(truncatingIfNeeded: y * 5); bytes[i + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 3)
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return (image, bytes)
    }

    static func encode(_ images: [CGImage], type: UTType, properties: [CFString: Any]? = nil, frameProperties: [CFString: Any]? = nil) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, images.count, nil)!
        if let properties { CGImageDestinationSetProperties(dest, properties as CFDictionary) }
        for image in images { CGImageDestinationAddImage(dest, image, frameProperties as CFDictionary?) }
        precondition(CGImageDestinationFinalize(dest), "ImageIO could not write \(type)")
        return out as Data
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .png, properties: [CFString: Any]? = nil) throws -> URL {
        try encode([image], type: type, frameProperties: properties).write(to: url)
        return url
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func decode(_ url: URL) -> CGImage? { (try? Data(contentsOf: url)).flatMap(decode) }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// 8-bit sRGB RGBA with straight alpha.
    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = Int(buf[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { buf[i + c] = UInt8(min(255, (Int(buf[i + c]) * 255 + a / 2) / a)) }
        }
        return buf
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let buf = rgba(image)
        let i = (y * image.width + x) * 4
        return (0..<4).map { Int(buf[i + $0]) }
    }

    /// Top-level RIFF chunk FourCCs of a WebP file.
    static func chunks(_ data: Data) -> [String] {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WEBP" else { return [] }
        var out: [String] = []
        var i = 12
        while i + 8 <= b.count {
            out.append(String(bytes: b[i..<i + 4], encoding: .ascii) ?? "?")
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            i += 8 + size + (size & 1)
        }
        return out
    }
}

func near(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

/// Collects every event of a submission.
func run(_ queue: ConversionQueue, _ jobs: [ConversionJob], _ options: EncodeOptions = .init()) async -> [ConversionEvent] {
    var events: [ConversionEvent] = []
    for await e in queue.submit(jobs, options: options) { events.append(e) }
    return events
}

extension Array where Element == ConversionEvent {
    var results: [ConversionResult] { compactMap { if case .succeeded(_, let r) = $0 { r } else { nil } } }
    var failures: [ConversionError] { compactMap { if case .failed(_, let e) = $0 { e } else { nil } } }
}

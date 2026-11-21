import CoreGraphics
import Foundation
import NotchCore

/// Fixture data for `ShelfModule.sample()`: made-up paths and generated pictures. Nothing here reads the disk.
enum ShelfSamples {
    private struct Sample {
        let name: String
        let size: Int64?
        let origin: ShelfOrigin
        /// Picture: (width, height, hue) or `nil` for a symbol tile.
        let picture: (Int, Int, Double)?
    }

    private static let samples: [Sample] = [
        Sample(name: "hero-banner.webp", size: 264_000, origin: .converted, picture: (320, 180, 0.58)),
        Sample(name: "Quarterly Report 2026 Q3 final.pdf", size: 1_840_000, origin: .dropped, picture: (150, 200, 0.0)),
        Sample(name: "team-offsite.webp", size: 190_000, origin: .converted, picture: (240, 240, 0.08)),
        Sample(name: "design-tokens.json", size: 4_200, origin: .dropped, picture: nil),
        Sample(name: "Screenshot 2026-11-21 at 09.41.12.png", size: 2_300_000, origin: .dropped, picture: (320, 200, 0.75)),
        Sample(name: "Assets", size: nil, origin: .dropped, picture: nil),
        Sample(name: "launch-keynote.mov", size: 48_500_000, origin: .dropped, picture: (320, 180, 0.38)),
    ]

    private static let minutesAgo: [Double] = [0.3, 6, 22, 41, 75, 140, 300]

    static func make(now: Date = Date()) -> ([ShelfItem], [String: SendableImage]) {
        var items: [ShelfItem] = []
        var thumbnails: [String: SendableImage] = [:]
        for (index, sample) in samples.enumerated() {
            let item = ShelfItem(
                path: "/Users/Shared/Notcher Samples/\(sample.name)", origin: sample.origin,
                addedAt: now.addingTimeInterval(-minutesAgo[index % minutesAgo.count] * 60), size: sample.size
            )
            items.append(item)
            if let (w, h, hue) = sample.picture, let image = gradient(width: w, height: h, hue: hue, page: sample.name.hasSuffix(".pdf")) {
                thumbnails["\(item.path)|\(item.size ?? -1)"] = SendableImage(image)
            }
        }
        return (items, thumbnails)
    }

    /// A soft two-stop gradient "photo", or a white page with grey lines for documents.
    private static func gradient(width: Int, height: Int, hue: Double, page: Bool) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if page {
            ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
            for line in 0..<9 {
                let y = height - 30 - line * 17
                ctx.fill(CGRect(x: 16, y: y, width: line % 3 == 2 ? width / 2 : width - 32, height: 6))
            }
            return ctx.makeImage()
        }
        let top = hsb(hue, 0.55, 0.95), bottom = hsb(hue + 0.08, 0.75, 0.45)
        guard let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        ctx.fillEllipse(in: CGRect(x: width / 2, y: height / 3, width: width / 3, height: width / 3))
        return ctx.makeImage()
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
        let h6 = (h.truncatingRemainder(dividingBy: 1)) * 6
        let c = b * s, x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let (r, g, bl): (Double, Double, Double) = switch Int(h6) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: bl + m, alpha: 1)
    }
}

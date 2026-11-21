import CoreGraphics
import Foundation
import ImageIO
import NotchCore
import UniformTypeIdentifiers

/// Fixture entries for `ClipboardModule.sample()`. Generated in memory; nothing is read from the system.
enum ClipboardSamples {
    static func make(now: Date) -> ([ClipboardEntry], [ClipboardEntry.ID: SendableImage]) {
        var entries: [ClipboardEntry] = []
        var thumbnails: [ClipboardEntry.ID: SendableImage] = [:]

        func text(_ s: String, from app: String, minutesAgo: Double) {
            entries.append(ClipboardEntry(content: .text(s), copiedAt: now.addingTimeInterval(-minutesAgo * 60), sourceApp: app))
        }
        func image(width: Int, height: Int, hue: Double, from app: String, minutesAgo: Double) {
            guard let cg = picture(width: width, height: height, hue: hue), let data = png(cg) else { return }
            let entry = ClipboardEntry(
                content: .image(data, type: "public.png"), copiedAt: now.addingTimeInterval(-minutesAgo * 60), sourceApp: app
            )
            entries.append(entry)
            thumbnails[entry.id] = ClipboardImages.thumbnail(of: data, maxPixels: 360)
        }

        text(
            "Keep the top cap pure black so the panel reads as part of the hardware, then let the glass take over.",
            from: "Notes", minutesAgo: 0.2
        )
        text("https://developer.apple.com/documentation/swiftui/glass", from: "Safari", minutesAgo: 4)
        image(width: 1600, height: 900, hue: 0.58, from: "Preview", minutesAgo: 18)
        text("#409EFF", from: "Sketchbook", minutesAgo: 64)
        text("swift build -c release && scripts/bundle.sh && scripts/run.sh --force-state expanded", from: "Terminal", minutesAgo: 95)
        image(width: 1080, height: 1080, hue: 0.92, from: "Photos", minutesAgo: 130)
        text("rgb(48, 217, 122)", from: "Figma", minutesAgo: 200)
        return (entries, thumbnails)
    }

    private static func picture(width: Int, height: Int, hue: Double) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [color(hue, 0.5, 0.95), color(hue + 0.1, 0.8, 0.4)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
        let d = Double(min(width, height)) * 0.45
        ctx.fillEllipse(in: CGRect(x: Double(width) * 0.55, y: Double(height) * 0.3, width: d, height: d))
        return ctx.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func color(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
        let h6 = h.truncatingRemainder(dividingBy: 1) * 6
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

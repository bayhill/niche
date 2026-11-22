import CoreGraphics
import Foundation
import NotchCore

/// Fixture data for `ScreenshotsModule.sample()`: invented paths and generated pictures. Nothing here reads the disk.
enum ScreenshotSamples {
    private struct Sample {
        let minutesAgo: Double
        let width: Int
        let height: Int
        let bytes: Int64
        let hue: Double
        /// A window with a sidebar, rather than a plain page.
        let sidebar: Bool
    }

    private static let samples: [Sample] = [
        Sample(minutesAgo: 0.4, width: 1640, height: 1080, bytes: 412_000, hue: 0.58, sidebar: true),
        Sample(minutesAgo: 7, width: 820, height: 512, bytes: 96_000, hue: 0.08, sidebar: false),
        Sample(minutesAgo: 26, width: 3600, height: 2338, bytes: 2_740_000, hue: 0.75, sidebar: true),
        Sample(minutesAgo: 95, width: 1200, height: 760, bytes: 238_000, hue: 0.38, sidebar: false),
        Sample(minutesAgo: 310, width: 2400, height: 1560, bytes: 1_180_000, hue: 0.0, sidebar: true),
    ]

    static let folder = "/Users/Shared/Notcher Samples"

    static func make(now: Date) -> ([Screenshot], [String: SendableImage]) {
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        names.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var screenshots: [Screenshot] = []
        var thumbnails: [String: SendableImage] = [:]
        for sample in samples {
            let taken = now.addingTimeInterval(-sample.minutesAgo * 60)
            let url = URL(fileURLWithPath: "\(folder)/Screenshot \(names.string(from: taken)).png")
            screenshots.append(Screenshot(
                url: url, createdAt: taken, modifiedAt: taken,
                pixelSize: PixelSize(width: sample.width, height: sample.height), bytes: sample.bytes
            ))
            if let image = picture(sample) { thumbnails[url.path] = SendableImage(image) }
        }
        return (screenshots, thumbnails)
    }

    /// A made-up app window at thumbnail size: a coloured backdrop, a title bar, a sidebar and lines of "text".
    private static func picture(_ sample: Sample) -> CGImage? {
        let scale = Double(ScreenshotsModule.thumbnailPixels) / Double(max(sample.width, sample.height))
        let width = max(1, Int(Double(sample.width) * scale)), height = max(1, Int(Double(sample.height) * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let top = hsb(sample.hue, 0.45, 0.85), bottom = hsb(sample.hue + 0.1, 0.7, 0.4)
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        let window = CGRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.84)
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        let bar = CGRect(x: window.minX, y: window.maxY - 14, width: window.width, height: 14)
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        ctx.fill(bar)
        // The three window buttons.
        for (index, rgb) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: bar.minX + 6 + CGFloat(index) * 9, y: bar.minY + 4, width: 6, height: 6))
        }
        var content = CGRect(x: window.minX + 10, y: window.minY + 10, width: window.width - 20, height: bar.minY - window.minY - 20)
        if sample.sidebar {
            let sidebar = window.width * 0.24
            ctx.setFillColor(CGColor(gray: 0.91, alpha: 1))
            ctx.fill(CGRect(x: window.minX, y: window.minY, width: sidebar, height: bar.minY - window.minY))
            content.origin.x += sidebar
            content.size.width -= sidebar
        }
        ctx.setFillColor(hsb(sample.hue, 0.55, 0.85))
        ctx.fill(CGRect(x: content.minX, y: content.maxY - 10, width: content.width * 0.5, height: 7))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        var y = content.maxY - 24
        var line = 0
        while y > content.minY {
            ctx.fill(CGRect(x: content.minX, y: y, width: content.width * (line % 4 == 3 ? 0.55 : 0.92), height: 4))
            y -= 10
            line += 1
        }
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

import AppKit
import NotchCore
import SwiftUI

/// Picks one colour from the screen. The app uses `SystemColourSampler`; tests and fixtures use their own.
@MainActor
public protocol ColourSampling: AnyObject {
    /// Shows the picker and waits. `nil` when the user cancelled (Escape) or the colour could not be read.
    func sample() async -> Colour?
}

/// The system magnifier, `NSColorSampler`. It needs no permission: macOS draws the loupe itself and hands back
/// only the one colour the user clicked.
///
/// The sampler hands back an `NSColor` in whatever colour space the system chose for the display it was picked
/// from (a display's own profile, not necessarily sRGB). Rather than read raw components from an unknown space,
/// the colour is converted by ColorSync to extended sRGB (`Colour(sampled:)`), which is unbounded: a pixel outside
/// the sRGB gamut on a P3 display keeps components below 0 or above 1 instead of being clipped.
@MainActor
public final class SystemColourSampler: ColourSampling {
    /// Kept for as long as the loupe is up; `NSColorSampler` must outlive its `show` call.
    private var active: NSColorSampler?

    public init() {}

    public func sample() async -> Colour? {
        guard active == nil else { return nil }
        let sampler = NSColorSampler()
        active = sampler
        defer { active = nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Colour?, Never>) in
            sampler.show { picked in
                continuation.resume(returning: picked.flatMap(Colour.init(sampled:)))
            }
        }
    }
}

public extension Colour {
    /// Converts any `NSColor` with RGB-compatible components into this type through ColorSync, unclamped.
    /// `nil` for colours with no such conversion (pattern or catalogue colours) or non-finite components.
    init?(sampled colour: NSColor) {
        guard let srgb = colour.usingColorSpace(.extendedSRGB) else { return nil }
        let value = Colour(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
        guard value.isFinite else { return nil }
        self = value
    }
}

extension Colour {
    /// The colour for drawing a swatch: Display P3 components, so a pick outside sRGB keeps its saturation on a
    /// P3 display. An sRGB pick draws the same either way. This and the "Aa" preview are the only places module
    /// code fills with a colour that is not a token: the colour is the content.
    var swatchColor: Color {
        let p3 = displayP3
        return Color(.displayP3, red: p3[0], green: p3[1], blue: p3[2])
    }
}

/// A small solid square of the pick for the live-activity wing (`ActivityGlyph.image`).
enum SwatchImage {
    /// 20 pt at 2x: the size the wing draws an image glyph.
    static let pixels = 40

    /// Drawn into a Display P3 bitmap so a wide-gamut pick survives, edged with `Tokens.Colors.hairline` so a black
    /// pick still shows against the black notch.
    static func make(_ colour: Colour) -> SendableImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let extended = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let fill = CGColor(colorSpace: extended, components: [colour.red, colour.green, colour.blue, 1]),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.setFillColor(fill)
        context.fill(rect)
        let radius = Tokens.Radius.thumbnail * 2
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(NSColor(Tokens.Colors.hairline).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        return context.makeImage().map(SendableImage.init)
    }
}

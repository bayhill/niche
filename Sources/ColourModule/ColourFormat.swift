import Foundation

/// The ways a colour can be copied. Stored in the setting `colour.format`.
public enum ColourFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `#RRGGBB`, uppercase, clamped to sRGB.
    case hex
    /// `rgb(r g b)` with 0–255 integers, clamped to sRGB (CSS Color 4 space-separated syntax).
    case rgb
    /// `oklch(L C h)`: L a percentage with one decimal, C three decimals, h degrees with one decimal.
    case oklch
    /// `color(display-p3 r g b)` with three decimals, unclamped.
    case displayP3

    public var id: String { rawValue }

    /// Name on the format choice.
    public var label: String {
        switch self {
        case .hex: "Hex"
        case .rgb: "RGB"
        case .oklch: "OKLCH"
        case .displayP3: "Display P3"
        }
    }

    /// Whether the format can only express sRGB, so a wider colour is clamped.
    public var clampsToSRGB: Bool { self == .hex || self == .rgb }
}

/// A colour written in one format.
public struct FormattedColour: Sendable, Equatable {
    /// The full CSS text, exactly what is copied.
    public var text: String
    /// The numbers alone, for a swatch too narrow for `text`: "0.917 0.200 0.139". Equal to `text` for hex.
    public var compact: String
    /// True when the format could not hold the colour and clamping changed it (hex or `rgb()` of a colour
    /// outside sRGB).
    public var clamped: Bool
}

public extension Colour {
    func formatted(_ format: ColourFormat) -> FormattedColour {
        switch format {
        case .hex:
            return FormattedColour(text: hex, compact: hex, clamped: !isInSRGBGamut)
        case .rgb:
            let c = rgb8
            let numbers = "\(c.red) \(c.green) \(c.blue)"
            return FormattedColour(text: "rgb(\(numbers))", compact: numbers, clamped: !isInSRGBGamut)
        case .oklch:
            let c = oklch
            let chroma = c.chroma < Self.achromaticChroma ? 0 : c.chroma
            var hue = chroma == 0 ? 0 : ColourText.round(c.hue, places: 1)
            if hue >= 360 { hue = 0 }  // 359.96 is written 0.0, not 360.0
            let numbers = "\(ColourText.fixed(c.lightness * 100, places: 1))% \(ColourText.fixed(chroma, places: 3)) "
                + ColourText.fixed(hue, places: 1)
            return FormattedColour(text: "oklch(\(numbers))", compact: numbers, clamped: false)
        case .displayP3:
            let numbers = displayP3.map { ColourText.fixed($0, places: 3) }.joined(separator: " ")
            return FormattedColour(text: "color(display-p3 \(numbers))", compact: numbers, clamped: false)
        }
    }

    /// `#RRGGBB`, uppercase, clamped to sRGB.
    var hex: String {
        let c = rgb8
        return String(format: "#%02X%02X%02X", c.red, c.green, c.blue)
    }

    /// Two colours are the same pick when no format can tell them apart: every format writes them identically.
    func readsSame(as other: Colour) -> Bool {
        ColourFormat.allCases.allSatisfy { formatted($0).text == other.formatted($0).text }
    }
}

enum ColourText {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Rounded to `places` decimals, half away from zero, with negative zero written as zero.
    static func fixed(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: posix, round(value, places: places))
    }

    static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        return rounded == 0 ? 0 : rounded  // drops the sign of -0.0
    }
}

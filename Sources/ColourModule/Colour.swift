import Foundation

/// One picked colour, as gamma-encoded sRGB components that are not clamped.
///
/// The components are sRGB as CSS Color 4 and `NSColorSpace.extendedSRGB` define it: the IEC 61966-2-1 transfer
/// function, mirrored through zero for negative values, D65 white. A Display P3 colour outside the sRGB gamut is
/// still exact here, with some component below 0 or above 1. Every other form (hex, OKLCH, Display P3) is
/// derived from these three numbers, so the stored value is the single source of truth.
public struct Colour: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// From 8-bit sRGB values, e.g. `Colour(rgb8: 0x77, 0x77, 0x77)`.
    public init(rgb8 red: Int, _ green: Int, _ blue: Int) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// From `#RRGGBB` (the `#` is optional). `nil` for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        self.init(rgb8: (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// From gamma-encoded Display P3 components (the sRGB transfer function, P3 primaries, D65 white).
    public init(displayP3 red: Double, _ green: Double, _ blue: Double) {
        let linear = ColourMath.p3LinearToXYZ.then(ColourMath.xyzToSRGBLinear).apply(ColourMath.decode([red, green, blue]))
        let encoded = ColourMath.encode(linear)
        self.init(red: encoded[0], green: encoded[1], blue: encoded[2])
    }

    /// From OKLCH: `lightness` 0...1 (not a percentage), `chroma` about 0...0.4, `hue` in degrees.
    public init(oklchLightness lightness: Double, chroma: Double, hue: Double) {
        let radians = hue * .pi / 180
        self.init(oklabLightness: lightness, a: chroma * cos(radians), b: chroma * sin(radians))
    }

    /// From Oklab: `lightness` 0...1.
    public init(oklabLightness lightness: Double, a: Double, b: Double) {
        let lmsCubed = ColourMath.oklabToLMS.apply([lightness, a, b]).map { $0 * $0 * $0 }
        let linear = ColourMath.lmsToXYZ.then(ColourMath.xyzToSRGBLinear).apply(lmsCubed)
        let encoded = ColourMath.encode(linear)
        self.init(red: encoded[0], green: encoded[1], blue: encoded[2])
    }

    public var components: [Double] { [red, green, blue] }

    /// True when every component is finite (a decoded file could hold anything).
    public var isFinite: Bool { red.isFinite && green.isFinite && blue.isFinite }

    /// How far outside 0...1 a component may sit and still count as inside sRGB: half an 8-bit step. Inside it, an
    /// 8-bit hex code represents the colour as well as 8 bits can, and floating-point noise from colour-space
    /// conversions (an sRGB pixel shown on a P3 display and sampled back) is absorbed.
    public static let gamutTolerance = 0.5 / 255

    /// Whether the colour lies inside the sRGB gamut (within `gamutTolerance`). Outside it, hex and `rgb()` clamp.
    public var isInSRGBGamut: Bool {
        components.allSatisfy { $0 >= -Self.gamutTolerance && $0 <= 1 + Self.gamutTolerance }
    }

    /// 0...255 per component, clamped to sRGB and rounded to nearest: what hex, `rgb()` and the contrast check use.
    public var rgb8: (red: Int, green: Int, blue: Int) {
        func byte(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return (byte(red), byte(green), byte(blue))
    }

    /// Linear-light sRGB, unclamped.
    public var linearSRGB: [Double] { ColourMath.decode(components) }

    /// CIE XYZ, D65 white, Y of white = 1.
    public var xyz: [Double] { ColourMath.sRGBLinearToXYZ.apply(linearSRGB) }

    /// Gamma-encoded Display P3 components, unclamped.
    public var displayP3: [Double] {
        ColourMath.encode(ColourMath.sRGBLinearToXYZ.then(ColourMath.xyzToP3Linear).apply(linearSRGB))
    }

    /// Oklab `[L, a, b]` with L in 0...1.
    public var oklab: [Double] { ColourMath.oklab(fromXYZ: xyz) }

    /// OKLCH with L in 0...1 and the hue in degrees, 0..<360. The hue is 0 for an achromatic colour
    /// (chroma below `Colour.achromaticChroma`).
    public var oklch: (lightness: Double, chroma: Double, hue: Double) {
        let lab = oklab
        let chroma = (lab[1] * lab[1] + lab[2] * lab[2]).squareRoot()
        guard chroma >= Self.achromaticChroma else { return (lab[0], chroma, 0) }
        var hue = atan2(lab[2], lab[1]) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (lab[0], chroma, hue)
    }

    /// Below this OKLCH chroma a colour counts as achromatic and its hue is written as 0. It is exactly where the
    /// chroma itself is written as 0.000 (three decimals), so a hue never stands beside a chroma that reads as none.
    /// Deliberately coarser than the CSS Color 4 sample code's epsilon of 0.000004, which only absorbs rounding noise.
    public static let achromaticChroma = 0.0005
}

/// The matrices and transfer function from the CSS Color 4 specification's sample code
/// (https://www.w3.org/TR/css-color-4/#color-conversion-code, file `conversions.js`), copied digit for digit.
/// The Oklab matrices there are Björn Ottosson's (https://bottosson.github.io/posts/oklab/) recomputed by the
/// spec editors for the CSS D65 white point; they agree with his published M1 to about 1e-4.
enum ColourMath {
    struct Matrix: Sendable {
        let rows: [[Double]]

        func apply(_ v: [Double]) -> [Double] {
            rows.map { $0[0] * v[0] + $0[1] * v[1] + $0[2] * v[2] }
        }

        /// `other` applied after `self`.
        func then(_ other: Matrix) -> Matrix {
            Matrix(rows: (0..<3).map { i in
                (0..<3).map { j in (0..<3).reduce(0) { $0 + other.rows[i][$1] * rows[$1][j] } }
            })
        }
    }

    /// `lin_sRGB_to_XYZ`.
    static let sRGBLinearToXYZ = Matrix(rows: [
        [506752 / 1228815, 87881 / 245763, 12673 / 70218],
        [87098 / 409605, 175762 / 245763, 12673 / 175545],
        [7918 / 409605, 87881 / 737289, 1001167 / 1053270],
    ])

    /// `XYZ_to_lin_sRGB`.
    static let xyzToSRGBLinear = Matrix(rows: [
        [12831 / 3959, -329 / 214, -1974 / 3959],
        [-851781 / 878810, 1648619 / 878810, 36519 / 878810],
        [705 / 12673, -2585 / 12673, 705 / 667],
    ])

    /// `lin_P3_to_XYZ`.
    static let p3LinearToXYZ = Matrix(rows: [
        [608311 / 1250200, 189793 / 714400, 198249 / 1000160],
        [35783 / 156275, 247089 / 357200, 198249 / 2500400],
        [0 / 1, 32229 / 714400, 5220557 / 5000800],
    ])

    /// `XYZ_to_lin_P3`.
    static let xyzToP3Linear = Matrix(rows: [
        [446124 / 178915, -333277 / 357830, -72051 / 178915],
        [-14852 / 17905, 63121 / 35810, 423 / 17905],
        [11844 / 330415, -50337 / 660830, 316169 / 330415],
    ])

    /// `XYZ_to_OKLab`, first matrix (XYZ to LMS).
    static let xyzToLMS = Matrix(rows: [
        [0.8190224379967030, 0.3619062600528904, -0.1288737815209879],
        [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
        [0.0481771893596242, 0.2642395317527308, 0.6335478284694309],
    ])

    /// `XYZ_to_OKLab`, second matrix (cube-rooted LMS to Oklab).
    static let lmsToOklab = Matrix(rows: [
        [0.2104542683093140, 0.7936177747023054, -0.0040720430116193],
        [1.9779985324311684, -2.4285922420485799, 0.4505937096174110],
        [0.0259040424655478, 0.7827717124575296, -0.8086757549230774],
    ])

    /// `OKLab_to_XYZ`, first matrix (Oklab to cube-rooted LMS).
    static let oklabToLMS = Matrix(rows: [
        [1.0000000000000000, 0.3963377773761749, 0.2158037573099136],
        [1.0000000000000000, -0.1055613458156586, -0.0638541728258133],
        [1.0000000000000000, -0.0894841775298119, -1.2914855480194092],
    ])

    /// `OKLab_to_XYZ`, second matrix (LMS to XYZ).
    static let lmsToXYZ = Matrix(rows: [
        [1.2268798758459243, -0.5578149944602171, 0.2813910456659647],
        [-0.0405757452148008, 1.1122868032803170, -0.0717110580655164],
        [-0.0763729366746601, -0.4214933324022432, 1.5869240198367816],
    ])

    static func oklab(fromXYZ xyz: [Double]) -> [Double] {
        lmsToOklab.apply(xyzToLMS.apply(xyz).map { cbrt($0) })
    }

    /// Encoded to linear light, mirrored for negative values (`lin_sRGB`; Display P3 uses the same curve).
    static func decode(_ c: [Double]) -> [Double] { c.map(decode) }

    static func decode(_ c: Double) -> Double {
        let magnitude = abs(c)
        if magnitude <= 0.04045 { return c / 12.92 }
        return (c < 0 ? -1 : 1) * pow((magnitude + 0.055) / 1.055, 2.4)
    }

    /// Linear light to encoded, mirrored for negative values (`gam_sRGB`).
    static func encode(_ c: [Double]) -> [Double] { c.map(encode) }

    static func encode(_ c: Double) -> Double {
        let magnitude = abs(c)
        if magnitude <= 0.0031308 { return c * 12.92 }
        return (c < 0 ? -1 : 1) * (1.055 * pow(magnitude, 1 / 2.4) - 0.055)
    }
}

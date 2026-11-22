import Foundation

/// WCAG 2.x contrast between two colours.
///
/// Relative luminance and contrast ratio follow the WCAG 2.2 definitions
/// (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance, #dfn-contrast-ratio) with the sRGB transfer function's
/// 0.04045 threshold (WCAG 2.0 printed 0.03928; the difference never changes an 8-bit result).
///
/// WCAG 2.x is defined over sRGB, so both colours are measured as their hex is written: clamped to sRGB and rounded
/// to 8 bits. That is what a page would ship and what published checkers compute, so the figures match theirs.
/// A pick outside sRGB is measured on its clamped hex; `involvesClamping` says when that happened.
public struct Contrast: Sendable, Equatable {
    public enum Level: String, Sendable, CaseIterable { case aa = "AA", aaa = "AAA" }
    public enum TextSize: String, Sendable, CaseIterable { case normal, large }

    public struct Verdict: Sendable, Equatable, Identifiable {
        public var level: Level
        public var size: TextSize
        public var threshold: Double
        public var passes: Bool
        public var id: String { "\(level.rawValue).\(size.rawValue)" }
    }

    /// The exact ratio, 1...21.
    public let ratio: Double
    /// True when either colour lies outside sRGB and was measured on its clamped hex.
    public let involvesClamping: Bool

    /// Order does not matter: the lighter colour is always on top of the fraction.
    public init(_ a: Colour, _ b: Colour) {
        let la = Self.relativeLuminance(a), lb = Self.relativeLuminance(b)
        ratio = (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        involvesClamping = !a.isInSRGBGamut || !b.isInSRGBGamut
    }

    /// A given ratio, for testing the display and verdict rules.
    init(ratio: Double, involvesClamping: Bool = false) {
        self.ratio = ratio; self.involvesClamping = involvesClamping
    }

    /// WCAG relative luminance of the colour's 8-bit sRGB value: 0 for black, 1 for white.
    public static func relativeLuminance(_ colour: Colour) -> Double {
        let c = colour.rgb8
        func channel(_ byte: Int) -> Double {
            let s = Double(byte) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// The thresholds WCAG names, in hundredths: 3:1 (AA large), 4.5:1 (AA normal, AAA large), 7:1 (AAA normal).
    static let thresholdHundredths = [300, 450, 700]

    /// The ratio in millionths, rounded. Snapping here absorbs floating-point noise (black on white computes as
    /// 20.999999999999996) so that the verdicts and the displayed figure are decided from the same number.
    private var micro: Int { Int((ratio * 1_000_000).rounded()) }

    /// The displayed figure in hundredths: rounded to nearest, except that it never rounds up onto a threshold the
    /// ratio does not reach (4.499 shows as 4.49, not 4.50).
    var displayedHundredths: Int {
        let rounded = (micro + 5_000) / 10_000
        for t in Self.thresholdHundredths where rounded >= t && micro < t * 10_000 { return t - 1 }
        return rounded
    }

    /// "4.52:1", "21.00:1".
    public var text: String {
        let h = displayedHundredths
        return "\(h / 100).\(String(format: "%02d", h % 100)):1"
    }

    public func passes(_ level: Level, _ size: TextSize) -> Bool { micro >= Int(Self.threshold(level, size) * 1_000_000) }

    public static func threshold(_ level: Level, _ size: TextSize) -> Double {
        switch (level, size) {
        case (.aa, .large): 3
        case (.aa, .normal), (.aaa, .large): 4.5
        case (.aaa, .normal): 7
        }
    }

    /// AA normal, AA large, AAA normal, AAA large.
    public var verdicts: [Verdict] {
        Level.allCases.flatMap { level in
            TextSize.allCases.map { size in
                Verdict(level: level, size: size, threshold: Self.threshold(level, size), passes: passes(level, size))
            }
        }
    }
}

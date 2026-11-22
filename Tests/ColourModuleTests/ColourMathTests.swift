import AppKit
import Foundation
import Testing
@testable import ColourModule

/// Reference values, and where they come from:
/// - [CSS4] CSS Color Module Level 4, W3C Candidate Recommendation (https://www.w3.org/TR/css-color-4/):
///   §9 "#7654CD is exactly oklab(54.43237% 0.0681665 -0.1656703)"; §11.1 "oklch(65% 0.15 270)" is
///   "color(display-p3 0.445 0.529 0.891)" and "oklch(65% 0.25 270)" is "color(display-p3 0.3731 0.4673 1.105)" and
///   "color(srgb 0.3475 0.4707 1.146)"; §14.1.3 Display P3 yellow is "oklch(0.96476 0.24503 110.23)" and
///   "color(srgb 1 1 -0.3463)"; §14.2 "oklch(76% 0.27 60)" is "color(display-p3 1.062 0.4954 -0.3115)";
///   §14.1.6 the hue of the sRGB primary blue is 264.06 degrees (rounded from 264.052).
/// - [Ottosson] Björn Ottosson, "A perceptual color space for image processing" (https://bottosson.github.io/posts/oklab/),
///   table of XYZ to Oklab test values, published to three decimals.
@Suite struct ColourMathTests {
    private func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
    private func close(_ a: [Double], _ b: [Double], _ tolerance: Double) -> Bool {
        zip(a, b).allSatisfy { close($0, $1, tolerance) }
    }

    @Test func oklabFromXYZMatchesOttossonsTable() {
        // [Ottosson]: X Y Z -> L a b, rounded to three decimals, so the tolerance is half a unit in the last place
        // plus the small difference between his M1 and the CSS one (under 1e-4).
        let table: [([Double], [Double])] = [
            ([0.950, 1.000, 1.089], [1.000, 0.000, 0.000]),
            ([1.000, 0.000, 0.000], [0.450, 1.236, -0.019]),
            ([0.000, 1.000, 0.000], [0.922, -0.671, 0.263]),
            ([0.000, 0.000, 1.000], [0.153, -1.415, -0.449]),
        ]
        for (xyz, lab) in table {
            #expect(close(ColourMath.oklab(fromXYZ: xyz), lab, 0.0006), "\(xyz)")
        }
    }

    @Test func oklabOfAnSRGBColourMatchesTheSpecExample() {
        // [CSS4] §9: #7654CD = oklab(54.43237% 0.0681665 -0.1656703).
        let lab = Colour(hex: "#7654CD")!.oklab
        #expect(close(lab, [0.5443237, 0.0681665, -0.1656703], 5e-7))
    }

    @Test func oklchToDisplayP3MatchesTheSpecExamples() {
        // [CSS4] §11.1: oklch(65% 0.15 270) = color(display-p3 0.445 0.529 0.891).
        #expect(close(Colour(oklchLightness: 0.65, chroma: 0.15, hue: 270).displayP3, [0.445, 0.529, 0.891], 0.0005))
        // [CSS4] §11.1: oklch(65% 0.25 270), outside both gamuts, unclamped.
        let wide = Colour(oklchLightness: 0.65, chroma: 0.25, hue: 270)
        #expect(close(wide.displayP3, [0.3731, 0.4673, 1.105], 0.0005))
        #expect(close(wide.components, [0.3475, 0.4707, 1.146], 0.0005))
        #expect(!wide.isInSRGBGamut)
        // [CSS4] §14.2: oklch(76% 0.27 60) = color(display-p3 1.062 0.4954 -0.3115).
        #expect(close(Colour(oklchLightness: 0.76, chroma: 0.27, hue: 60).displayP3, [1.062, 0.4954, -0.3115], 0.0005))
    }

    @Test func displayP3YellowMatchesTheSpecExample() {
        // [CSS4] §14.1.3: color(display-p3 1 1 0) = color(srgb 1 1 -0.3463) = oklch(0.96476 0.24503 110.23).
        let yellow = Colour(displayP3: 1, 1, 0)
        #expect(close(yellow.components, [1, 1, -0.3463], 0.00005))
        let lch = yellow.oklch
        #expect(close(lch.lightness, 0.96476, 0.000005))
        #expect(close(lch.chroma, 0.24503, 0.000005))
        #expect(close(lch.hue, 110.23, 0.005))
        #expect(!yellow.isInSRGBGamut)
    }

    @Test func srgbBlueHue() {
        // [CSS4] §14.1.6: 264.052 degrees, quoted there as 264.06.
        #expect(close(Colour(rgb8: 0, 0, 255).oklch.hue, 264.052, 0.001))
    }

    @Test func roundTripsWithinTolerance() {
        // Every conversion is a pair of exact matrix inverses (to float precision) and an exact transfer function,
        // so a round trip lands within 1e-9.
        let colours = [
            Colour(red: 0.2, green: 0.4, blue: 0.6), Colour(red: 1, green: 1, blue: 1), Colour(red: 0, green: 0, blue: 0),
            Colour(red: 0.01, green: 0.5, blue: 0.99), Colour(displayP3: 0, 1, 0), Colour(red: -0.3, green: 1.1, blue: 0.02),
        ]
        for colour in colours {
            let p3 = colour.displayP3
            #expect(close(Colour(displayP3: p3[0], p3[1], p3[2]).components, colour.components, 1e-9), "P3 \(colour)")
            let lab = colour.oklab
            #expect(close(Colour(oklabLightness: lab[0], a: lab[1], b: lab[2]).components, colour.components, 1e-9), "Oklab \(colour)")
            let lch = colour.oklch
            if lch.chroma >= Colour.achromaticChroma {
                let back = Colour(oklchLightness: lch.lightness, chroma: lch.chroma, hue: lch.hue)
                #expect(close(back.components, colour.components, 1e-9), "OKLCH \(colour)")
            }
        }
        for value in stride(from: -1.2, through: 1.2, by: 0.01) {
            #expect(close(ColourMath.encode(ColourMath.decode(value)), value, 1e-12))
        }
    }

    @Test func transferFunctionUsesTheSRGBThreshold() {
        #expect(ColourMath.decode(0.04045) == 0.04045 / 12.92)
        #expect(close(ColourMath.decode(0.5), pow((0.5 + 0.055) / 1.055, 2.4), 1e-15))
        #expect(ColourMath.decode(-0.5) == -ColourMath.decode(0.5))
    }

    @Test func gamut() {
        #expect(Colour(rgb8: 255, 0, 0).isInSRGBGamut)
        #expect(Colour(red: 1.0015, green: -0.0015, blue: 0.5).isInSRGBGamut)  // within half an 8-bit step
        #expect(!Colour(red: 1.003, green: 0, blue: 0).isInSRGBGamut)
        #expect(!Colour(displayP3: 0, 1, 0).isInSRGBGamut)
        // An sRGB colour round-tripped through P3 stays inside.
        let p3 = Colour(rgb8: 0x33, 0x66, 0x99).displayP3
        #expect(Colour(displayP3: p3[0], p3[1], p3[2]).isInSRGBGamut)
    }

    @Test func hexParsing() {
        #expect(Colour(hex: "#777777") == Colour(rgb8: 0x77, 0x77, 0x77))
        #expect(Colour(hex: "1f2a44") == Colour(rgb8: 0x1F, 0x2A, 0x44))
        #expect(Colour(hex: "#12345") == nil)
        #expect(Colour(hex: "#12345G") == nil)
        #expect(Colour(hex: "+12345") == nil)
    }

    /// What `NSColorSampler` hands back goes through `Colour(sampled:)`. Built here from plain `NSColor`s (no
    /// sampler shown): a Display P3 green must survive as an unclamped extended-sRGB value matching the CSS maths.
    @Test func sampledNSColorKeepsWideGamut() throws {
        let green = try #require(Colour(sampled: NSColor(displayP3Red: 0, green: 1, blue: 0, alpha: 1)))
        let expected = Colour(displayP3: 0, 1, 0)  // CSS sample code: about (-0.5116, 1.0183, -0.3107)
        #expect(close(green.components, expected.components, 0.002))
        #expect(close(expected.components, [-0.5116, 1.0183, -0.3107], 0.0001))
        #expect(!green.isInSRGBGamut)

        let srgb = try #require(Colour(sampled: NSColor(srgbRed: 0x33 / 255, green: 0x66 / 255, blue: 0x99 / 255, alpha: 1)))
        #expect(srgb.formatted(.hex).text == "#336699")
        #expect(srgb.isInSRGBGamut)

        let grey = try #require(Colour(sampled: NSColor(white: 0.5, alpha: 1)))  // a grey colour space converts too
        #expect(close(grey.red, grey.green, 1e-6) && close(grey.green, grey.blue, 1e-6))
        #expect(Colour(sampled: NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))) == nil)
    }
}

@Suite struct ColourFormatTests {
    private func text(_ colour: Colour, _ format: ColourFormat) -> String { colour.formatted(format).text }

    @Test func blackAndWhite() {
        let black = Colour(rgb8: 0, 0, 0), white = Colour(rgb8: 255, 255, 255)
        #expect(text(black, .hex) == "#000000")
        #expect(text(white, .hex) == "#FFFFFF")
        #expect(text(black, .rgb) == "rgb(0 0 0)")
        #expect(text(white, .rgb) == "rgb(255 255 255)")
        #expect(text(black, .oklch) == "oklch(0.0% 0.000 0.0)")
        // White computes as L 1.0000000000000002 and a chroma of 5e-16 at hue 180: achromatic, so the hue is 0.
        #expect(text(white, .oklch) == "oklch(100.0% 0.000 0.0)")
        #expect(text(black, .displayP3) == "color(display-p3 0.000 0.000 0.000)")
        #expect(text(white, .displayP3) == "color(display-p3 1.000 1.000 1.000)")
    }

    @Test func primaries() {
        // OKLCH of the sRGB primaries from the CSS Color 4 sample code (red 62.796% 0.25768 29.2339,
        // green 86.644% 0.29483 142.4953, blue 45.201% 0.31321 264.0520), written to the format's precision.
        let red = Colour(rgb8: 255, 0, 0), green = Colour(rgb8: 0, 255, 0), blue = Colour(rgb8: 0, 0, 255)
        #expect(text(red, .hex) == "#FF0000")
        #expect(text(red, .rgb) == "rgb(255 0 0)")
        #expect(text(red, .oklch) == "oklch(62.8% 0.258 29.2)")
        #expect(text(green, .oklch) == "oklch(86.6% 0.295 142.5)")
        #expect(text(blue, .oklch) == "oklch(45.2% 0.313 264.1)")
        // Display P3 of the sRGB primaries (red 0.9175 0.2003 0.1386, green 0.4584 0.9853 0.2983, blue 0 0 0.9596).
        #expect(text(red, .displayP3) == "color(display-p3 0.917 0.200 0.139)")
        #expect(text(green, .displayP3) == "color(display-p3 0.458 0.985 0.298)")
        // Blue's green component computes as -1.8e-16: written 0.000, never -0.000.
        #expect(text(blue, .displayP3) == "color(display-p3 0.000 0.000 0.960)")
        for colour in [red, green, blue] {
            for format in ColourFormat.allCases { #expect(!colour.formatted(format).clamped) }
        }
    }

    @Test func outOfGamutP3Green() {
        let green = Colour(displayP3: 0, 1, 0)
        let hex = green.formatted(.hex)
        #expect(hex.text == "#00FF00")
        #expect(hex.clamped)
        #expect(green.formatted(.rgb).text == "rgb(0 255 0)")
        #expect(green.formatted(.rgb).clamped)
        #expect(green.formatted(.displayP3).text == "color(display-p3 0.000 1.000 0.000)")
        #expect(!green.formatted(.displayP3).clamped)
        #expect(green.formatted(.oklch).text == "oklch(84.9% 0.369 145.6)")
        #expect(!green.formatted(.oklch).clamped)
    }

    @Test func compactForms() {
        let red = Colour(rgb8: 255, 0, 0)
        #expect(red.formatted(.hex).compact == "#FF0000")
        #expect(red.formatted(.rgb).compact == "255 0 0")
        #expect(red.formatted(.oklch).compact == "62.8% 0.258 29.2")
        #expect(red.formatted(.displayP3).compact == "0.917 0.200 0.139")
    }

    @Test func roundingAtTheEdges() {
        // 8-bit: 0.5/255 rounds to 1, just under rounds to 0.
        #expect(Colour(red: 0.5 / 255, green: 0.4999 / 255, blue: 254.5 / 255).formatted(.hex).text == "#0100FF")
        // Clamped values that still round inside 0...255 are not flagged.
        #expect(!Colour(red: 1.0015, green: 0, blue: 0).formatted(.hex).clamped)
        #expect(Colour(red: 1.0015, green: 0, blue: 0).formatted(.hex).text == "#FF0000")
        // A hue that rounds to 360.0 is written 0.0.
        let nearlyRed = Colour(oklchLightness: 0.6, chroma: 0.2, hue: 359.97)
        #expect(nearlyRed.formatted(.oklch).text.hasSuffix(" 0.0)"))
        // Below the achromatic chroma the hue is 0; at it, the hue is kept.
        let grey = Colour(oklchLightness: 0.5, chroma: 0.0004, hue: 120)
        #expect(grey.formatted(.oklch).text == "oklch(50.0% 0.000 0.0)")
        let faint = Colour(oklchLightness: 0.5, chroma: 0.0006, hue: 120)
        #expect(faint.formatted(.oklch).text == "oklch(50.0% 0.001 120.0)")
        // Neutral greys are achromatic.
        #expect(Colour(rgb8: 0x77, 0x77, 0x77).formatted(.oklch).text.hasSuffix(" 0.000 0.0)"))
    }

    @Test func readsSame() {
        #expect(Colour(rgb8: 10, 20, 30).readsSame(as: Colour(red: 10.0001 / 255, green: 20 / 255, blue: 30 / 255)))
        #expect(!Colour(rgb8: 10, 20, 30).readsSame(as: Colour(rgb8: 10, 20, 31)))
        // Two P3 greens with the same clamped hex are different picks.
        #expect(!Colour(displayP3: 0, 1, 0).readsSame(as: Colour(displayP3: 0.1, 1, 0)))
    }
}

@Suite struct ContrastTests {
    // WCAG 2.2 (https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio) and the values published checkers give for
    // these pairs (#777777 on white is the familiar near-miss at 4.48:1).

    @Test func blackOnWhiteIsTwentyOne() {
        let c = Contrast(Colour(rgb8: 0, 0, 0), Colour(rgb8: 255, 255, 255))
        #expect(c.text == "21.00:1")
        #expect(abs(c.ratio - 21) < 1e-9)
        #expect(c.verdicts.allSatisfy { $0.passes })
        #expect(abs(Contrast.relativeLuminance(Colour(rgb8: 255, 255, 255)) - 1) < 1e-12)
        #expect(Contrast.relativeLuminance(Colour(rgb8: 0, 0, 0)) == 0)
    }

    @Test func greyNearMisses() {
        let white = Colour(rgb8: 255, 255, 255)
        let fails = Contrast(Colour(hex: "#777777")!, white)
        #expect(fails.text == "4.48:1")
        #expect(!fails.passes(.aa, .normal))
        #expect(fails.passes(.aa, .large))
        #expect(!fails.passes(.aaa, .normal))
        #expect(!fails.passes(.aaa, .large))

        let passes = Contrast(Colour(hex: "#767676")!, white)
        #expect(passes.text == "4.54:1")
        #expect(passes.passes(.aa, .normal))
        #expect(passes.passes(.aa, .large))
        #expect(!passes.passes(.aaa, .normal))
        #expect(passes.passes(.aaa, .large))
    }

    @Test func orderDoesNotMatter() {
        let a = Colour(hex: "#1F2A44")!, b = Colour(hex: "#F4F1EA")!
        #expect(Contrast(a, b) == Contrast(b, a))
        #expect(Contrast(a, a).text == "1.00:1")
    }

    @Test func luminanceUsesTheSRGBThreshold() {
        // 10/255 = 0.0392 is below 0.04045: linear segment.
        #expect(abs(Contrast.relativeLuminance(Colour(rgb8: 10, 10, 10)) - (10.0 / 255) / 12.92) < 1e-15)
        let mid = pow((128.0 / 255 + 0.055) / 1.055, 2.4)
        #expect(abs(Contrast.relativeLuminance(Colour(rgb8: 128, 128, 128)) - mid) < 1e-15)
    }

    private func text(_ ratio: Double) -> String { Contrast(ratio: ratio).text }

    @Test func neverRoundsUpOntoAThreshold() {
        #expect(text(4.499) == "4.49:1")
        #expect(text(4.4951) == "4.49:1")
        #expect(text(4.5) == "4.50:1")
        #expect(text(2.996) == "2.99:1")
        #expect(text(6.9999) == "6.99:1")
        #expect(text(7.0) == "7.00:1")
        // Away from thresholds it rounds to nearest.
        #expect(text(4.478) == "4.48:1")
        #expect(text(4.4749) == "4.47:1")
        #expect(text(5.555) == "5.56:1")
    }

    @Test func displayedFigureAndVerdictAlwaysAgree() {
        // Every 8-bit grey against every other: whenever a verdict fails, the figure shown is below its threshold,
        // and whenever it passes, the figure is at or above it.
        for a in stride(from: 0, through: 255, by: 3) {
            for b in stride(from: 0, through: 255, by: 5) {
                let c = Contrast(Colour(rgb8: a, a, a), Colour(rgb8: b, b, b))
                let shown = Double(c.displayedHundredths) / 100
                for v in c.verdicts {
                    #expect(v.passes == (shown >= v.threshold), "\(a) on \(b): \(c.text) \(v.id)")
                }
            }
        }
    }

    @Test func outOfGamutIsMeasuredOnTheClampedHex() {
        let p3 = Contrast(Colour(displayP3: 0, 1, 0), Colour(rgb8: 0, 0, 0))
        let hex = Contrast(Colour(rgb8: 0, 255, 0), Colour(rgb8: 0, 0, 0))
        #expect(p3.ratio == hex.ratio)
        #expect(p3.involvesClamping)
        #expect(!hex.involvesClamping)
    }
}

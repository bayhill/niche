import Foundation

/// Invented picks for fixtures, the playground and snapshots.
enum ColourSamples {
    /// Five picks, newest first: a P3 green outside sRGB, a dark ink, a soft paper, a mid grey and a warm accent.
    static func picks(now: Date) -> [ColourPick] {
        let colours: [Colour] = [
            Colour(displayP3: 0.30, 0.88, 0.36),
            Colour(rgb8: 0x1F, 0x2A, 0x44),
            Colour(rgb8: 0xF4, 0xF1, 0xEA),
            Colour(rgb8: 0x76, 0x76, 0x76),
            Colour(rgb8: 0xE0, 0x6C, 0x3B),
        ]
        return colours.enumerated().map { index, colour in
            ColourPick(colour: colour, pickedAt: now.addingTimeInterval(-Double(index) * 240 - 30))
        }
    }

    /// The colour the settings pane writes in each format as an example.
    static let settingsExample = Colour(rgb8: 0xE0, 0x6C, 0x3B)

    /// What the fixture's "Pick a colour" hands out, in turn.
    static let extraPicks: [Colour] = [
        Colour(rgb8: 0x3D, 0x8B, 0x7A),
        Colour(displayP3: 0.95, 0.25, 0.55),
        Colour(rgb8: 0xFF, 0xD1, 0x66),
    ]
}

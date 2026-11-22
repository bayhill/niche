@testable import ColourModule
import Foundation
import NotchCore
import NotchCoreTesting
import Testing

/// Writes the page in each state to $TMPDIR/niche-snapshots for visual review.
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "niche-snapshots", directoryHint: .isDirectory)

    @MainActor private final class NoSampler: ColourSampling {
        func sample() async -> Colour? { nil }
    }

    private func write(_ module: ColourModule, _ name: String) throws {
        let url = try ViewSnapshot.write(
            ColourPage(module: module, scrolls: false), size: PanelLayout.pageSize, to: Self.dir.appending(path: "\(name).png")
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pages() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }

        let hex = ColourModule.sample()
        await hex.start(env.context(for: .colour))
        try write(hex, "colour-hex")

        for format in [ColourFormat.rgb, .oklch, .displayP3] {
            env.settings.set(ColourModule.formatKey, format)
            try write(hex, "colour-\(format.rawValue)")
        }
        env.settings.set(ColourModule.formatKey, .hex)

        let comparing = ColourModule.sample()
        await comparing.start(env.context(for: .colour))
        comparing.setComparing(true)
        comparing.activate(comparing.picks[0])  // un-choose the newest
        comparing.activate(comparing.picks[2])  // choose the paper: ink on paper
        try write(comparing, "colour-compare")

        let one = ColourModule.sample()
        await one.start(env.context(for: .colour))
        one.setComparing(true)
        one.activate(one.picks[0])
        try write(one, "colour-compare-one")

        let empty = ColourModule(sampler: NoSampler(), copy: { _ in })
        try write(empty, "colour-empty")

        let full = ColourModule(sampler: NoSampler(), copy: { _ in })
        await full.start(env.context(for: .colour))
        for i in 0..<12 { full.record(Colour(oklchLightness: 0.3 + Double(i) * 0.05, chroma: 0.12, hue: Double(i) * 30)) }
        try write(full, "colour-full")
        full.stop()

        print("snapshots in \(Self.dir.path)")
    }
}

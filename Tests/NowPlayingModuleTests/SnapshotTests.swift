import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

/// Writes the card in each state to $TMPDIR/notcher-snapshots for visual review.
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "notcher-snapshots", directoryHint: .isDirectory)

    @Test func cards() throws {
        var paused = SampleProvider.track
        paused.isPlaying = false
        let long = NowPlayingState(
            title: "A Very Long Track Title That Never Ends (Extended Remix)", artist: "Somebody Featuring Somebody Else",
            isPlaying: true, bundleID: "com.apple.Safari"
        )
        let connect = NowPlayingModule(adapter: nil, adapterSelfTest: { false }, fallback: FakeProvider(.appleScript))
        connect.select(adapterPassed: false)
        let cases: [(String, NowPlayingModule)] = [
            ("nowplaying-playing", .sample()),
            ("nowplaying-paused", .sample(paused)),
            ("nowplaying-long-noart", .sample(long)),
            ("nowplaying-empty", .sample(nil)),
            ("nowplaying-connect", connect),
        ]
        for (name, module) in cases {
            let url = try ViewSnapshot.write(module: module, to: Self.dir.appending(path: "\(name).png"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        print("snapshots in \(Self.dir.path)")
    }
}

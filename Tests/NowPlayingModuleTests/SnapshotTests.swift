import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

/// Writes the card in each state to $TMPDIR/notcher-snapshots for visual review (210 × 184, the centre slot).
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "notcher-snapshots", directoryHint: .isDirectory)

    @Test func cards() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        var paused = SampleProvider.track
        paused.isPlaying = false
        let long = NowPlayingState(
            title: "A Very Long Track Title That Never Ends (Extended Remix)", artist: "Somebody Featuring Somebody Else",
            album: "An Album Name That Is Also Far Too Long", isPlaying: true, bundleID: "com.apple.Safari"
        )
        let plainCard = NowPlayingModule.sample()
        await plainCard.start(env.context(for: .nowPlaying))
        env.settings.set(NowPlayingModule.ambientArtwork, false)

        let connect = NowPlayingModule(adapter: nil, adapterSelfTest: { .failed }, fallback: FakeProvider(.appleScript))
        connect.select(adapterPassed: false)
        let deniedFallback = FakeProvider(.appleScript)
        let denied = NowPlayingModule(adapter: nil, adapterSelfTest: { .failed }, fallback: deniedFallback)
        denied.connect()
        deniedFallback.onFailure?(.notAuthorized(bundleID: "com.spotify.client"))
        let unavailable = NowPlayingModule(adapter: nil, adapterSelfTest: { .failed }, fallback: nil)
        unavailable.select(adapterPassed: false)

        let recorder = OpenerRecorder()
        recorder.running["com.spotify.client"] = .some("Spotify")
        let clickable = NowPlayingModule(
            adapter: SampleProvider(state: SampleProvider.track), adapterSelfTest: { .passed }, fallback: nil, opener: recorder.opener
        )
        clickable.select(adapterPassed: true)
        #expect(clickable.sourceApp?.openLabel == "Open Spotify")

        let cases: [(String, NowPlayingModule)] = [
            ("np-clickable", clickable),
            ("np-playing-ambient", .sample()),
            ("np-playing-plain", plainCard),
            ("np-paused", .sample(paused)),
            ("np-long-noart-noposition", .sample(long)),
            ("np-empty", .sample(nil)),
            ("np-connect", connect),
            ("np-denied", denied),
            ("np-unavailable", unavailable),
        ]
        for (name, module) in cases {
            let url = try ViewSnapshot.write(module: module, to: Self.dir.appending(path: "\(name).png"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(denied.phase == .notAuthorized(app: "Spotify"))
        print("snapshots in \(Self.dir.path)")
    }
}

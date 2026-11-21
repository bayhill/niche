import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Synchronization
import Testing

@Suite struct PositionTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func state(playing: Bool = true, elapsed: Double? = 60, duration: Double? = 200, rate: Double? = nil) -> NowPlayingState {
        NowPlayingState(title: "A", isPlaying: playing, elapsed: elapsed, duration: duration, timestamp: t, playbackRate: rate)
    }

    @Test func advancesWhilePlaying() {
        #expect(state().position(at: t) == 60)
        #expect(state().position(at: t.addingTimeInterval(12.5)) == 72.5)
        #expect(PlaybackPosition.progress(of: state(), at: t.addingTimeInterval(40)) == 0.5)
    }

    @Test func frozenWhilePaused() {
        #expect(state(playing: false).position(at: t.addingTimeInterval(300)) == 60)
    }

    @Test func unknownElapsedOrDurationHidesTheRow() {
        #expect(state(elapsed: nil).position(at: t) == nil)
        #expect(state(duration: nil).position(at: t) == nil)
        #expect(state(duration: 0).position(at: t) == nil)
        #expect(PlaybackPosition.progress(of: state(duration: nil), at: t) == nil)
    }

    @Test func honoursPlaybackRate() {
        #expect(state(rate: 2).position(at: t.addingTimeInterval(10)) == 80)
        #expect(state(rate: 0.5).position(at: t.addingTimeInterval(10)) == 65)
        // A zero or missing rate while playing counts as normal speed.
        #expect(state(rate: 0).position(at: t.addingTimeInterval(10)) == 70)
    }

    @Test func clampedToDuration() {
        #expect(state().position(at: t.addingTimeInterval(1000)) == 200)
        #expect(state(elapsed: -5).position(at: t) == 0)
        // A timestamp in the future never moves the playhead backwards.
        #expect(state().position(at: t.addingTimeInterval(-30)) == 60)
    }

    @Test func noTimestampMeansNoExtrapolation() {
        let s = NowPlayingState(title: "A", isPlaying: true, elapsed: 30, duration: 100)
        #expect(s.position(at: t.addingTimeInterval(50)) == 30)
    }

    @Test func parserReadsPlaybackRate() {
        var parser = AdapterStreamParser()
        var payload = StreamFixture.track
        payload["playbackRate"] = 1.5
        #expect(parser.feed(StreamFixture.full(payload)).first??.playbackRate == 1.5)
    }

    @Test func formatsLikeTheDesign() {
        let s = state(elapsed: 84, duration: 221)
        let p = s.position(at: t)!
        #expect(Format.playback(seconds: p) == "1:24")
        #expect(Format.playback(seconds: s.duration! - p, remaining: true) == "\u{2212}2:17")
    }
}

@MainActor
@Suite struct CardTests {
    @Test func placementAndAmbientSetting() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = NowPlayingModule.sample()
        #expect(module.placement == .dashboard(.center))
        #expect(module.ambientArtwork) // default before start
        await module.start(env.context(for: .nowPlaying))
        #expect(module.ambientArtwork)
        env.settings.set(NowPlayingModule.ambientArtwork, false)
        #expect(!module.ambientArtwork)
    }

    @Test func sampleShowsPositionAndAlbum() {
        let s = SampleProvider.track
        #expect(s.artwork != nil)
        #expect(s.album != nil)
        #expect(s.position(at: .now) != nil)
    }

    @Test func appleScriptPublishesSeeksButNotSteadyProgress() async {
        let shared = OutputBox(output: "playing\nSong\nArtist\nAlbum\n200\n10\n")
        let runner = FakeScriptRunner { _ in .success(shared.get()) }
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let provider = AppleScriptProvider(runner: runner, runningPlayers: { [.music] }, loadArtwork: { _ in nil }, now: { clock.value })
        var updates: [NowPlayingState?] = []
        provider.onUpdate = { updates.append($0) }
        _ = await provider.poll()
        clock.value = clock.value.addingTimeInterval(5)
        shared.set("playing\nSong\nArtist\nAlbum\n200\n15\n") // steady progress: no update
        _ = await provider.poll()
        #expect(updates.count == 1)
        clock.value = clock.value.addingTimeInterval(5)
        shared.set("playing\nSong\nArtist\nAlbum\n200\n120\n") // seek
        _ = await provider.poll()
        #expect(updates.count == 2)
        #expect(updates.last??.elapsed == 120)
    }
}

final class OutputBox: Sendable {
    private let value: Mutex<String>
    init(output: String) { value = Mutex(output) }
    func get() -> String { value.withLock { $0 } }
    func set(_ new: String) { value.withLock { $0 = new } }
}

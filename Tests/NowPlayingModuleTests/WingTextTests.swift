import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

@MainActor
@Suite struct WingTextTests {
    let t = Date(timeIntervalSince1970: 1_000)

    @Test func titleAndArtistInTheWings() throws {
        let a = try #require(NowPlayingActivity.make(NowPlayingState(title: "Paper Lanterns at Low Tide", artist: "Saltmere Quartet", isPlaying: true), updatedAt: t))
        #expect(a.leadingText == "Paper Lanterns at Low Tide")
        #expect(a.trailingText == "Saltmere Quartet")
        #expect(a.accessibilityLabel == "Playing Paper Lanterns at Low Tide by Saltmere Quartet")
        #expect(a.priority == .ambient)
        #expect(a.trailing == .equalizer(playing: true))
        #expect(a.leading == .symbol("music.note", tint: .primary)) // never tinted
    }

    @Test func offMeansExactlyTheOldActivity() throws {
        let s = NowPlayingState(title: "Paper Lanterns at Low Tide", artist: "Saltmere Quartet", isPlaying: true)
        let a = try #require(NowPlayingActivity.make(s, updatedAt: t, showText: false))
        #expect(a.leadingText == nil)
        #expect(a.trailingText == nil)
        var on = try #require(NowPlayingActivity.make(s, updatedAt: t))
        on.leadingText = nil; on.trailingText = nil
        #expect(a == on)
    }

    @Test func artistFallsBackToAlbumThenNothing() {
        let album = NowPlayingActivity.make(NowPlayingState(title: "Track", album: "Album", isPlaying: true), updatedAt: t)
        #expect(album?.trailingText == "Album")
        #expect(album?.accessibilityLabel == "Playing Track from Album")
        let none = NowPlayingActivity.make(NowPlayingState(title: "Track", isPlaying: true), updatedAt: t)
        #expect(none?.trailingText == nil)
        #expect(none?.accessibilityLabel == "Playing Track")
    }

    @Test func whitespaceIsTrimmedAndEmptyIsOmitted() {
        let a = NowPlayingActivity.make(
            NowPlayingState(title: "  Paper Lanterns at Low Tide \n", artist: "   ", album: "\tAmbient ", isPlaying: true), updatedAt: t
        )
        #expect(a?.leadingText == "Paper Lanterns at Low Tide")
        #expect(a?.trailingText == "Ambient") // blank artist falls back to the album
        let blank = NowPlayingActivity.make(NowPlayingState(title: " \n ", artist: "", album: " ", isPlaying: true), updatedAt: t)
        #expect(blank?.leadingText == nil)
        #expect(blank?.trailingText == nil)
        #expect(blank?.accessibilityLabel == "Playing")
        #expect(NowPlayingActivity.make(NowPlayingState(title: "Two\nlines", isPlaying: true), updatedAt: t)?.leadingText == "Two lines")
    }

    @Test func pausedShowsNothing() {
        #expect(NowPlayingActivity.make(NowPlayingState(title: "A", artist: "B", isPlaying: false), updatedAt: t) == nil)
    }

    @Test func identityStableAcrossTracksAndUpdatedAtUnchanged() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let clock = Box(t)
        let adapter = FakeProvider(.mediaRemote)
        let m = NowPlayingModule(adapter: adapter, adapterSelfTest: { .passed }, selfTestKey: "k", fallback: nil, now: { clock.value })
        await m.start(env.context(for: .nowPlaying))
        var state = NowPlayingState(title: "One", artist: "A", isPlaying: true, elapsed: 1, duration: 100, timestamp: t)
        adapter.onUpdate?(state)
        let first = try #require(m.liveActivity)
        // Position-only change: same activity, same updatedAt.
        clock.value = t.addingTimeInterval(30)
        state.elapsed = 31
        adapter.onUpdate?(state)
        #expect(m.liveActivity == first)
        // New track: same id (animates in place), new text, updatedAt moves on as before.
        clock.value = t.addingTimeInterval(60)
        adapter.onUpdate?(NowPlayingState(title: "Two", artist: "B", isPlaying: true))
        let second = try #require(m.liveActivity)
        #expect(second.id == first.id)
        #expect(second.leadingText == "Two")
        #expect(second.trailingText == "B")
        #expect(second.updatedAt == t.addingTimeInterval(60))
        m.stop()
    }

    @Test func togglingTheSettingUpdatesTheWings() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = NowPlayingModule.sample()
        await module.start(env.context(for: .nowPlaying))
        #expect(module.liveActivity?.leadingText == "Paper Lanterns at Low Tide")
        env.settings.set(NowPlayingModule.showTitleInNotch, false)
        #expect(await eventually { module.liveActivity?.leadingText == nil })
        #expect(module.liveActivity != nil) // artwork and equalizer stay
        #expect(module.liveActivity?.trailingText == nil)
        env.settings.set(NowPlayingModule.showTitleInNotch, true)
        #expect(await eventually { module.liveActivity?.trailingText == "Saltmere Quartet" })
        module.stop()
    }

    @Test func longSampleForTruncation() throws {
        let a = try #require(NowPlayingModule.sample(SampleProvider.longTrack).liveActivity)
        #expect((a.leadingText?.count ?? 0) > 40)
        #expect((a.trailingText?.count ?? 0) > 40)
        #expect(NowPlayingModule.showTitleInNotch.name == "nowPlaying.showTitleInNotch")
        #expect(NowPlayingModule.showTitleInNotch.defaultValue)
    }
}

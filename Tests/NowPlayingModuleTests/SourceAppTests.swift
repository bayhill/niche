import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

/// Records what the opener would do; never touches a real app.
@MainActor
final class OpenerRecorder {
    var running: [String: String?] = [:]
    var installed: [String: URL] = [:]
    var names: [URL: String] = [:]
    var activated: [String] = []
    var launched: [URL] = []

    var opener: SourceAppOpener {
        SourceAppOpener(
            runningName: { [unowned self] in self.running[$0] },
            appURL: { [unowned self] in self.installed[$0] },
            bundleName: { [unowned self] in self.names[$0] },
            activate: { [unowned self] in self.activated.append($0) },
            launch: { [unowned self] in self.launched.append($0) }
        )
    }
}

@MainActor
@Suite struct SourceAppTests {
    let spotifyURL = URL(filePath: "/Applications/Spotify.app")

    func start(_ recorder: OpenerRecorder, _ env: TestEnvironment) async -> (NowPlayingModule, FakeProvider) {
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let adapter = FakeProvider(.mediaRemote)
        let m = NowPlayingModule(adapter: adapter, adapterSelfTest: { .passed }, selfTestKey: "k", fallback: nil, opener: recorder.opener)
        await m.start(env.context(for: .nowPlaying))
        return (m, adapter)
    }

    @Test func runningAppIsActivatedAndTheNotchCollapses() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder()
        r.running["com.spotify.client"] = .some("Spotify")
        let (m, adapter) = await start(r, env)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true, bundleID: "com.spotify.client"))
        #expect(m.sourceApp == SourceApp(bundleID: "com.spotify.client", name: "Spotify"))
        m.openSourceApp()
        #expect(r.activated == ["com.spotify.client"])
        #expect(r.launched.isEmpty)
        #expect(env.notch.calls == [.collapse])
        m.stop()
    }

    @Test func installedButQuitAppIsLaunched() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder()
        r.running["com.spotify.client"] = .some("Spotify")
        r.installed["com.spotify.client"] = spotifyURL
        let (m, adapter) = await start(r, env)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: false, bundleID: "com.spotify.client"))
        r.running = [:] // the player quit after the card resolved it
        m.openSourceApp()
        #expect(r.activated.isEmpty)
        #expect(r.launched == [spotifyURL])
        #expect(env.notch.calls == [.collapse])

        // Not running from the start: resolved from the installed bundle's name.
        r.names[spotifyURL] = "Spotify"
        adapter.onUpdate?(NowPlayingState(title: "B", isPlaying: false, bundleID: "com.spotify.client.other"))
        #expect(m.sourceApp == nil)
        r.installed["com.spotify.client.other"] = spotifyURL
        adapter.onUpdate?(NowPlayingState(title: "C", isPlaying: false, bundleID: "com.spotify.client"))
        #expect(m.sourceApp?.name == "Spotify")
        m.stop()
    }

    @Test func missingOrUnknownBundleIsInert() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder()
        let (m, adapter) = await start(r, env)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true, bundleID: nil))
        #expect(m.sourceApp == nil)
        m.openSourceApp()
        adapter.onUpdate?(NowPlayingState(title: "B", isPlaying: true, bundleID: "com.example.gone"))
        #expect(m.sourceApp == nil)
        m.openSourceApp()
        #expect(r.activated.isEmpty && r.launched.isEmpty)
        #expect(env.notch.calls.isEmpty)
        m.stop()
    }

    @Test func uninstalledAtClickTimeDoesNotCollapse() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder()
        r.running["com.spotify.client"] = .some("Spotify")
        let (m, adapter) = await start(r, env)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true, bundleID: "com.spotify.client"))
        r.running = [:]
        m.openSourceApp()
        #expect(env.notch.calls.isEmpty)
        m.stop()
    }

    @Test func pauseIfPlayingOnlyEverPauses() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder() // kept alive: the opener's closures hold it unowned
        let (m, adapter) = await start(r, env)
        // Nothing known: nothing sent.
        m.pauseIfPlaying()
        #expect(adapter.sent.isEmpty)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: false, bundleID: "com.spotify.client"))
        m.pauseIfPlaying()
        #expect(adapter.sent.isEmpty)
        // Playing: the pause-only command, never the toggle.
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true, bundleID: "com.spotify.client"))
        m.pauseIfPlaying()
        #expect(adapter.sent == [.pause])
        let service: any PlaybackControlling = m
        service.pauseIfPlaying()
        #expect(adapter.sent == [.pause, .pause])
        #expect(r.activated.isEmpty && r.launched.isEmpty)
        m.stop()
    }

    @Test func pauseIsItsOwnCommand() {
        #expect(MediaCommand.pause.adapterID == 1)
        #expect(MediaCommand.togglePlayPause.adapterID == 2)
        #expect(Set(MediaCommand.allCases.map(\.adapterID)).count == MediaCommand.allCases.count)
        #expect(MediaCommand.pause.isPlaying(after: true) == false)
        #expect(MediaCommand.pause.isPlaying(after: false) == false)
        #expect(MediaCommand.togglePlayPause.isPlaying(after: false) == true)
        #expect(MediaCommand.next.isPlaying(after: true) == nil)
        for player in ScriptablePlayer.allCases { #expect(player.commandScript(.pause).hasSuffix(" to pause")) }
        // The sample source pauses and stays paused.
        let sample = SampleProvider(state: SampleProvider.track)
        sample.send(.pause)
        #expect(sample.state?.isPlaying == false)
        sample.send(.pause)
        #expect(sample.state?.isPlaying == false)
    }

    @Test func transportDoesNotOpenTheApp() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let r = OpenerRecorder()
        r.running["com.spotify.client"] = .some("Spotify")
        let (m, adapter) = await start(r, env)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true, bundleID: "com.spotify.client"))
        for command in MediaCommand.allCases { m.send(command) }
        #expect(adapter.sent == MediaCommand.allCases)
        #expect(r.activated.isEmpty && r.launched.isEmpty)
        #expect(env.notch.calls.isEmpty)
        m.stop()
    }

    @Test func labelsUseTheAppName() {
        #expect(SourceApp(bundleID: "com.spotify.client", name: "Spotify").openLabel == "Open Spotify")
        #expect(SourceApp(bundleID: "x", name: nil).openLabel == "Open app")
        let r = OpenerRecorder()
        r.running["a"] = .some(nil) // running, but no localized name
        #expect(r.opener.resolve("a") == SourceApp(bundleID: "a", name: nil))
        #expect(r.opener.resolve("") == nil)
        #expect(r.opener.resolve(nil) == nil)
    }

    @Test func sampleIsNotClickable() {
        let m = NowPlayingModule.sample()
        #expect(m.state?.bundleID == "com.spotify.client")
        #expect(m.sourceApp == nil)
        m.openSourceApp() // inert opener: nothing happens
        #expect(SourceAppOpener.inert.resolve("com.spotify.client") == nil)
    }
}

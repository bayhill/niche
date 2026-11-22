import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

private let locations = AdapterLocations(
    script: URL(filePath: "/tmp/fixture/mediaremote-adapter.pl"), framework: URL(filePath: "/tmp/fixture/MediaRemoteAdapter.framework")
)

@Suite struct BackoffTests {
    @Test func exponentialThenGivesUp() {
        var b = RestartBackoff(initial: .seconds(1), maximum: .seconds(10), stableAfter: .seconds(30), maxQuickFailures: 6)
        let delays = (0..<7).map { _ in b.next(afterRunOf: .seconds(1)) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10), nil])
    }

    @Test func stableRunResets() {
        var b = RestartBackoff(initial: .seconds(1), maximum: .seconds(60), stableAfter: .seconds(30), maxQuickFailures: 3)
        _ = b.next(afterRunOf: .zero)
        _ = b.next(afterRunOf: .zero)
        #expect(b.next(afterRunOf: .zero) == .seconds(4))
        #expect(b.next(afterRunOf: .seconds(45)) == .seconds(1))
        #expect(b.failures == 1)
    }
}

@MainActor
@Suite struct AdapterProviderTests {
    @Test func streamsStatesAndRestartsWithBackoff() async {
        let first = FakeChild(chunks: [StreamFixture.full(StreamFixture.track)], status: 1)
        let second = FakeChild(chunks: [StreamFixture.full(StreamFixture.track), StreamFixture.diff(["title": "Copper Orbit"])], status: 1)
        let launcher = FakeLauncher(children: [first, second])
        let sleeper = RecordingSleeper()
        let provider = AdapterProvider(
            locations: locations, launcher: launcher,
            backoff: RestartBackoff(initial: .milliseconds(100), maximum: .seconds(1), maxQuickFailures: 3), sleep: sleeper.sleep
        )
        var states: [NowPlayingState?] = []
        var failures: [NowPlayingFailure] = []
        provider.onUpdate = { states.append($0) }
        provider.onFailure = { failures.append($0) }
        provider.start()

        #expect(await eventually { failures == [.gaveUp] })
        // 2 scripted runs + 2 fallback runs that exit immediately; the 4th failure exceeds maxQuickFailures.
        #expect(launcher.launched.count == 4)
        #expect(provider.launches == 4)
        #expect(sleeper.recorded == [.milliseconds(100), .milliseconds(200), .milliseconds(400)])
        #expect(launcher.launched[0] == [locations.script.path, locations.framework.path, "stream", "--micros", "--debounce=60"])
        // Same track after restart is not re-delivered; the title change is; giving up clears.
        #expect(states.map { $0?.title } == ["Paper Lanterns at Low Tide", "Copper Orbit", nil])
    }

    @Test func stopTerminatesChild() async {
        let child = FakeChild(chunks: [StreamFixture.full(StreamFixture.track)], stayOpen: true)
        let launcher = FakeLauncher(children: [child])
        let provider = AdapterProvider(locations: locations, launcher: launcher, sleep: RecordingSleeper().sleep)
        var latest: NowPlayingState?
        provider.onUpdate = { latest = $0 }
        provider.start()
        provider.start() // idempotent
        #expect(await eventually { latest?.title == "Paper Lanterns at Low Tide" })
        #expect(launcher.launched.count == 1)
        provider.stop()
        #expect(child.terminated)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(launcher.launched.count == 1) // not restarted after stop
    }

    @Test func sendUsesAdapterCommandIDsAndTogglesOptimistically() async {
        let child = FakeChild(chunks: [StreamFixture.full(StreamFixture.track)], stayOpen: true)
        let launcher = FakeLauncher(children: [child])
        let provider = AdapterProvider(locations: locations, launcher: launcher, sleep: RecordingSleeper().sleep)
        var latest: NowPlayingState?
        provider.onUpdate = { latest = $0 }
        provider.start()
        #expect(await eventually { latest != nil })
        provider.send(.togglePlayPause)
        #expect(latest?.isPlaying == false)
        provider.send(.next)
        provider.send(.previous)
        #expect(await eventually { launcher.ran.count == 3 })
        let commands = Set(launcher.ran.map { $0.suffix(2) }.map(Array.init))
        #expect(commands == [["send", "2"], ["send", "4"], ["send", "5"]])
        #expect(launcher.ran.allSatisfy { $0.first == "/usr/bin/perl" })
        provider.stop()
    }

    @Test func selfTestPassesOnlyOnCleanExit() async {
        let ok = FakeLauncher(runResult: ProcessResult(status: 0))
        #expect(await AdapterProvider.selfTest(locations, launcher: ok) == .passed)
        #expect(ok.ran.first == ["/usr/bin/perl", locations.script.path, locations.framework.path, locations.testClient.path, "test"])
        #expect(locations.testClient.lastPathComponent == "MediaRemoteAdapterTestClient")
        #expect(await AdapterProvider.selfTest(locations, launcher: FakeLauncher(runResult: ProcessResult(status: 4))) == .failed)
        // A timeout (e.g. a loaded login) or a launch failure says nothing about MediaRemote.
        #expect(await AdapterProvider.selfTest(locations, launcher: FakeLauncher(runResult: ProcessResult(status: 15, timedOut: true))) == .unknown)
        #expect(await AdapterProvider.selfTest(locations, launcher: FakeLauncher(runResult: ProcessResult(status: -1))) == .unknown)
    }

    @Test func bundleLookupNeedsBothFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "np-bundle-\(UUID().uuidString)/Fake.app/Contents")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appending(path: "Frameworks/MediaRemoteAdapter.framework"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.fake</string></dict></plist>"
        try Data(plist.utf8).write(to: root.appending(path: "Info.plist"))
        let bundle = try #require(Bundle(url: root.deletingLastPathComponent()))
        #expect(AdapterLocations.inBundle(bundle) == nil)
        try Data("#!/usr/bin/perl\n".utf8).write(to: root.appending(path: "Resources/mediaremote-adapter.pl"))
        let found = try #require(AdapterLocations.inBundle(bundle))
        #expect(found.framework.lastPathComponent == "MediaRemoteAdapter.framework")
        #expect(found.perl.path == "/usr/bin/perl")
    }
}

@MainActor
@Suite struct AppleScriptProviderTests {
    @Test func parsesSpotifyOutputWithDecimalComma() throws {
        let out = "playing\nCopper Orbit\nGlasswing Chamber Ensemble\nCopper Orbit EP\n301,5\n12,25\nhttps://i.scdn.co/image/ab67\n"
        let parsed = try #require(PlayerScriptOutput.parse(out, player: .spotify, now: Date(timeIntervalSince1970: 0)))
        #expect(parsed.state.title == "Copper Orbit")
        #expect(parsed.state.artist == "Glasswing Chamber Ensemble")
        #expect(parsed.state.duration == 301.5)
        #expect(parsed.state.elapsed == 12.25)
        #expect(parsed.state.isPlaying)
        #expect(parsed.state.bundleID == "com.spotify.client")
        #expect(parsed.artworkURL?.host() == "i.scdn.co")
    }

    @Test func parsesMusicPausedWithMissingValues() throws {
        let parsed = try #require(PlayerScriptOutput.parse("paused\nSong\nmissing value\n\n200\n5\n", player: .music, now: .now))
        #expect(!parsed.state.isPlaying)
        #expect(parsed.state.artist == nil)
        #expect(parsed.state.album == nil)
        #expect(parsed.artworkURL == nil)
        #expect(PlayerScriptOutput.parse("stopped\n", player: .music, now: .now) == nil)
        #expect(PlayerScriptOutput.parse("playing\n\n", player: .music, now: .now) == nil)
    }

    @Test func pollsOnlyRunningPlayers() async {
        let runner = FakeScriptRunner { _ in .success("playing\nSong\nArtist\nAlbum\n100\n1\n") }
        let running = Box<[ScriptablePlayer]>([])
        let provider = AppleScriptProvider(runner: runner, runningPlayers: { running.value }, loadArtwork: { _ in nil })
        var latest: NowPlayingState?? = .none
        provider.onUpdate = { latest = .some($0) }
        _ = await provider.poll()
        #expect(runner.calls.withLock { $0 } == 0) // nothing running: no Apple Events
        running.value = [.music]
        _ = await provider.poll()
        #expect(runner.calls.withLock { $0 } == 1)
        #expect(latest??.title == "Song")
        #expect(latest??.bundleID == "com.apple.Music")
    }

    @Test func deniedAutomationReportsAndStopsAsking() async {
        let runner = FakeScriptRunner { _ in .failure(ScriptError("execution error: Not authorized to send Apple events to Spotify. (-1743)")) }
        let provider = AppleScriptProvider(runner: runner, runningPlayers: { [.spotify] }, loadArtwork: { _ in nil })
        var failures: [NowPlayingFailure] = []
        provider.onFailure = { failures.append($0) }
        _ = await provider.poll()
        _ = await provider.poll()
        #expect(failures == [.notAuthorized(bundleID: "com.spotify.client")])
        #expect(runner.calls.withLock { $0 } == 1)
    }

    @Test func prefersThePlayingApp() async {
        let runner = FakeScriptRunner { source in
            source.contains("com.spotify.client") ? .success("paused\nA\nX\nY\n1\n0\n") : .success("playing\nB\nX\nY\n1\n0\n")
        }
        let provider = AppleScriptProvider(runner: runner, runningPlayers: { [.spotify, .music] }, loadArtwork: { _ in nil })
        var latest: NowPlayingState?
        provider.onUpdate = { latest = $0 }
        _ = await provider.poll()
        #expect(latest?.title == "B")
        provider.send(.togglePlayPause)
        #expect(latest?.isPlaying == false) // optimistic
    }

    @Test func scriptsTargetTheRightApp() {
        #expect(ScriptablePlayer.spotify.statusScript.contains("tell application id \"com.spotify.client\""))
        #expect(ScriptablePlayer.spotify.statusScript.contains("/ 1000"))
        #expect(ScriptablePlayer.music.commandScript(.next)
            == "if application id \"com.apple.Music\" is running then tell application id \"com.apple.Music\" to next track")
        #expect(ScriptablePlayer.spotify.commandScript(.togglePlayPause).hasSuffix("playpause"))
    }
}

@Suite struct FoundationLauncherTests {
    @Test func runCapturesOutputAndStatus() async {
        let r = await FoundationProcessLauncher().run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "printf 'a\\nb'; printf oops >&2; exit 3"], timeout: .seconds(5)
        )
        #expect(r.status == 3)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "a\nb")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "oops")
        #expect(!r.timedOut)
    }

    @Test func runTimesOut() async {
        let start = ContinuousClock.now
        let r = await FoundationProcessLauncher().run(URL(filePath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(200))
        #expect(r.timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func launchStreamsAndTerminates() async throws {
        let child = try FoundationProcessLauncher().launch(URL(filePath: "/bin/sh"), arguments: ["-c", "echo ready; exec sleep 30"])
        var iterator = child.output.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == "ready\n")
        child.terminate()
        let status = await child.waitForExit()
        #expect(status == 15)
    }
}

/// Runs only when NOTCHER_ADAPTER_DIR points at a `build.sh` output. Reads now-playing state; never sends commands.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOTCHER_ADAPTER_DIR"] != nil))
struct RealAdapterTests {
    @Test func selfTestAndStream() async throws {
        let dir = URL(filePath: try #require(ProcessInfo.processInfo.environment["NOTCHER_ADAPTER_DIR"]))
        let loc = AdapterLocations(script: dir.appending(path: "mediaremote-adapter.pl"), framework: dir.appending(path: "MediaRemoteAdapter.framework"))
        #expect(await AdapterProvider.selfTest(loc) == .passed)
        let provider = AdapterProvider(locations: loc)
        var updates = 0
        provider.onUpdate = { _ in updates += 1 }
        provider.start()
        #expect(await eventually(.seconds(5)) { provider.launches == 1 })
        try await Task.sleep(for: .seconds(2))
        provider.stop()
        print("real adapter: launches \(provider.launches), updates \(updates)")
        #expect(provider.launches == 1)
    }
}

@MainActor
@Suite struct FallbackPollingTests {
    @Test func scriptsGuardAgainstRelaunchingAPlayerThatQuit() {
        for player in ScriptablePlayer.allCases {
            let script = player.statusScript
            let guardLine = script.range(of: "if application id \"\(player.bundleID)\" is running then")
            let tell = script.range(of: "tell application id \"\(player.bundleID)\"")
            #expect(guardLine != nil && tell != nil && guardLine!.lowerBound < tell!.lowerBound)
            for command in MediaCommand.allCases {
                #expect(player.commandScript(command).hasPrefix("if application id \"\(player.bundleID)\" is running then"))
            }
        }
        #expect(PlayerScriptOutput.parse("notrunning\n", player: .spotify, now: .now) == nil)
    }

    @Test func schedule() {
        let s = PollSchedule()
        #expect(s.interval(playing: true, idleFor: 10_000) == .milliseconds(1500))
        #expect(s.interval(playing: false, idleFor: 0) == .seconds(5))
        #expect(s.interval(playing: false, idleFor: 299) == .seconds(5))
        #expect(s.interval(playing: false, idleFor: 300) == .seconds(20))
        #expect(s.noPlayer == .seconds(30))
    }

    @Test func pollReturnsTheScheduledInterval() async {
        let output = OutputBox(output: "playing\nSong\nArtist\nAlbum\n200\n10\n")
        let runner = FakeScriptRunner { _ in .success(output.get()) }
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let running = Box<[ScriptablePlayer]>([.music])
        let provider = AppleScriptProvider(
            runner: runner, runningPlayers: { running.value }, loadArtwork: { _ in nil }, observeApps: false, now: { clock.value }
        )
        #expect(await provider.poll() == .milliseconds(1500))
        output.set("paused\nSong\nArtist\nAlbum\n200\n12\n")
        #expect(await provider.poll() == .seconds(5))
        clock.value = clock.value.addingTimeInterval(400) // nothing changed for a while
        #expect(await provider.poll() == .seconds(20))
        running.value = []
        let calls = runner.calls.withLock { $0 }
        #expect(await provider.poll() == .seconds(30))
        #expect(runner.calls.withLock { $0 } == calls) // no osascript without a running player
    }

    @Test func stopClearsStateSoARestartRepublishes() async {
        let runner = FakeScriptRunner { _ in .success("playing\nSong\nArtist\nAlbum\n200\n10\n") }
        let sleeper = RecordingSleeper()
        let provider = AppleScriptProvider(
            runner: runner, runningPlayers: { [.music] }, loadArtwork: { _ in nil }, observeApps: false, sleep: sleeper.sleep
        )
        var updates = 0
        provider.onUpdate = { _ in updates += 1 }
        provider.start()
        #expect(await eventually { updates == 1 })
        provider.stop()
        provider.kick() // ignored while stopped
        let callsAfterStop = runner.calls.withLock { $0 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(runner.calls.withLock { $0 } <= callsAfterStop + 1)
        provider.start()
        #expect(await eventually { updates == 2 })
        provider.stop()
    }
}

@MainActor
@Suite struct RestartTests {
    @Test func startStopStartWithFakeChildren() async {
        let first = FakeChild(chunks: [StreamFixture.full(StreamFixture.track)], stayOpen: true)
        let second = FakeChild(chunks: [StreamFixture.full(StreamFixture.track)], stayOpen: true)
        let launcher = FakeLauncher(children: [first, second])
        let provider = AdapterProvider(locations: locations, launcher: launcher, sleep: RecordingSleeper().sleep)
        var updates: [NowPlayingState?] = []
        provider.onUpdate = { updates.append($0) }
        provider.start()
        #expect(await eventually { updates.count == 1 })
        provider.stop()
        #expect(first.terminated)
        provider.start()
        // Same track again after a restart: republished, because stop forgot the last state.
        #expect(await eventually { updates.count == 2 })
        #expect(launcher.launched.count == 2)
        provider.stop()
        #expect(second.terminated)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(launcher.launched.count == 2)
    }

    /// Real processes: a stand-in "adapter" that records its pid, so the test can check nothing survives a stop.
    @Test func startStopStartLeavesNoRunningChild() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pids = dir.appending(path: "pids")
        let script = dir.appending(path: "fake-adapter.sh")
        try Data("""
        echo $$ >> "\(pids.path)"
        printf '{"type":"data","diff":false,"payload":{}}\\n'
        exec sleep 60
        """.utf8).write(to: script)
        let loc = AdapterLocations(perl: URL(filePath: "/bin/sh"), script: script, framework: dir.appending(path: "X.framework"))
        let provider = AdapterProvider(locations: loc)

        func recorded() -> [Int32] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        }
        func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

        provider.start()
        #expect(await eventually { recorded().count == 1 })
        provider.stop()
        let firstPID = try #require(recorded().first)
        #expect(await eventually { !alive(firstPID) })
        provider.start()
        #expect(await eventually { recorded().count == 2 })
        // The child can write its pid before the provider has handled the `.launched` event, and a stopped run
        // drops its late events by design, so wait for the count before stopping again.
        #expect(await eventually { provider.launches == 2 })
        let secondPID = recorded()[1]
        #expect(alive(secondPID))
        #expect(!alive(firstPID))
        provider.stop()
        #expect(await eventually { !alive(secondPID) })
    }
}

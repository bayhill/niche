import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

@MainActor
@Suite struct ModuleTests {
    @Test func selectionRules() {
        #expect(NowPlayingSelection.choose(adapterPassed: true, hasFallback: true, consented: false, mayPrompt: false) == .adapter)
        #expect(NowPlayingSelection.choose(adapterPassed: false, hasFallback: true, consented: false, mayPrompt: false) == .needsConnect)
        #expect(NowPlayingSelection.choose(adapterPassed: false, hasFallback: true, consented: true, mayPrompt: false) == .appleScript)
        #expect(NowPlayingSelection.choose(adapterPassed: false, hasFallback: true, consented: false, mayPrompt: true) == .appleScript)
        #expect(NowPlayingSelection.choose(adapterPassed: false, hasFallback: false, consented: true, mayPrompt: true) == .unavailable)
    }

    @Test func adapterChosenWhenSelfTestPasses() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let adapter = FakeProvider(.mediaRemote), fallback = FakeProvider(.appleScript)
        let module = NowPlayingModule(adapter: adapter, adapterSelfTest: { true }, fallback: fallback)
        await module.start(env.context(for: .nowPlaying))
        #expect(await eventually { module.activeSource == .mediaRemote })
        #expect(adapter.startCount == 1)
        #expect(fallback.startCount == 0)
        module.stop()
        #expect(adapter.stopCount == 1)
        #expect(module.phase == .idle)
    }

    @Test func fallbackWaitsForConnectThenStarts() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let adapter = FakeProvider(.mediaRemote), fallback = FakeProvider(.appleScript)
        let module = NowPlayingModule(adapter: adapter, adapterSelfTest: { false }, fallback: fallback)
        await module.start(env.context(for: .nowPlaying))
        #expect(await eventually { module.phase == .needsConnect })
        #expect(fallback.startCount == 0) // no Automation prompt without consent
        module.connect()
        #expect(module.activeSource == .appleScript)
        #expect(fallback.startCount == 1)
        #expect(env.settings.get(NowPlayingModule.automationConsent))
    }

    @Test func remembersConsentAndHonoursMayPrompt() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.automationConsent, true)
        let fallback = FakeProvider(.appleScript)
        let module = NowPlayingModule(adapter: nil, adapterSelfTest: { true }, fallback: fallback)
        await module.start(env.context(for: .nowPlaying))
        #expect(await eventually { module.activeSource == .appleScript })

        let env2 = try TestEnvironment(); defer { env2.cleanUp() }
        let fallback2 = FakeProvider(.appleScript)
        let module2 = NowPlayingModule(adapter: FakeProvider(.mediaRemote), adapterSelfTest: { false }, fallback: fallback2)
        await module2.start(env2.context(for: .nowPlaying, mayPrompt: true))
        #expect(await eventually { module2.activeSource == .appleScript })
    }

    @Test func adapterGivingUpRetestsAndRetries() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let adapter = FakeProvider(.mediaRemote), fallback = FakeProvider(.appleScript)
        let module = NowPlayingModule(adapter: adapter, adapterSelfTest: { true }, fallback: fallback)
        await module.start(env.context(for: .nowPlaying))
        #expect(await eventually { module.activeSource == .mediaRemote })
        adapter.onFailure?(.gaveUp)
        // Retest passes (stub returns true): one more stream attempt.
        #expect(await eventually { adapter.startCount == 2 && module.activeSource == .mediaRemote })
    }

    @Test func activityFollowsPlayback() async {
        let module = NowPlayingModule.sample()
        let activity = module.liveActivity
        #expect(activity?.priority == .ambient)
        #expect(activity?.module == .nowPlaying)
        #expect(activity?.trailing == .equalizer(playing: true))
        if case .image = activity?.leading {} else { Issue.record("expected artwork glyph") }
        module.send(.togglePlayPause)
        #expect(module.state?.isPlaying == false)
        #expect(module.liveActivity == nil)
        module.send(.togglePlayPause)
        #expect(module.liveActivity != nil)
    }

    @Test func activityIsStableWhileNothingVisibleChanges() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        var clock = Date(timeIntervalSince1970: 1000)
        let adapter = FakeProvider(.mediaRemote)
        let module = NowPlayingModule(adapter: adapter, adapterSelfTest: { true }, fallback: nil, now: { clock })
        await module.start(env.context(for: .nowPlaying))
        #expect(await eventually { module.activeSource == .mediaRemote })
        var state = NowPlayingState(title: "A", isPlaying: true, elapsed: 1)
        adapter.onUpdate?(state)
        let first = try #require(module.liveActivity)
        clock = clock.addingTimeInterval(30)
        state.elapsed = 31
        adapter.onUpdate?(state)
        #expect(module.liveActivity?.updatedAt == first.updatedAt)
        adapter.onUpdate?(nil)
        #expect(module.liveActivity == nil)
        #expect(module.state == nil)
    }

    @Test func activityPure() {
        #expect(NowPlayingActivity.make(nil, updatedAt: .now) == nil)
        #expect(NowPlayingActivity.make(NowPlayingState(title: "A", isPlaying: false), updatedAt: .now) == nil)
        let a = NowPlayingActivity.make(NowPlayingState(title: "A", artist: "B", isPlaying: true), updatedAt: .now)
        #expect(a?.leading == .symbol("music.note", tint: .primary))
        #expect(a?.accessibilityLabel == "Playing A by B")
    }

    @Test func requirementsAreOptionalAutomation() {
        let r = NowPlayingModule.sample().requirements
        #expect(r.map(\.kind) == [.automation(bundleID: "com.spotify.client"), .automation(bundleID: "com.apple.Music")])
        #expect(r.allSatisfy { $0.optional })
    }
}

import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Synchronization
import Testing

/// A scripted self-test that counts its runs. The last outcome repeats.
final class SelfTestStub: Sendable {
    private let runs = Mutex(0)
    private let results: Mutex<[AdapterTestOutcome]>
    init(_ results: AdapterTestOutcome...) { self.results = Mutex(results) }
    var count: Int { runs.withLock { $0 } }
    var test: @Sendable () async -> AdapterTestOutcome {
        { [self] in
            runs.withLock { $0 += 1 }
            return results.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? .failed) }
        }
    }
}

@MainActor
@Suite struct SelfTestCacheTests {
    static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    static let instant: @Sendable (Duration) async throws -> Void = { _ in await Task.yield() }

    func module(
        stub: SelfTestStub, key: String = "k", adapter: FakeProvider = FakeProvider(.mediaRemote),
        fallback: FakeProvider = FakeProvider(.appleScript), sleep: @escaping @Sendable (Duration) async throws -> Void = instant,
        now: @escaping @MainActor () -> Date = { .now }
    ) -> NowPlayingModule {
        NowPlayingModule(
            adapter: adapter, adapterSelfTest: stub.test, selfTestKey: key, verifyAfter: .seconds(15), fallback: fallback,
            now: now, sleep: sleep
        )
    }

    @Test func policy() {
        let t = Date(timeIntervalSince1970: 10_000)
        let pass = AdapterCheck(key: "k", passed: true, checkedAt: t.addingTimeInterval(-86_400 * 90))
        let fail = AdapterCheck(key: "k", passed: false, checkedAt: t.addingTimeInterval(-600))
        #expect(AdapterCheckPolicy.decide(cached: nil, key: "k", now: t) == .verify)
        #expect(AdapterCheckPolicy.decide(cached: pass, key: "k", now: t) == .usePass)
        #expect(AdapterCheckPolicy.decide(cached: pass, key: "other", now: t) == .verify)
        #expect(AdapterCheckPolicy.decide(cached: pass, key: nil, now: t) == .verify)
        #expect(AdapterCheckPolicy.decide(cached: fail, key: "k", now: t) == .useFail)
        #expect(AdapterCheckPolicy.decide(cached: fail, key: "k", now: t.addingTimeInterval(3600)) == .verify)
        // A clock that went backwards does not keep a failure alive.
        #expect(AdapterCheckPolicy.decide(cached: fail, key: "k", now: t.addingTimeInterval(-3600)) == .verify)
    }

    @Test func firstLaunchStreamsAtOnceAndARealTrackConfirmsWithoutTesting() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(.passed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, adapter: adapter, sleep: Self.never)
        await m.start(env.context(for: .nowPlaying))
        #expect(m.activeSource == .mediaRemote)
        #expect(adapter.startCount == 1)
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true))
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == true)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.key == "k")
        #expect(stub.count == 0) // no fake now-playing entry was ever published
        m.stop()
    }

    @Test func firstLaunchSilentStreamTestsOnceAndCaches() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(.passed)
        let m = module(stub: stub)
        await m.start(env.context(for: .nowPlaying))
        #expect(await eventually { env.settings.get(NowPlayingModule.adapterCheck)?.passed == true })
        #expect(stub.count == 1)
        #expect(m.activeSource == .mediaRemote)
        m.stop()
    }

    @Test func secondLaunchWithSameKeyDoesNotTest() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(.passed)
        let first = module(stub: stub)
        await first.start(env.context(for: .nowPlaying))
        #expect(await eventually { stub.count == 1 })
        first.stop() // even if this lands before the result is handled, the finished test is recorded
        #expect(await eventually { env.settings.get(NowPlayingModule.adapterCheck)?.passed == true })
        let adapter = FakeProvider(.mediaRemote)
        let second = module(stub: stub, adapter: adapter)
        await second.start(env.context(for: .nowPlaying))
        #expect(second.activeSource == .mediaRemote)
        #expect(adapter.startCount == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(stub.count == 1)
        second.stop()
    }

    @Test func changedKeyReverifies() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "26.6.1|a", passed: true, checkedAt: .now))
        let stub = SelfTestStub(.failed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, key: "26.7|a", adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        #expect(await eventually { m.phase == .needsConnect })
        #expect(stub.count == 1)
        #expect(adapter.stopCount == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.key == "26.7|a")
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == false)
    }

    @Test func recentCachedFailGoesToFallbackWithoutTesting() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: false, checkedAt: .now.addingTimeInterval(-600)))
        env.settings.set(NowPlayingModule.automationConsent, true)
        let stub = SelfTestStub(.passed)
        let adapter = FakeProvider(.mediaRemote), fallback = FakeProvider(.appleScript)
        let m = module(stub: stub, adapter: adapter, fallback: fallback)
        await m.start(env.context(for: .nowPlaying))
        #expect(m.activeSource == .appleScript)
        #expect(adapter.startCount == 0)
        #expect(stub.count == 0)
        m.checkAgain() // the manual retry
        #expect(await eventually { m.activeSource == .mediaRemote })
        #expect(stub.count == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == true)
        m.stop()
    }

    @Test func oldCachedFailIsRetried() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: false, checkedAt: .now.addingTimeInterval(-7200)))
        let stub = SelfTestStub(.passed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        #expect(adapter.startCount == 1)
        #expect(await eventually { env.settings.get(NowPlayingModule.adapterCheck)?.passed == true })
        #expect(stub.count == 1)
        m.stop()
    }

    @Test func timeoutIsUnknownAndNotCached() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(.unknown)
        let m = module(stub: stub)
        await m.start(env.context(for: .nowPlaying))
        #expect(await eventually { stub.count == 1 && !m.isChecking })
        #expect(env.settings.get(NowPlayingModule.adapterCheck) == nil)
        #expect(m.activeSource == .mediaRemote) // the stream keeps running
        m.stop()
    }

    @Test func streamGiveUpRetestsAndFailingRetestFallsBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let stub = SelfTestStub(.failed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        #expect(m.activeSource == .mediaRemote)
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { m.phase == .needsConnect })
        #expect(stub.count == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == false)
    }

    @Test func streamGiveUpWithPassingRetestRetriesOnceThenFallsBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let stub = SelfTestStub(.passed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { stub.count == 1 && adapter.startCount == 2 })
        #expect(m.activeSource == .mediaRemote)
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { stub.count == 2 && m.phase == .needsConnect })
    }

    @Test func mayPromptIsNotReusedLater() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let stub = SelfTestStub(.failed)
        let adapter = FakeProvider(.mediaRemote), fallback = FakeProvider(.appleScript)
        let m = module(stub: stub, adapter: adapter, fallback: fallback)
        await m.start(env.context(for: .nowPlaying, mayPrompt: true))
        #expect(m.activeSource == .mediaRemote)
        // Hours later the stream gives up: no click, so no Automation prompt.
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { m.phase == .needsConnect })
        #expect(fallback.startCount == 0)
    }

    @Test func stoppedModuleCheckAgainStartsNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let stub = SelfTestStub(.passed)
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: stub, adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        m.stop()
        m.checkAgain()
        #expect(await eventually { stub.count == 1 && !m.isChecking })
        #expect(adapter.startCount == 1)
        #expect(m.phase == .idle)
    }

    @Test func startStopStartRestartsTheProviderCleanly() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let adapter = FakeProvider(.mediaRemote)
        let m = module(stub: SelfTestStub(.passed), adapter: adapter)
        await m.start(env.context(for: .nowPlaying))
        adapter.onUpdate?(NowPlayingState(title: "A", isPlaying: true))
        #expect(m.liveActivity != nil)
        m.stop()
        #expect(adapter.stopCount == 1)
        #expect(m.state == nil)
        #expect(m.liveActivity == nil)
        await m.start(env.context(for: .nowPlaying))
        #expect(adapter.startCount == 2)
        #expect(m.activeSource == .mediaRemote)
        m.stop()
        #expect(adapter.stopCount == 2)
    }
}

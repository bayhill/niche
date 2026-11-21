import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Synchronization
import Testing

/// A scripted self-test that counts its runs.
final class SelfTestStub: Sendable {
    private let runs = Mutex(0)
    private let results: Mutex<[Bool]>
    init(_ results: Bool...) { self.results = Mutex(results) }
    var count: Int { runs.withLock { $0 } }
    var test: @Sendable () async -> Bool {
        { [self] in
            runs.withLock { $0 += 1 }
            return results.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? false) }
        }
    }
}

@MainActor
@Suite struct SelfTestCacheTests {
    func launch(_ env: TestEnvironment, stub: SelfTestStub, key: String, adapter: FakeProvider = FakeProvider(.mediaRemote),
                fallback: FakeProvider = FakeProvider(.appleScript)) async -> NowPlayingModule {
        let module = NowPlayingModule(adapter: adapter, adapterSelfTest: stub.test, selfTestKey: key, fallback: fallback)
        await module.start(env.context(for: .nowPlaying))
        return module
    }

    @Test func firstLaunchTestsOnceAndCaches() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(true)
        let module = await launch(env, stub: stub, key: "26.6.1|a")
        #expect(await eventually { module.activeSource == .mediaRemote })
        #expect(stub.count == 1)
        let cached = try #require(env.settings.get(NowPlayingModule.adapterCheck))
        #expect(cached.key == "26.6.1|a")
        #expect(cached.passed)
    }

    @Test func secondLaunchWithSameKeySkipsTheTest() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(true)
        let first = await launch(env, stub: stub, key: "k")
        #expect(await eventually { first.activeSource == .mediaRemote })
        first.stop()
        let adapter = FakeProvider(.mediaRemote)
        let second = await launch(env, stub: stub, key: "k", adapter: adapter)
        // Decided synchronously in start from the cache: no test, stream provider started.
        #expect(second.activeSource == .mediaRemote)
        #expect(adapter.startCount == 1)
        #expect(stub.count == 1)
    }

    @Test func changedKeyRetests() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "26.6.1|a", passed: true, checkedAt: .now))
        let stub = SelfTestStub(false)
        let module = await launch(env, stub: stub, key: "26.7|a")
        #expect(await eventually { module.phase == .needsConnect })
        #expect(stub.count == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.key == "26.7|a")
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == false)
    }

    @Test func cachedFailGoesToFallbackWithoutTesting() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: false, checkedAt: .now))
        env.settings.set(NowPlayingModule.automationConsent, true)
        let stub = SelfTestStub(true)
        let fallback = FakeProvider(.appleScript)
        let module = await launch(env, stub: stub, key: "k", fallback: fallback)
        #expect(module.activeSource == .appleScript)
        #expect(fallback.startCount == 1)
        #expect(stub.count == 0)
        // "Check again" in Settings is the way to retry.
        module.checkAgain()
        #expect(await eventually { module.activeSource == .mediaRemote })
        #expect(stub.count == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == true)
    }

    @Test func streamGiveUpRetestsAndFailingRetestFallsBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        env.settings.set(NowPlayingModule.adapterCheck, AdapterCheck(key: "k", passed: true, checkedAt: .now))
        let stub = SelfTestStub(false)
        let adapter = FakeProvider(.mediaRemote)
        let module = await launch(env, stub: stub, key: "k", adapter: adapter)
        #expect(module.activeSource == .mediaRemote)
        #expect(stub.count == 0)
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { module.phase == .needsConnect })
        #expect(stub.count == 1)
        #expect(env.settings.get(NowPlayingModule.adapterCheck)?.passed == false)
    }

    @Test func streamGiveUpWithPassingRetestRetriesOnceThenFallsBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let stub = SelfTestStub(true)
        let adapter = FakeProvider(.mediaRemote)
        let module = await launch(env, stub: stub, key: "k", adapter: adapter)
        #expect(await eventually { module.activeSource == .mediaRemote })
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { stub.count == 2 && module.activeSource == .mediaRemote })
        #expect(adapter.startCount == 2)
        adapter.onFailure?(.gaveUp)
        #expect(await eventually { stub.count == 3 && module.phase == .needsConnect })
    }
}

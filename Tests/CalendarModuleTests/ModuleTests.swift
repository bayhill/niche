@testable import CalendarModule
import Foundation
import NotchCore
import NotchCoreTesting
import Testing

@MainActor
final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

@MainActor
@Suite struct CalendarModuleTests {
    let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    func make(_ source: SampleEventSource, clock: Clock, opened: Box? = nil) -> CalendarModule {
        CalendarModule(source: source, now: { clock.now }, sleep: never, openURL: { opened?.urls.append($0) })
    }

    @Test func undeterminedDoesNotPromptWithoutPermission() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let source = SampleEventSource(access: .notDetermined, events: [event("x", start: 10)])
        let module = make(source, clock: Clock(t0))
        await module.start(env.context(for: .calendar))
        #expect(source.requestCount == 0)
        #expect(module.access == .notDetermined)
        #expect(module.meeting == nil)
        await module.connect()
        #expect(source.requestCount == 1)
        #expect(module.access == .granted)
        #expect(module.meeting?.event.id == "x")
        module.stop()
    }

    @Test func mayPromptRequestsAtStart() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let source = SampleEventSource(access: .notDetermined, events: [event("x", start: 10)])
        let module = make(source, clock: Clock(t0))
        await module.start(env.context(for: .calendar, mayPrompt: true))
        for _ in 0..<100 where module.meeting == nil { await Task.yield() }
        #expect(source.requestCount == 1)
        #expect(module.meeting?.event.id == "x")
        module.stop()
    }

    @Test func deniedShowsNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let source = SampleEventSource(access: .notDetermined, events: [event("x", start: 10)])
        source.grantOnRequest = .denied
        let opened = Box()
        let module = make(source, clock: Clock(t0), opened: opened)
        await module.start(env.context(for: .calendar))
        await module.connect()
        #expect(module.access == .denied)
        #expect(module.meeting == nil)
        #expect(module.nextRefresh == t0.addingTimeInterval(60)) // keeps checking without prompting
        #expect(module.liveActivity == nil)
        module.openPrivacySettings()
        #expect(opened.urls.first?.scheme == "x-apple.systempreferences")
        // Granted later in System Settings: picked up on the next refresh.
        source.access = .granted
        module.refresh()
        #expect(module.meeting?.event.id == "x")
        #expect(source.requestCount == 1)
        module.stop()
    }

    @Test func followsTheClockAndStoreChanges() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clock = Clock(t0)
        let source = SampleEventSource(events: [event("review", start: 20, notes: "https://meet.google.com/abc-defg-hij")])
        let module = make(source, clock: clock)
        await module.start(env.context(for: .calendar))
        #expect(module.meeting?.event.id == "review")
        #expect(module.liveActivity == nil)
        #expect(!module.isImminent)
        #expect(module.nextRefresh == t0.addingTimeInterval(60))

        clock.advance(minutes: 6)
        module.refresh()
        #expect(module.liveActivity?.trailing == .countdown(to: t0.addingTimeInterval(min(20))))
        #expect(module.isImminent)

        clock.advance(minutes: 14)
        module.refresh()
        #expect(module.meeting?.isNow == true)
        #expect(module.liveActivity?.trailing == .text("now"))

        clock.advance(minutes: 3)
        module.refresh()
        #expect(module.liveActivity == nil)
        #expect(module.meeting?.isNow == true)

        clock.advance(minutes: 8)
        module.refresh()
        #expect(module.meeting == nil)

        // EKEventStoreChanged
        source.events.append(event("added", start: 40))
        source.onChange?()
        #expect(module.meeting?.event.id == "added")
        module.stop()
        #expect(source.onChange == nil)
    }

    @Test func settingsExcludeCalendarsAndLeadTime() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let source = SampleEventSource(events: [event("home", start: 8, calendar: "home"), event("work", start: 40)])
        let module = make(source, clock: Clock(t0))
        await module.start(env.context(for: .calendar))
        #expect(module.meeting?.event.id == "home")
        #expect(module.liveActivity != nil)
        env.settings.set(CalendarModule.excludedCalendars, ["home"])
        env.settings.set(CalendarModule.leadMinutes, 5)
        module.refresh()
        #expect(module.meeting?.event.id == "work")
        #expect(module.liveActivity == nil)
        module.stop()
    }

    @Test func joinOpensTheLink() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let opened = Box()
        let source = SampleEventSource(events: [event("z", start: 5, notes: "https://acme.zoom.us/j/42")])
        let module = make(source, clock: Clock(t0), opened: opened)
        await module.start(env.context(for: .calendar))
        module.join()
        #expect(opened.urls == [URL(string: "https://acme.zoom.us/j/42")!])
        module.stop()
    }

    @Test func sampleHasAMeetingWithoutStarting() {
        let module = CalendarModule.sample()
        #expect(module.meeting?.event.title == "Design review")
        #expect(module.meeting?.link?.provider == .teams)
        #expect(module.placement == .dashboard(.leadingTop))
        #expect(module.requirements.map(\.kind) == [.calendar])
    }
}

@MainActor
final class Box {
    var urls: [URL] = []
}

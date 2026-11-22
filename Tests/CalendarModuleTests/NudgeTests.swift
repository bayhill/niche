@testable import CalendarModule
import Foundation
import NotchCore
import NotchCoreTesting
import Testing

private let zoom = "https://acme.zoom.us/j/842000000"

private func meeting(
    _ id: String, start: Double, minutes: Double = 30, title: String? = nil, location: String? = nil, notes: String? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id, title: title ?? id, start: t0.addingTimeInterval(min(start)), end: t0.addingTimeInterval(min(start + minutes)),
        location: location, notes: notes
    )
}

@Suite struct NudgeTests {
    /// Nudge for `events` at `minutes` past t0, with a lead of `lead` minutes.
    func nudge(_ events: [CalendarEvent], at minutes: Double, lead: Double = 5, answered: Set<String> = []) -> Nudge? {
        let now = t0.addingTimeInterval(min(minutes))
        return MeetingNudge.make(candidates: NextMeetingSelector.candidates(events, now: now), now: now, lead: min(lead), answered: answered)
    }

    let review = meeting("review", start: 20, title: "Design review", notes: zoom)

    @Test func windowRunsFromLeadUntilTwoMinutesAfterStart() {
        #expect(nudge([review], at: 14.99) == nil)
        #expect(nudge([review], at: 15) != nil)          // exactly start - lead
        #expect(nudge([review], at: 20) != nil)          // exactly the start
        #expect(nudge([review], at: 21.99) != nil)
        #expect(nudge([review], at: 22) == nil)          // exactly start + nowWindow
    }

    @Test func shortMeetingEndsTheWindowAtItsEnd() {
        let standup = meeting("standup", start: 20, minutes: 1)
        #expect(nudge([standup], at: 20.5) != nil)
        #expect(nudge([standup], at: 21) == nil)
        #expect(nudge([standup], at: 20)?.expiresAt == t0.addingTimeInterval(min(21)))
    }

    @Test func offWhenLeadIsZero() {
        #expect(nudge([review], at: 18, lead: 0) == nil)
        #expect(nudge([review], at: 20, lead: 0) == nil)
        #expect(nudge([review], at: 18, lead: -1) == nil)
    }

    @Test func beforeTheStart() throws {
        let n = try #require(nudge([review], at: 15))
        #expect(n.id == "calendar.nudge.review.\(Int(t0.timeIntervalSince1970) + 20 * 60)")
        #expect(n.module == .calendar)
        #expect(n.symbol == "video.circle.fill")
        #expect(n.title == "Design review")
        #expect(n.message == "Hey buddy, time to head over")
        #expect(n.countdown == t0.addingTimeInterval(min(20)))
        #expect(n.actionTitle == "Join")
        #expect(n.expiresAt == t0.addingTimeInterval(min(22)))
        #expect(n.accessibilityLabel == "Design review starts in 5 minutes. Time to head over.")
        // What is drawn is equal on every refresh before the start; only the label's minutes follow the clock.
        var later = try #require(nudge([review], at: 17.3))
        #expect(later.accessibilityLabel == "Design review starts in 3 minutes. Time to head over.")
        later.accessibilityLabel = n.accessibilityLabel
        #expect(later == n)
        #expect(nudge([review], at: 19.99)?.accessibilityLabel == "Design review starts in 1 minute. Time to head over.")
    }

    @Test func afterTheStart() throws {
        let before = try #require(nudge([review], at: 19))
        let n = try #require(nudge([review], at: 20))
        #expect(n.id == before.id)
        #expect(n.message == "Hey buddy, it has started")
        #expect(n.accessibilityLabel == "Design review has started.")
        #expect(n.countdown == before.countdown)
        #expect(n.expiresAt == before.expiresAt)
        #expect(n.actionTitle == "Join")
        #expect(nudge([review], at: 21.5) == n)
    }

    @Test func minutesInTheLabel() {
        #expect(nudge([review], at: 19.5, lead: 1)?.accessibilityLabel == "Design review starts in 1 minute. Time to head over.")
        #expect(nudge([review], at: 18.5, lead: 1.5)?.accessibilityLabel == "Design review starts in 2 minutes. Time to head over.")
        // The minutes left, not the lead: a nudge that first shows late still tells the truth.
        #expect(nudge([review], at: 10, lead: 15)?.accessibilityLabel == "Design review starts in 10 minutes. Time to head over.")
        #expect(nudge([review], at: 18.2, lead: 15)?.accessibilityLabel == "Design review starts in 2 minutes. Time to head over.")
    }

    @Test func answeredIsSkipped() throws {
        let n = try #require(nudge([review], at: 16))
        #expect(nudge([review], at: 16, answered: [n.id]) == nil)
        #expect(nudge([review], at: 21, answered: [n.id]) == nil)
        #expect(nudge([review], at: 16, answered: ["calendar.nudge.other.1"]) == n)
    }

    @Test func simultaneousMeetingsNudgeInTurn() throws {
        let a = meeting("a", start: 20, notes: zoom), b = meeting("b", start: 20)
        let first = try #require(nudge([b, a], at: 16))
        #expect(first.title == "a") // joinable first, as the selector sorts
        let second = try #require(nudge([b, a], at: 16, answered: [first.id]))
        #expect(second.title == "b")
        #expect(nudge([b, a], at: 16, answered: [first.id, second.id]) == nil)
    }

    @Test func movedMeetingGetsANewId() {
        let moved = meeting("review", start: 30, title: "Design review", notes: zoom)
        #expect(MeetingNudge.id(for: moved) != MeetingNudge.id(for: review))
        #expect(MeetingNudge.id(for: moved) == "calendar.nudge.review.\(Int(t0.timeIntervalSince1970) + 30 * 60)")
        // A dismissal of the old time does not silence the new one.
        #expect(nudge([moved], at: 26, answered: [MeetingNudge.id(for: review)]) != nil)
    }

    @Test func idUsesWholeSeconds() {
        let e = CalendarEvent(id: "x", title: "x", start: Date(timeIntervalSince1970: 1_800_000_000.75), end: t0.addingTimeInterval(3600))
        #expect(MeetingNudge.id(for: e) == "calendar.nudge.x.1800000000")
    }

    @Test func locationThatIsAPlace() {
        func message(_ location: String?) -> String? { nudge([meeting("m", start: 20, location: location)], at: 16)?.message }
        #expect(message("Room 4.12") == "Hey buddy, time to head to Room 4.12")
        #expect(message("  Room 4.12  ") == "Hey buddy, time to head to Room 4.12")
        #expect(message("Kungsgatan 1\n111 43 Stockholm\nSweden") == "Hey buddy, time to head to Kungsgatan 1")
        #expect(message("\n  \nCafe Lindgren\nUpstairs") == "Hey buddy, time to head to Cafe Lindgren")
        #expect(message("Room 4; Microsoft Teams Meeting") == "Hey buddy, time to head to Room 4")
        #expect(message("Meet at the reception") == "Hey buddy, time to head to Meet at the reception")
        let label = nudge([meeting("m", start: 20, location: "Room 4")], at: 15)?.accessibilityLabel
        #expect(label == "m starts in 5 minutes. Time to head to Room 4.")
    }

    @Test func locationNamingTheLinkedServiceIsNotAPlace() {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
        func message(_ location: String, notes: String?) -> String? {
            nudge([meeting("m", start: 20, location: location, notes: notes)], at: 16)?.message
        }
        // A Swedish Outlook writes the service's name with a local word.
        #expect(message("Microsoft Teams-möte", notes: teams) == "Hey buddy, time to head over")
        #expect(message("Room 4; Microsoft Teams-möte", notes: teams) == "Hey buddy, time to head to Room 4")
        #expect(message("Zoom-möte", notes: zoom) == "Hey buddy, time to head over")
        // Without a link for that service the words are taken as a place.
        #expect(message("Teams corner, floor 3", notes: nil) == "Hey buddy, time to head to Teams corner, floor 3")
        #expect(message("Teams corner, floor 3", notes: zoom) == "Hey buddy, time to head to Teams corner, floor 3")
    }

    @Test func locationThatIsNotAPlace() {
        func message(_ location: String?) -> String? { nudge([meeting("m", start: 20, location: location)], at: 16)?.message }
        for location in [
            nil, "", "   ", "\n \n", "Microsoft Teams Meeting", "Microsoft Teams meeting", "Zoom", "Google Meet", "Webex",
            "Teams", "Online", zoom, "https://example.com/room/4", "\(zoom)\nRoom 4",
            "Microsoft Teams Meeting; https://teams.microsoft.com/l/meetup-join/19%3a1",
        ] {
            #expect(message(location) == "Hey buddy, time to head over", "\(location ?? "nil")")
        }
    }

    @Test func emptyTitleReadsMeeting() {
        #expect(nudge([meeting("m", start: 20, title: "")], at: 16)?.title == "Meeting")
        #expect(nudge([meeting("m", start: 20, title: "  \n ")], at: 16)?.title == "Meeting")
        #expect(nudge([meeting("m", start: 20, title: "")], at: 20)?.accessibilityLabel == "Meeting has started.")
    }

    @Test func withoutALinkNoActionAndACalendarSymbol() throws {
        let n = try #require(nudge([meeting("plain", start: 20)], at: 16))
        #expect(n.actionTitle == nil)
        #expect(n.symbol == "calendar")
        let teams = try #require(nudge([meeting("t", start: 20, notes: "https://teams.microsoft.com/l/meetup-join/19%3a1")], at: 16))
        #expect(teams.actionTitle == "Join")
        #expect(teams.symbol == "person.2.fill")
    }

    @Test func scheduleWakesForTheNudge() {
        let c = NextMeetingSelector.candidates([review], now: t0)
        // Wing lead 15 (at 5), nudge lead 3 (at 17).
        let at10 = t0.addingTimeInterval(min(10))
        #expect(CalendarSchedule.nextRefresh(after: at10, candidates: c, lead: min(15), nudgeLead: min(3), maxInterval: 3600)
            == t0.addingTimeInterval(min(17)))
        // Without a nudge lead the next boundary is the start, as before.
        #expect(CalendarSchedule.nextRefresh(after: at10, candidates: c, lead: min(15), maxInterval: 3600) == t0.addingTimeInterval(min(20)))
        #expect(CalendarSchedule.nextRefresh(after: at10, candidates: c, lead: min(15), nudgeLead: 0, maxInterval: 3600)
            == t0.addingTimeInterval(min(20)))
    }
}

@MainActor
@Suite struct NudgeModuleTests {
    let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    func make(_ source: SampleEventSource, clock: Clock, opened: Box? = nil) -> CalendarModule {
        CalendarModule(source: source, now: { clock.now }, sleep: never, openURL: { opened?.urls.append($0) })
    }

    @Test func appearsWhenTheClockCrossesTheLead() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clock = Clock(t0)
        let module = make(SampleEventSource(events: [meeting("review", start: 20, notes: zoom)]), clock: clock)
        await module.start(env.context(for: .calendar))
        #expect(module.nudge == nil)
        clock.advance(minutes: 14.9)
        module.refresh()
        #expect(module.nudge == nil)
        clock.advance(minutes: 0.1)
        module.refresh()
        #expect(module.nudge?.title == "review")
        #expect(module.nudge?.message == "Hey buddy, time to head over")
        clock.advance(minutes: 7)
        module.refresh()
        #expect(module.nudge == nil) // past start + nowWindow
        module.stop()
    }

    @Test func dismissClearsItForGood() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clock = Clock(t0.addingTimeInterval(min(16)))
        let opened = Box()
        let module = make(SampleEventSource(events: [meeting("review", start: 20, notes: zoom)]), clock: clock, opened: opened)
        await module.start(env.context(for: .calendar))
        let id = try #require(module.nudge?.id)
        module.dismissNudge(id)
        #expect(module.nudge == nil)
        #expect(Set(module.answered.keys) == [id])
        module.refresh()
        #expect(module.nudge == nil)
        clock.advance(minutes: 4.5) // after the start: same id, still answered
        module.refresh()
        #expect(module.nudge == nil)
        #expect(opened.urls.isEmpty)
        #expect(module.meeting?.event.id == "review") // the card is untouched
        module.stop()
    }

    @Test func actionOpensTheNudgedEventOnceAndClears() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        // "long" is the card's meeting (in progress); the nudge is for "next", which has its own link.
        let source = SampleEventSource(events: [
            meeting("long", start: -5, minutes: 120, notes: "https://meet.google.com/abc-defg-hij"),
            meeting("next", start: 3, notes: zoom),
        ])
        let opened = Box()
        let module = make(source, clock: Clock(t0), opened: opened)
        await module.start(env.context(for: .calendar))
        #expect(module.meeting?.event.id == "long")
        let n = try #require(module.nudge)
        #expect(n.title == "next")
        module.performNudgeAction(n.id)
        #expect(opened.urls == [URL(string: zoom)!])
        #expect(module.nudge == nil)
        module.performNudgeAction(n.id) // already answered: nothing
        module.refresh()
        #expect(opened.urls.count == 1)
        #expect(module.nudge == nil)
        module.stop()
    }

    @Test func actionWithoutALinkOnlyClears() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let opened = Box()
        let module = make(SampleEventSource(events: [meeting("plain", start: 3)]), clock: Clock(t0), opened: opened)
        await module.start(env.context(for: .calendar))
        let id = try #require(module.nudge?.id)
        module.performNudgeAction(id)
        #expect(module.nudge == nil)
        #expect(opened.urls.isEmpty)
        module.stop()
    }

    @Test func unknownIdDoesNothing() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let opened = Box()
        let module = make(SampleEventSource(events: [meeting("review", start: 3, notes: zoom)]), clock: Clock(t0), opened: opened)
        await module.start(env.context(for: .calendar))
        let n = try #require(module.nudge)
        module.performNudgeAction("calendar.nudge.other.1")
        module.dismissNudge("calendar.nudge.other.1")
        #expect(module.nudge == n)
        #expect(module.answered.isEmpty)
        #expect(opened.urls.isEmpty)
        module.stop()
    }

    @Test func answeredIsPrunedWhenTheNudgeWouldHaveExpired() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clock = Clock(t0)
        let source = SampleEventSource(events: [meeting("short", start: 3, minutes: 10), meeting("later", start: 60)])
        let module = make(source, clock: clock)
        await module.start(env.context(for: .calendar))
        let id = try #require(module.nudge?.id)
        module.dismissNudge(id)
        #expect(Set(module.answered.keys) == [id])
        clock.advance(minutes: 4.9) // just inside "short"'s window (it ends two minutes after the start)
        module.refresh()
        #expect(Set(module.answered.keys) == [id])
        clock.advance(minutes: 0.2)
        module.refresh()
        #expect(module.answered.isEmpty)
        module.stop()
    }

    @Test func anEmptyReadDoesNotBringADismissedNudgeBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let clock = Clock(t0)
        let events = [meeting("review", start: 3)]
        let source = SampleEventSource(events: events)
        let module = make(source, clock: clock)
        await module.start(env.context(for: .calendar))
        let id = try #require(module.nudge?.id)
        module.dismissNudge(id)
        // The store momentarily returns nothing, then the same events again.
        source.events.removeAll()
        source.onChange?()
        #expect(module.nudge == nil)
        source.events = events
        source.onChange?()
        #expect(module.nudge == nil)
        #expect(Set(module.answered.keys) == [id])
        module.stop()
    }

    @Test func noAccessNoNudge() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let source = SampleEventSource(events: [meeting("review", start: 3)])
        let module = make(source, clock: Clock(t0))
        await module.start(env.context(for: .calendar))
        #expect(module.nudge != nil)
        source.access = .denied
        module.refresh()
        #expect(module.nudge == nil)
        let undetermined = make(SampleEventSource(access: .notDetermined, events: [meeting("review", start: 3)]), clock: Clock(t0))
        await undetermined.start(env.context(for: .calendar))
        #expect(undetermined.nudge == nil)
        module.stop(); undetermined.stop()
    }

    @Test func settingFollowsTheChoice() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        let module = make(SampleEventSource(events: [meeting("review", start: 8)]), clock: Clock(t0))
        await module.start(env.context(for: .calendar))
        #expect(module.nudge == nil) // default 5 minutes
        env.settings.set(CalendarModule.nudgeMinutes, 10)
        module.refresh()
        #expect(module.nudge != nil)
        #expect(module.nudge?.accessibilityLabel == "review starts in 8 minutes. Time to head over.")
        env.settings.set(CalendarModule.nudgeMinutes, 0)
        module.refresh()
        #expect(module.nudge == nil)
        #expect(module.liveActivity != nil) // the wing is a separate setting
        module.stop()
    }

    @Test func refreshIsScheduledForTheNudge() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }
        // Half a minute before the nudge boundary (10 minutes before a meeting at 30 past); the wing's boundary
        // (15 before) has passed and the once-a-minute tick is later.
        env.settings.set(CalendarModule.nudgeMinutes, 10)
        let clock = Clock(t0.addingTimeInterval(min(19.5)))
        let module = make(SampleEventSource(events: [meeting("review", start: 30)]), clock: clock)
        await module.start(env.context(for: .calendar))
        #expect(module.nudge == nil)
        #expect(module.nextRefresh == t0.addingTimeInterval(min(20)))
        module.stop()
    }

    @Test func samplePublishesANudge() throws {
        let module = CalendarModule.sample()
        let n = try #require(module.nudge)
        #expect(n.title == "Design review")
        #expect(n.message == "Hey buddy, time to head over") // its location is "Microsoft Teams Meeting"
        #expect(n.actionTitle == "Join")
        #expect(n.symbol == "person.2.fill")
        #expect(module.meeting?.event.id == "sample.review")
    }
}

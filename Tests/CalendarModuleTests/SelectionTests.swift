@testable import CalendarModule
import Foundation
import NotchCore
import Testing

let t0 = Date(timeIntervalSince1970: 1_800_000_000) // fixed "now"
func min(_ m: Double) -> TimeInterval { m * 60 }
func event(
    _ id: String, start: Double, minutes: Double = 30, allDay: Bool = false, cancelled: Bool = false, declined: Bool = false,
    calendar: String = "work", notes: String? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id, calendarID: calendar, title: id, start: t0.addingTimeInterval(min(start)), end: t0.addingTimeInterval(min(start + minutes)),
        isAllDay: allDay, isCancelled: cancelled, isDeclined: declined, notes: notes
    )
}

@Suite struct SelectionTests {
    @Test func skipsAllDayDeclinedCancelled() {
        let events = [
            event("allday", start: -60, minutes: 24 * 60, allDay: true),
            event("declined", start: 5, declined: true),
            event("cancelled", start: 10, cancelled: true),
            event("real", start: 20),
        ]
        #expect(NextMeetingSelector.select(events, now: t0)?.event.id == "real")
    }

    @Test func soonestFirstRegardlessOfInputOrder() {
        let events = [event("later", start: 90), event("sooner", start: 30), event("past", start: -60)]
        let m = NextMeetingSelector.select(events, now: t0)
        #expect(m?.event.id == "sooner")
        #expect(m?.isNow == false)
    }

    @Test func overlappingSameStartPrefersJoinable() {
        let events = [
            event("b-plain", start: 15),
            event("a-zoom", start: 15, notes: "https://acme.zoom.us/j/1"),
        ]
        let m = NextMeetingSelector.select(events, now: t0)
        #expect(m?.event.id == "a-zoom")
        #expect(m?.link?.provider == .zoom)
    }

    @Test func inProgressIsNowForTenMinutesThenMovesOn() {
        let events = [event("current", start: -3, minutes: 60), event("next", start: 30)]
        let now3 = NextMeetingSelector.select(events, now: t0)
        #expect(now3?.event.id == "current")
        #expect(now3?.isNow == true)
        // 10 minutes after the start of "current" (it began at -3).
        let later = NextMeetingSelector.select(events, now: t0.addingTimeInterval(min(7)))
        #expect(later?.event.id == "next")
        #expect(later?.isNow == false)
    }

    @Test func shortInProgressMeetingMovesOnWhenItEnds() {
        let events = [event("standup", start: -2, minutes: 5), event("next", start: 30)]
        #expect(NextMeetingSelector.select(events, now: t0)?.event.id == "standup")
        #expect(NextMeetingSelector.select(events, now: t0.addingTimeInterval(min(3)))?.event.id == "next")
    }

    @Test func overlappingInProgressAndUpcoming() {
        // Long meeting started 5 min ago, another starts in 2 min: earliest still wins until its 10-minute window ends.
        let events = [event("long", start: -5, minutes: 120), event("overlap", start: 2)]
        #expect(NextMeetingSelector.select(events, now: t0)?.event.id == "long")
        #expect(NextMeetingSelector.select(events, now: t0.addingTimeInterval(min(5)))?.event.id == "overlap")
    }

    @Test func tomorrowWithin24HoursOnly() {
        let tomorrow = event("tomorrow", start: 20 * 60)
        #expect(NextMeetingSelector.select([tomorrow], now: t0)?.event.id == "tomorrow")
        let tooFar = event("far", start: 24 * 60 + 1)
        #expect(NextMeetingSelector.select([tooFar], now: t0) == nil)
    }

    @Test func excludedCalendars() {
        let events = [event("private", start: 10, calendar: "home"), event("work", start: 40)]
        #expect(NextMeetingSelector.select(events, now: t0, excludedCalendars: ["home"])?.event.id == "work")
    }

    @Test func nothing() {
        #expect(NextMeetingSelector.select([], now: t0) == nil)
        #expect(NextMeetingSelector.select([event("over", start: -60)], now: t0) == nil)
    }
}

@Suite struct ActivityTests {
    let events = [event("review", start: 20, notes: "https://teams.microsoft.com/l/meetup-join/19%3a1")]

    func activity(at minutes: Double, lead: Double = 15) -> LiveActivity? {
        let now = t0.addingTimeInterval(min(minutes))
        return MeetingActivity.make(candidates: NextMeetingSelector.candidates(events, now: now), now: now, lead: min(lead))
    }

    @Test func outsideTheWindowNothing() {
        #expect(activity(at: 0) == nil)       // 20 min before
        #expect(activity(at: 4.9) == nil)     // just over 15 min before
        #expect(activity(at: 22) == nil)      // more than 2 min after start
        #expect(activity(at: 60) == nil)      // over
    }

    @Test func countdownFromLeadTime() throws {
        let a = try #require(activity(at: 5))
        #expect(a.priority == .passive)
        #expect(a.module == .calendar)
        #expect(a.leading == .symbol("person.2.fill", tint: .primary))
        #expect(a.trailing == .countdown(to: t0.addingTimeInterval(min(20))))
        #expect(a.expiresAt == t0.addingTimeInterval(min(20)))
        #expect(a.accessibilityLabel == "review in 15 minutes")
        // Stable across refreshes within the phase.
        #expect(activity(at: 12) == a.withTrailing(a.trailing, label: "review in 8 minutes"))
    }

    @Test func nowWithAccentForTwoMinutes() throws {
        let a = try #require(activity(at: 20))
        #expect(a.leading == .symbol("person.2.fill", tint: .accent, pulse: true))
        #expect(a.trailing == .text("now"))
        #expect(a.expiresAt == t0.addingTimeInterval(min(22)))
        #expect(activity(at: 21.9)?.trailing == .text("now"))
        #expect(activity(at: 20)?.id == activity(at: 10)?.id) // same id: morphs in place
    }

    @Test func leadTimeIsConfigurable() {
        #expect(activity(at: 12, lead: 5) == nil)
        #expect(activity(at: 16, lead: 5) != nil)
    }

    @Test func calendarSymbolWithoutLink() {
        let plain = [event("plain", start: 5)]
        let a = MeetingActivity.make(candidates: plain, now: t0, lead: min(15))
        #expect(a?.leading == .symbol("calendar", tint: .primary))
    }

    @Test func refreshScheduleHitsBoundaries() {
        let c = NextMeetingSelector.candidates(events, now: t0)
        #expect(CalendarSchedule.nextRefresh(after: t0, candidates: c, lead: min(15)) == t0.addingTimeInterval(60))
        let justBefore = t0.addingTimeInterval(min(4.5))
        #expect(CalendarSchedule.nextRefresh(after: justBefore, candidates: c, lead: min(15)) == t0.addingTimeInterval(min(5)))
        let atStart = t0.addingTimeInterval(min(20))
        #expect(CalendarSchedule.nextRefresh(after: atStart, candidates: c, lead: min(15)) == t0.addingTimeInterval(min(21)))
        #expect(CalendarSchedule.nextRefresh(after: t0, candidates: [], lead: min(15)) == t0.addingTimeInterval(60))
    }
}

@Suite struct FormatTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let locale = Locale(identifier: "en_GB")

    @Test func ranges() {
        let today = NextMeeting(event: event("a", start: 30), link: nil, isNow: false)
        // t0 is 2027-01-15 08:00 UTC.
        #expect(MeetingTimeFormat.text(for: today, now: t0, calendar: calendar, locale: locale) == "8:30 \u{2013} 9:00")
        let now = NextMeeting(event: event("b", start: -2), link: nil, isNow: true)
        #expect(MeetingTimeFormat.text(for: now, now: t0, calendar: calendar, locale: locale) == "Until 8:28")
        let tomorrow = NextMeeting(event: event("c", start: 20 * 60), link: nil, isNow: false)
        #expect(MeetingTimeFormat.text(for: tomorrow, now: t0, calendar: calendar, locale: locale) == "Tomorrow 4:00")
    }
}

extension LiveActivity {
    func withTrailing(_ glyph: ActivityGlyph?, label: String) -> LiveActivity {
        var copy = self
        copy.trailing = glyph
        copy.accessibilityLabel = label
        return copy
    }
}

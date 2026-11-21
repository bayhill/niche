import Foundation
import NotchCore

public struct NextMeeting: Sendable, Equatable {
    public var event: CalendarEvent
    public var link: MeetingLink?
    /// Already started (shown as "now" for the first minutes).
    public var isNow: Bool
    public init(event: CalendarEvent, link: MeetingLink?, isNow: Bool) { self.event = event; self.link = link; self.isNow = isNow }
}

/// Picks the meeting to show. Pure.
public enum NextMeetingSelector {
    /// Only events starting within this window count.
    public static let horizon: TimeInterval = 24 * 3600
    /// An event in progress stays the "next meeting" until this long after its start (or its end, if sooner).
    public static let inProgressWindow: TimeInterval = 10 * 60

    /// Timed, not cancelled, not declined, not over, starting within the horizon, in an included calendar;
    /// sorted by start (then joinable first, then shorter first, then title).
    public static func candidates(_ events: [CalendarEvent], now: Date, excludedCalendars: Set<String> = []) -> [CalendarEvent] {
        events
            .filter {
                !$0.isAllDay && !$0.isCancelled && !$0.isDeclined && !excludedCalendars.contains($0.calendarID)
                    && $0.end > now && $0.start < now.addingTimeInterval(horizon) && $0.end > $0.start
            }
            .map { ($0, $0.link != nil) }
            .sorted { a, b in
                if a.0.start != b.0.start { return a.0.start < b.0.start }
                if a.1 != b.1 { return a.1 }
                if a.0.end != b.0.end { return a.0.end < b.0.end }
                return a.0.title < b.0.title
            }
            .map(\.0)
    }

    public static func select(_ events: [CalendarEvent], now: Date, excludedCalendars: Set<String> = []) -> NextMeeting? {
        select(candidates: candidates(events, now: now, excludedCalendars: excludedCalendars), now: now)
    }

    /// `candidates` must come from `candidates(_:now:excludedCalendars:)`.
    public static func select(candidates: [CalendarEvent], now: Date) -> NextMeeting? {
        for event in candidates {
            if event.start > now { return NextMeeting(event: event, link: event.link, isNow: false) }
            if now < min(event.end, event.start.addingTimeInterval(inProgressWindow)) {
                return NextMeeting(event: event, link: event.link, isNow: true)
            }
        }
        return nil
    }
}

/// The wing glyph for upcoming meetings. Pure.
public enum MeetingActivity {
    /// How long after the start the wing says "now".
    public static let nowWindow: TimeInterval = 2 * 60

    /// Countdown from `lead` before the start, then "now" (accent) for `nowWindow`. `updatedAt` is the phase's start so
    /// repeated refreshes produce equal values.
    public static func make(candidates: [CalendarEvent], now: Date, lead: TimeInterval) -> LiveActivity? {
        guard let event = candidates.first(where: {
            now >= $0.start.addingTimeInterval(-lead) && now < min($0.end, $0.start.addingTimeInterval(nowWindow))
        }) else { return nil }
        let symbol = event.link?.provider.symbol ?? "calendar"
        if now < event.start {
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            return LiveActivity(
                id: "calendar.\(event.id)", module: .calendar, priority: .passive,
                leading: .symbol(symbol, tint: .primary), trailing: .countdown(to: event.start),
                expiresAt: event.start, updatedAt: event.start.addingTimeInterval(-lead),
                accessibilityLabel: "\(event.title) in \(minutes) minute\(minutes == 1 ? "" : "s")"
            )
        }
        return LiveActivity(
            id: "calendar.\(event.id)", module: .calendar, priority: .passive,
            leading: .symbol(symbol, tint: .accent, pulse: true), trailing: .text("now"),
            expiresAt: min(event.end, event.start.addingTimeInterval(nowWindow)), updatedAt: event.start,
            accessibilityLabel: "\(event.title) is starting now"
        )
    }
}

/// When the module should look again. Pure.
public enum CalendarSchedule {
    /// The next instant the card or wing could change, but at least once a minute.
    public static func nextRefresh(after now: Date, candidates: [CalendarEvent], lead: TimeInterval, maxInterval: TimeInterval = 60) -> Date {
        let boundaries = candidates.flatMap { e in
            [
                e.start.addingTimeInterval(-lead), e.start, e.start.addingTimeInterval(MeetingActivity.nowWindow),
                e.start.addingTimeInterval(NextMeetingSelector.inProgressWindow), e.end,
            ]
        }
        let next = boundaries.filter { $0 > now }.min() ?? .distantFuture
        return min(now.addingTimeInterval(maxInterval), next)
    }
}

/// "10:00 – 10:30", "Until 10:30", "Tomorrow 09:00".
public enum MeetingTimeFormat {
    public static func text(
        for meeting: NextMeeting, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style.timeZone = calendar.timeZone
        let start = meeting.event.start.formatted(style), end = meeting.event.end.formatted(style)
        if meeting.isNow { return "Until \(end)" }
        if calendar.isDate(meeting.event.start, inSameDayAs: now) { return "\(start) \u{2013} \(end)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(meeting.event.start, inSameDayAs: tomorrow) {
            return "Tomorrow \(start)"
        }
        return meeting.event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}

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

/// The nudge that makes the notch grow shortly before a meeting ("Hey buddy, time to head over"). Pure.
///
/// What is drawn is equal across refreshes within a phase (before the start, after the start). Only the accessibility
/// label changes in between, with the minutes actually left, so it is right whenever VoiceOver reads it.
public enum MeetingNudge: Sendable {
    /// Stable per meeting occurrence and start time: a meeting moved to another time nudges again.
    public static func id(for event: CalendarEvent) -> String {
        "calendar.nudge.\(event.id).\(Int(event.start.timeIntervalSince1970.rounded(.down)))"
    }

    /// The first candidate in its nudge window (`start - lead ..< min(end, start + nowWindow)`) that the user has not
    /// answered. `candidates` must come from `NextMeetingSelector.candidates`. `lead <= 0` means nudges are off.
    public static func event(candidates: [CalendarEvent], now: Date, lead: TimeInterval, answered: Set<String>) -> CalendarEvent? {
        guard lead > 0 else { return nil }
        return candidates.first { e in
            now >= e.start.addingTimeInterval(-lead) && now < expiry(of: e) && !answered.contains(id(for: e))
        }
    }

    public static func make(candidates: [CalendarEvent], now: Date, lead: TimeInterval, answered: Set<String>) -> Nudge? {
        event(candidates: candidates, now: now, lead: lead, answered: answered).map { make(for: $0, now: now) }
    }

    /// The nudge for one event, whether or not it is in its window.
    public static func make(for event: CalendarEvent, now: Date) -> Nudge {
        let link = event.link
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Meeting" : trimmed
        let message: String, label: String
        if now < event.start {
            let place = self.place(event.location, provider: link?.provider)
            let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
            message = "Hey buddy, time to head " + (place.map { "to \($0)" } ?? "over")
            label = "\(title) starts in \(minutes) minute\(minutes == 1 ? "" : "s"). Time to head \(place.map { "to \($0)" } ?? "over")."
        } else {
            message = "Hey buddy, it has started"
            label = "\(title) has started."
        }
        return Nudge(
            id: id(for: event), module: .calendar, symbol: link?.provider.symbol ?? "calendar", title: title,
            message: message, countdown: event.start, actionTitle: link == nil ? nil : "Join", expiresAt: expiry(of: event),
            accessibilityLabel: label
        )
    }

    /// After this the meeting is no longer worth a nudge: the wing's "now" window, or the end if sooner.
    public static func expiry(of event: CalendarEvent) -> Date {
        min(event.end, event.start.addingTimeInterval(MeetingActivity.nowWindow))
    }

    /// The location as a place to head to, or `nil` when it is not one: empty, a link, or only the name of the
    /// online meeting service ("Microsoft Teams Meeting"). Uses the first non-empty line; Exchange's
    /// "Room 4; Microsoft Teams Meeting" keeps only the room. `provider` is the service the meeting's link is for:
    /// a part that names it is not a place either, whatever else it says ("Microsoft Teams-möte" from a Swedish Outlook).
    public static func place(_ location: String?, provider: MeetingProvider? = nil) -> String? {
        guard let line = location?
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let parts = line.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && MeetingLinkExtractor.urls(in: $0).isEmpty && !namesProvider($0, linked: provider) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Words that, alone, make a location just the name of an online meeting service.
    static let providerWords: Set<String> = Set(
        MeetingProvider.allCases.flatMap { $0.label.lowercased().split(separator: " ").map(String.init) }
    ).union(["microsoft", "meeting", "online", "call", "video"])

    private static func namesProvider(_ text: String, linked: MeetingProvider?) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !words.isEmpty else { return false }
        if words.isSubset(of: providerWords) { return true }
        guard let linked else { return false }
        return Set(linked.label.lowercased().split(separator: " ").map(String.init)).isSubset(of: words)
    }
}

/// When the module should look again. Pure.
public enum CalendarSchedule {
    /// The next instant the card or wing could change, but at least once a minute.
    /// `nudgeLead` is the nudge's lead (`0` when nudges are off); the start itself is already a boundary.
    public static func nextRefresh(
        after now: Date, candidates: [CalendarEvent], lead: TimeInterval, nudgeLead: TimeInterval = 0, maxInterval: TimeInterval = 60
    ) -> Date {
        let boundaries = candidates.flatMap { e in
            [
                e.start.addingTimeInterval(-lead), e.start.addingTimeInterval(-max(0, nudgeLead)), e.start,
                e.start.addingTimeInterval(MeetingActivity.nowWindow),
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

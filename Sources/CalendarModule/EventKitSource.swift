import EventKit
import Foundation

/// EventKit-backed source. Creating it never prompts; only `requestAccess()` does.
@MainActor
public final class EventKitSource: EventSource {
    private lazy var store = EKEventStore()
    private var observer: (any NSObjectProtocol)?

    public var onChange: (() -> Void)? {
        didSet { observeChanges() }
    }

    public init() {}

    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .granted
        @unknown default: .denied
        }
    }

    public func requestAccess() async -> CalendarAccess {
        let store = store
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.requestFullAccessToEvents { _, _ in continuation.resume() }
        }
        if access == .granted { store.reset() }
        return access
    }

    public func calendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.map)
    }

    private static func map(_ e: EKEvent) -> CalendarEvent {
        let declined = e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
        let title = (e.title as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        return CalendarEvent(
            id: "\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))",
            calendarID: e.calendar?.calendarIdentifier ?? "", title: title, start: e.startDate, end: e.endDate,
            isAllDay: e.isAllDay, isCancelled: e.status == .canceled, isDeclined: declined,
            url: e.url, location: e.location, notes: e.hasNotes ? e.notes : nil
        )
    }

    private func observeChanges() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard onChange != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }
}

/// Fixture source: a few meetings around a reference time. Touches nothing on the system.
@MainActor
public final class SampleEventSource: EventSource {
    public var access: CalendarAccess
    public var events: [CalendarEvent]
    public var calendarList: [CalendarInfo]
    public var onChange: (() -> Void)?
    public private(set) var requestCount = 0
    /// What `requestAccess()` turns `access` into.
    public var grantOnRequest: CalendarAccess = .granted

    public init(access: CalendarAccess = .granted, events: [CalendarEvent] = [], calendars: [CalendarInfo] = []) {
        self.access = access; self.events = events; self.calendarList = calendars
    }

    public func requestAccess() async -> CalendarAccess {
        requestCount += 1
        access = grantOnRequest
        return access
    }

    public func calendars() -> [CalendarInfo] { access == .granted ? calendarList : [] }

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        return events.filter { $0.end > start && $0.start < end }
    }

    /// A Teams design review in 12 minutes, then a Meet sync and a focus block.
    public static func demo(now: Date = .now) -> SampleEventSource {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDk4%40thread.v2/0?context=%7b%22Tid%22%3a%221%22%7d"
        return SampleEventSource(
            events: [
                CalendarEvent(
                    id: "sample.review", calendarID: "work", title: "Design review", start: now.addingTimeInterval(12 * 60),
                    end: now.addingTimeInterval(42 * 60), location: "Microsoft Teams Meeting",
                    notes: "Join the meeting now <\(teams)>"
                ),
                CalendarEvent(
                    id: "sample.sync", calendarID: "work", title: "Weekly sync", start: now.addingTimeInterval(2 * 3600),
                    end: now.addingTimeInterval(2.5 * 3600), notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij"
                ),
                CalendarEvent(
                    id: "sample.focus", calendarID: "home", title: "Focus", start: now.addingTimeInterval(-3600),
                    end: now.addingTimeInterval(3600 * 5), isAllDay: true
                ),
            ],
            calendars: [
                CalendarInfo(id: "work", title: "Work", account: "Exchange"),
                CalendarInfo(id: "home", title: "Home", account: "iCloud"),
            ]
        )
    }
}

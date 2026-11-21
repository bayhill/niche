import Foundation

/// An event as the module needs it, detached from EventKit.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    /// Unique per occurrence (recurring events share an item identifier).
    public var id: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    /// The current user is an attendee and declined.
    public var isDeclined: Bool
    public var url: URL?
    public var location: String?
    public var notes: String?

    public init(
        id: String, calendarID: String = "default", title: String, start: Date, end: Date, isAllDay: Bool = false,
        isCancelled: Bool = false, isDeclined: Bool = false, url: URL? = nil, location: String? = nil, notes: String? = nil
    ) {
        self.id = id; self.calendarID = calendarID; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.isCancelled = isCancelled; self.isDeclined = isDeclined
        self.url = url; self.location = location; self.notes = notes
    }

    public var link: MeetingLink? { MeetingLinkExtractor.extract(url: url, location: location, notes: notes) }
}

public struct CalendarInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Account name ("iCloud", "Work").
    public var account: String
    public init(id: String, title: String, account: String) { self.id = id; self.title = title; self.account = account }
}

public enum CalendarAccess: Sendable, Equatable {
    case notDetermined, denied, restricted, writeOnly, granted
}

/// Where events come from. EventKit in the app, a fake in tests and fixtures.
@MainActor
public protocol EventSource: AnyObject {
    /// Current authorisation. Reading it never prompts.
    var access: CalendarAccess { get }
    /// Shows the system prompt if undetermined. Only call after the user asked for it.
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarInfo]
    /// Events overlapping `start..<end`.
    func events(from start: Date, to end: Date) -> [CalendarEvent]
    /// Called on the main actor when the store changes (`EKEventStoreChanged`).
    var onChange: (() -> Void)? { get set }
}

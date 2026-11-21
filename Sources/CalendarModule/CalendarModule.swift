import AppKit
import Foundation
import NotchCore
import Observation
import os
import SwiftUI

@MainActor
@Observable
public final class CalendarModule: NotchModule {
    /// Minutes before a meeting that the wing starts counting down.
    public static let leadMinutes = SettingsKey("calendar.leadMinutes", default: 15)
    /// Calendar identifiers the user switched off. New calendars are included by default.
    public static let excludedCalendars = SettingsKey("calendar.excludedCalendars", default: [String]())
    public static let leadChoices = [5, 10, 15, 30]

    public let id = ModuleID.calendar
    public let title = "Calendar"
    public let symbol = "calendar"
    public let placement = PanelPlacement.dashboard(.leadingBottom)
    public let requirements = [PermissionRequirement(.calendar, rationale: "Shows your next meeting and joins it with one click.")]

    public private(set) var access: CalendarAccess
    public private(set) var meeting: NextMeeting?
    public private(set) var liveActivity: LiveActivity?
    /// Join button gets the accent once the countdown has started.
    public private(set) var isImminent = false
    /// Clock reading at the last refresh, for formatting.
    public private(set) var refreshedAt: Date

    @ObservationIgnored private let source: any EventSource
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var log = Log.logger(for: .calendar)
    /// When the next scheduled refresh fires. For tests.
    @ObservationIgnored public private(set) var nextRefresh: Date?

    public init(
        source: any EventSource, now: @escaping @MainActor () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        settings: SettingsStore? = nil
    ) {
        self.source = source; self.now = now; self.sleep = sleep; self.openURL = openURL; self.settings = settings
        access = source.access
        refreshedAt = now()
    }

    public static func live() -> CalendarModule { CalendarModule(source: EventKitSource()) }

    /// Sample meetings relative to now, already loaded. No EventKit.
    public static func sample() -> CalendarModule {
        let module = CalendarModule(source: SampleEventSource.demo(), openURL: { _ in })
        module.refresh()
        return module
    }

    public var lead: TimeInterval { TimeInterval((settings?.get(Self.leadMinutes) ?? Self.leadMinutes.defaultValue) * 60) }

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        if settings == nil { settings = context.settings }
        log = context.log
        access = source.access
        // Also when not (yet) granted: refreshing re-reads the status without prompting, so access granted later in
        // System Settings shows up within a minute.
        begin()
        if access == .notDetermined, context.mayPrompt {
            // The prompt waits for the user; start must not.
            Task { [weak self] in await self?.connect() }
        }
        context.log.notice("started")
    }

    public func stop() {
        running = false
        timer?.cancel()
        timer = nil
        source.onChange = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Shows the system calendar prompt (user clicked "Connect Calendar").
    public func connect() async {
        access = await source.requestAccess()
        log.notice("calendar access: \(String(describing: self.access), privacy: .public)")
        refresh()
    }

    public func join() {
        guard let url = meeting?.link?.url else { return }
        openURL(url)
    }

    public func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { openURL(url) }
    }

    public func calendars() -> [CalendarInfo] { source.calendars() }

    private func begin() {
        source.onChange = { [weak self] in self?.refresh() }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Re-reads events and reschedules the next refresh. Called on start, store changes, wake, settings changes and timer.
    public func refresh() {
        let t = now()
        refreshedAt = t
        access = source.access
        guard access == .granted else {
            set(meeting: nil, activity: nil, imminent: false)
            if running { schedule(at: t.addingTimeInterval(60)) }
            return
        }
        let excluded = Set(settings?.get(Self.excludedCalendars) ?? [])
        let window = source.events(from: t.addingTimeInterval(-NextMeetingSelector.horizon / 2), to: t.addingTimeInterval(NextMeetingSelector.horizon))
        let candidates = NextMeetingSelector.candidates(window, now: t, excludedCalendars: excluded)
        let next = NextMeetingSelector.select(candidates: candidates, now: t)
        let activity = MeetingActivity.make(candidates: candidates, now: t, lead: lead)
        let imminent = next.map { $0.isNow || $0.event.start.timeIntervalSince(t) <= lead } ?? false
        set(meeting: next, activity: activity, imminent: imminent)
        if running { schedule(at: CalendarSchedule.nextRefresh(after: t, candidates: candidates, lead: lead)) }
    }

    private func set(meeting next: NextMeeting?, activity: LiveActivity?, imminent: Bool) {
        if next != meeting { Motion.animate(Motion.morph) { meeting = next } }
        if activity != liveActivity { liveActivity = activity }
        if imminent != isImminent { Motion.animate(Motion.quick) { isImminent = imminent } }
    }

    private func schedule(at date: Date) {
        nextRefresh = date
        timer?.cancel()
        let delay = max(0.25, date.timeIntervalSince(now()))
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(.milliseconds(Int(delay * 1000))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    public func panelView() -> AnyView { AnyView(CalendarCard(module: self)) }

    public func settingsView() -> AnyView? { AnyView(CalendarSettings(module: self, settings: settings)) }
}

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
    /// Minutes before a meeting that the notch grows by itself to say it is time to go. 0 is off.
    public static let nudgeMinutes = SettingsKey("calendar.nudgeMinutes", default: 5)
    public static let nudgeChoices = [0, 2, 5, 10, 15]
    /// Joining a meeting pauses whatever is playing.
    public static let pauseOnJoin = SettingsKey("calendar.pauseOnJoin", default: true)

    public let id = ModuleID.calendar
    public let title = "Calendar"
    public let symbol = "calendar"
    public let placement = PanelPlacement.dashboard(.leadingTop)
    public let requirements = [PermissionRequirement(.calendar, rationale: "Shows the next meeting beside the notch and joins it with one click.")]

    public private(set) var access: CalendarAccess
    public private(set) var meeting: NextMeeting?
    public private(set) var liveActivity: LiveActivity?
    public private(set) var nudge: Nudge?
    /// Join button gets the accent once the countdown has started.
    public private(set) var isImminent = false
    /// Clock reading at the last refresh, for formatting.
    public private(set) var refreshedAt: Date

    @ObservationIgnored private let source: any EventSource
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    /// Whether an app is installed for a meeting's app link (`MeetingLink.appURL`).
    @ObservationIgnored private let canOpenInApp: @MainActor (URL) -> Bool
    @ObservationIgnored private var services: AppServices?
    @ObservationIgnored private var settings: SettingsStore?
    /// Overrides the `nudgeMinutes` setting (the sample uses it so its meeting 12 minutes away nudges).
    @ObservationIgnored private let nudgeLeadOverride: TimeInterval?
    /// Nudge ids the user acted on or dismissed, with the instant each nudge would have expired. In memory only.
    /// Pruned by that instant rather than by what the store currently returns, so a momentarily empty read
    /// (EventKit resetting) cannot bring an answered nudge back.
    @ObservationIgnored private(set) var answered: [String: Date] = [:]
    /// The event behind `nudge`, for its link.
    @ObservationIgnored private var nudgedEvent: CalendarEvent?
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
        canOpenInApp: @escaping @MainActor (URL) -> Bool = { _ in false },
        settings: SettingsStore? = nil, nudgeLead: TimeInterval? = nil
    ) {
        self.source = source; self.now = now; self.sleep = sleep; self.openURL = openURL; self.settings = settings
        self.canOpenInApp = canOpenInApp
        nudgeLeadOverride = nudgeLead
        access = source.access
        refreshedAt = now()
    }

    public static func live() -> CalendarModule {
        CalendarModule(source: EventKitSource(), canOpenInApp: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil })
    }

    /// Sample meetings relative to now, already loaded. No EventKit. Nudges 15 minutes ahead whatever the setting
    /// says and whether or not the meeting is a call, so the design review 12 minutes away shows a nudge.
    public static func sample() -> CalendarModule {
        let module = CalendarModule(source: SampleEventSource.demo(), openURL: { _ in }, nudgeLead: 15 * 60)
        module.refresh()
        return module
    }

    public var lead: TimeInterval { TimeInterval((settings?.get(Self.leadMinutes) ?? Self.leadMinutes.defaultValue) * 60) }
    /// How long before a meeting the nudge appears; 0 when off.
    public var nudgeLead: TimeInterval {
        nudgeLeadOverride ?? TimeInterval((settings?.get(Self.nudgeMinutes) ?? Self.nudgeMinutes.defaultValue) * 60)
    }
    /// The lead for a call (a link and nowhere to walk to).
    var callLead: TimeInterval { nudgeLeadOverride ?? MeetingNudge.callLead }

    public func start(_ context: ModuleContext) async {
        guard !running else { return }
        running = true
        if settings == nil { settings = context.settings }
        services = context.services
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

    /// Shows the system calendar prompt (user clicked "Connect calendar").
    public func connect() async {
        access = await source.requestAccess()
        log.notice("calendar access: \(String(describing: self.access), privacy: .public)")
        refresh()
    }

    public func join() {
        guard let link = meeting?.link else { return }
        open(link)
    }

    /// Joins: pauses what is playing (unless switched off), then opens the service's own app when it is installed and
    /// the link has an app form, else the browser link.
    private func open(_ link: MeetingLink) {
        if settings?.get(Self.pauseOnJoin) ?? Self.pauseOnJoin.defaultValue { services?.playback?.pauseIfPlaying() }
        if let app = link.appURL, canOpenInApp(app) { openURL(app) } else { openURL(link.url) }
    }

    public func performNudgeAction(_ id: Nudge.ID) {
        guard nudge?.id == id else { return }
        if let link = nudgedEvent?.link { open(link) }
        answer(id)
    }

    public func dismissNudge(_ id: Nudge.ID) {
        guard nudge?.id == id else { return }
        answer(id)
    }

    private func answer(_ id: Nudge.ID) {
        answered[id] = nudge?.expiresAt ?? now()
        refresh()
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
            nudgedEvent = nil
            set(meeting: nil, activity: nil, imminent: false, nudge: nil)
            if running { schedule(at: t.addingTimeInterval(60)) }
            return
        }
        let excluded = Set(settings?.get(Self.excludedCalendars) ?? [])
        let window = source.events(from: t.addingTimeInterval(-NextMeetingSelector.horizon / 2), to: t.addingTimeInterval(NextMeetingSelector.horizon))
        let candidates = NextMeetingSelector.candidates(window, now: t, excludedCalendars: excluded)
        let next = NextMeetingSelector.select(candidates: candidates, now: t)
        let activity = MeetingActivity.make(candidates: candidates, now: t, lead: lead)
        let imminent = next.map { $0.isNow || $0.event.start.timeIntervalSince(t) <= lead } ?? false
        let nudgeLead = nudgeLead
        answered = answered.filter { $0.value > t }
        let callLead = callLead
        let nudged = MeetingNudge.event(candidates: candidates, now: t, lead: nudgeLead, callLead: callLead, answered: Set(answered.keys))
        nudgedEvent = nudged
        set(meeting: next, activity: activity, imminent: imminent, nudge: nudged.map { MeetingNudge.make(for: $0, now: t, among: candidates) })
        if running { schedule(at: CalendarSchedule.nextRefresh(after: t, candidates: candidates, lead: lead, nudgeLead: nudgeLead, callLead: callLead)) }
    }

    private func set(meeting next: NextMeeting?, activity: LiveActivity?, imminent: Bool, nudge newNudge: Nudge?) {
        if next != meeting { Motion.animate(Motion.morph) { meeting = next } }
        if activity != liveActivity { liveActivity = activity }
        if newNudge != nudge { nudge = newNudge }
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

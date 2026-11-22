import NotchCore
import SwiftUI

struct CalendarCard: View {
    let module: CalendarModule

    var body: some View {
        GlassCard(spacing: Tokens.Spacing.s) {
            switch module.access {
            case .granted:
                if let meeting = module.meeting {
                    MeetingView(meeting: meeting, time: MeetingTimeFormat.text(for: meeting, now: module.refreshedAt),
                                imminent: module.isImminent, join: module.join)
                        .id(meeting.event.id)
                        .transition(.blurReplace)
                } else {
                    EmptyState(symbol: "calendar", title: "No meetings in the next 24 hours").motionAppear()
                }
            case .notDetermined:
                Prompt(message: "Next meeting and a join button", button: "Connect calendar", symbol: "calendar") {
                    Task { await module.connect() }
                }
            case .denied, .restricted, .writeOnly:
                Prompt(message: "Allow calendar access", button: "Open System Settings", symbol: nil) {
                    module.openPrivacySettings()
                }
            }
        }
        .motion(Motion.morph, value: module.meeting?.event.id)
    }
}

private struct MeetingView: View {
    let meeting: NextMeeting
    let time: String
    let imminent: Bool
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: meeting.link?.provider.symbol ?? "calendar")
                    .font(NotchTextStyle.label.font)
                    .foregroundStyle(meeting.isNow ? Tokens.Colors.accent : Tokens.Colors.textTertiary)
                    .notchHero(.calendar)
                SectionHeader("Next meeting") {
                    if meeting.isNow {
                        Text(Format.countdown(seconds: 0)).font(NotchTextStyle.numeric.font).foregroundStyle(Tokens.Colors.accent)
                    } else {
                        CountdownText(to: meeting.event.start)
                    }
                }
            }
            HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.event.title).notchStyle(.title).lineLimit(1)
                    Text(time).notchStyle(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                if meeting.link != nil {
                    GlassButton("Join", prominence: imminent ? .accent : .standard, action: join)
                        .fixedSize()
                        .help("Join on \(meeting.link?.provider.label ?? "")")
                }
            }
        }
    }
}

private struct Prompt: View {
    let message: String
    let button: String
    let symbol: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Text(message).notchStyle(.caption).lineLimit(1)
            GlassButton(button, symbol: symbol, action: action).fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAppear()
    }
}

struct CalendarSettings: View {
    let module: CalendarModule
    let settings: SettingsStore?
    @State private var calendars: [CalendarInfo] = []

    var body: some View {
        Form {
            if let settings {
                Section("Calendars") {
                    if calendars.isEmpty {
                        Text(module.access == .granted ? "No calendars" : "Connect calendar to choose calendars")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(calendars) { calendar in
                        Toggle(isOn: included(calendar.id, settings)) {
                            Text(calendar.title)
                            if !calendar.account.isEmpty { Text(calendar.account) }
                        }
                    }
                }
                Section {
                    Picker("Show beside the notch", selection: settings.binding(CalendarModule.leadMinutes)) {
                        ForEach(CalendarModule.leadChoices, id: \.self) { Text("\($0) minutes before").tag($0) }
                    }
                    Picker("Nudge before a meeting", selection: settings.binding(CalendarModule.nudgeMinutes)) {
                        ForEach(CalendarModule.nudgeChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) minutes before").tag($0) }
                    }
                } footer: {
                    Text("Calls nudge at \(Int(MeetingNudge.callLead / 60)) minutes. A meeting with a place to go uses the time above.")
                }
                Section {
                    Toggle("Pause music when joining", isOn: settings.binding(CalendarModule.pauseOnJoin))
                }
            } else {
                Text("Available once the module is running")
            }
        }
        .formStyle(.grouped)
        .onAppear { calendars = module.calendars() }
        .onChange(of: settings?.get(CalendarModule.leadMinutes)) { module.refresh() }
        .onChange(of: settings?.get(CalendarModule.nudgeMinutes)) { module.refresh() }
        .onChange(of: settings?.get(CalendarModule.excludedCalendars)) { module.refresh() }
    }

    private func included(_ id: String, _ settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { !settings.get(CalendarModule.excludedCalendars).contains(id) },
            set: { on in
                var excluded = settings.get(CalendarModule.excludedCalendars).filter { $0 != id }
                if !on { excluded.append(id) }
                settings.set(CalendarModule.excludedCalendars, excluded)
            }
        )
    }
}

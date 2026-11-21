import NotchCore
import SwiftUI

/// The half-height dashboard card (210 × 87): the two most important sessions as two-line rows, with a "+N" count
/// and, while alerts are off, one quiet bell beside the second row. No header: the rows are the content.
struct ClaudeCard: View {
    let module: ClaudeAgentsModule

    var body: some View {
        let content = SessionCardContent.make(sessions: module.sessions, alerts: module.alertsState)
        GlassCard(spacing: 0) {
            if content.rows.isEmpty {
                EmptyState(symbol: "sparkles", title: "No sessions running", compact: true)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, now: context.date, isHero: index == 0) { module.activate(session) }
                                .transition(.opacity)
                        }
                    }
                    .motion(Motion.morph, value: content.rows)
                }
                .overlay(alignment: .bottomTrailing) { CornerCluster(content: content, module: module) }
                Spacer(minLength: 0)
            }
        }
    }
}

/// "+N" and the alert bell, sitting on the second row's state line where that line leaves room.
private struct CornerCluster: View {
    let content: SessionCardContent
    let module: ClaudeAgentsModule

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if content.hiddenCount > 0 {
                Text("+\(content.hiddenCount)").notchStyle(.caption).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(content.hiddenCount) more sessions")
            }
            if content.showsEnableAlerts {
                GlassIconButton("bell.slash", label: "Enable alerts", kind: .plain, size: 18, tint: .secondary, action: module.openAlertSettings)
            }
        }
        .motion(Motion.morph, value: content.hiddenCount)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let now: Date
    let isHero: Bool
    let action: () -> Void

    var body: some View {
        let state = session.state
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                dot
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                        Text(session.title).notchStyle(.body).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(SessionPresentation.elapsed(since: session.since, now: now))
                            .notchStyle(.caption).monospacedDigit().lineLimit(1).fixedSize()
                            .contentTransition(.numericText())
                    }
                    Text(SessionPresentation.stateLine(for: state)).notchStyle(.caption).lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
        // RowButtonStyle pads its hover fill; let the fill bleed into the card padding so two rows fit in 63 pt.
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
        .disabled(session.pid == nil)
        .motion(Motion.morph, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(SessionPresentation.detailLine(for: state))")
        .accessibilityHint(session.pid == nil ? "" : "Brings the app running this session to the front")
    }

    @ViewBuilder private var dot: some View {
        let status = StatusDot(SessionPresentation.tint(for: session.state), pulsing: session.state.needsUser)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
        if isHero && session.state.needsUser { status.notchHero(.claudeAgents) } else { status }
    }
}

private struct JSONPreview: View {
    let title: String
    let json: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(json).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings pane: what enabling alerts does, the exact plan, and Install / Uninstall.
struct ClaudeSettingsView: View {
    let module: ClaudeAgentsModule

    var body: some View {
        Form {
            Section("Claude Code alerts") {
                Text("Notcher shows which Claude Code sessions are running. Alerts add the moment a session needs permission or input, or finishes, beside the closed notch.")
                Text("Install adds a small Claude Code plugin, notcher-bridge. For each session event it passes the session, folder, event name, tool name and notification text to Notcher; prompts, tool input and tool output are never written. Nothing is collected while alerts are off or Notcher is not running, and nothing goes over the network.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Label(statusText, systemImage: statusSymbol).symbolRenderingMode(.multicolor)
                }
            }
            if let plan = module.plan {
                Section(module.alertsState == .on ? "Installed with" : "What install does") {
                    ForEach(Array(plan.installSteps.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)").textSelection(.enabled)
                    }
                    ForEach(plan.installCommands, id: \.display) { command in
                        Text(command.display).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    if plan.cli == nil {
                        Label("The claude command was not found. Install Claude Code first.", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Section("~/.claude/settings.json") {
                    JSONPreview(title: "Before", json: plan.settingsBefore)
                    JSONPreview(title: "After", json: plan.settingsAfter)
                    Text("Only these two keys change, after a timestamped backup. Run /reload-plugins or restart open sessions to pick up the plugin.")
                        .foregroundStyle(.secondary)
                }
                Section("Uninstall runs") {
                    ForEach(plan.uninstallCommands, id: \.display) { command in
                        Text(command.display).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section {
                if module.alertsState == .offStillRegistered {
                    Text("Alerts are off and nothing is collected, but Claude Code still lists the notcher-bridge plugin. Remove it, or turn alerts back on.")
                }
                if !module.canChangeAlerts {
                    Text("Turn the Claude module on to set up alerts.").foregroundStyle(.secondary)
                }
                HStack {
                    switch module.alertsState {
                    case .on:
                        Button("Turn off") { Task { await module.uninstallHooks() } }
                    case .offStillRegistered:
                        Button("Remove from Claude Code") { Task { await module.uninstallHooks() } }
                        Button("Turn on") { Task { await module.installHooks() } }
                    case .off, .unavailable:
                        Button("Install") { Task { await module.installHooks() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(module.alertsState == .unavailable || !module.canChangeAlerts)
                    }
                    if module.isChangingHooks { ProgressView().controlSize(.small) }
                }
                .disabled(module.isChangingHooks)
                if let result = module.lastResult {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    if !result.log.isEmpty {
                        DisclosureGroup("Details") {
                            Text(result.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { module.reloadPlan() }
    }

    private var statusText: String {
        switch module.alertsState {
        case .on: "On"
        case .off: "Off"
        case .offStillRegistered: "Off, plugin still registered in Claude Code"
        case .unavailable: "Off. Install Claude Code to turn alerts on"
        }
    }

    private var statusSymbol: String {
        switch module.alertsState {
        case .on: "checkmark.circle.fill"
        case .off: "bell.slash"
        case .offStillRegistered, .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

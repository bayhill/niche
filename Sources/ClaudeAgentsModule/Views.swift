import NotchCore
import SwiftUI

/// The dashboard card: up to four sessions, most urgent first. Clicking a row brings its host app forward.
struct ClaudeCard: View {
    let module: ClaudeAgentsModule

    var body: some View {
        let sessions = module.sessions
        let visible = Array(sessions.prefix(ClaudeAgentsModule.visibleLimit))
        let attention = sessions.contains { $0.state.needsUser }
        GlassCard(spacing: Tokens.Spacing.xs) {
            SectionHeader("Claude", symbol: "sparkles") {
                HStack(spacing: Tokens.Spacing.s) {
                    if module.hookStatus != .installed {
                        Button(action: module.openAlertSettings) {
                            Text("Enable alerts").font(NotchTextStyle.caption.font).foregroundStyle(Tokens.Colors.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Get told when a session needs your permission or input")
                    }
                    if sessions.count > visible.count {
                        Text("+\(sessions.count - visible.count)").notchStyle(.caption)
                    }
                    if attention {
                        StatusDot(.warning, pulsing: true).notchHero(.claudeAgents)
                    }
                }
            }
            if visible.isEmpty {
                EmptyState(symbol: "sparkles", title: "No Claude sessions", message: "Sessions you start appear here")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, now: context.date) { module.activate(session) }
                                .motionAppear(index)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let now: Date
    let action: () -> Void

    var body: some View {
        let state = session.state
        Button(action: action) {
            ResultRow(
                symbol: SessionPresentation.symbol(for: state), symbolTint: SessionPresentation.tint(for: state),
                title: session.title, detail: SessionPresentation.stateLine(for: state),
                trailing: SessionPresentation.elapsed(since: session.since, now: now),
                trailingTint: state.needsUser ? .warning : .secondary
            )
            .symbolEffect(.pulse, isActive: state.needsUser)
        }
        .buttonStyle(RowButtonStyle())
        // RowButtonStyle pads its hover fill; let the fill bleed into the card padding so rows keep their 30 pt.
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
        .disabled(session.pid == nil)
        .help("\(SessionPresentation.detailLine(for: state))\n\(session.cwd)")
        .accessibilityLabel("\(session.title), \(SessionPresentation.detailLine(for: state))")
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
                Text("Notcher already sees which Claude Code sessions are running. Turn on alerts to also learn the moment a session is waiting for your permission or an answer, or has just finished.")
                Text("This installs a small Claude Code plugin, notcher-bridge, that hands each session event to Notcher. It sends nothing over the network, prints nothing into your sessions, and does nothing while alerts are off.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Label(statusText, systemImage: statusSymbol).symbolRenderingMode(.multicolor)
                }
            }
            if let plan = module.plan {
                Section(module.hookStatus == .installed ? "Installed with" : "What Install does") {
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
                    Text("Only these two keys change. A timestamped backup is saved first. Open sessions pick the plugin up after /reload-plugins or a restart.")
                        .foregroundStyle(.secondary)
                }
                Section("Uninstall runs") {
                    ForEach(plan.uninstallCommands, id: \.display) { command in
                        Text(command.display).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section {
                HStack {
                    if module.hookStatus == .installed {
                        Button("Uninstall") { Task { await module.uninstallHooks() } }
                    } else {
                        Button("Install") { Task { await module.installHooks() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(module.hookStatus == .cliNotFound)
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
        switch module.hookStatus {
        case .installed: "On"
        case .notInstalled: "Off"
        case .cliNotFound: "Off: Claude Code's command-line tool was not found"
        }
    }

    private var statusSymbol: String {
        switch module.hookStatus {
        case .installed: "checkmark.circle.fill"
        case .notInstalled: "bell.slash"
        case .cliNotFound: "exclamationmark.triangle.fill"
        }
    }
}

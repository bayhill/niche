import Foundation
import NotchCore

/// How a session is drawn: symbol, tint and the short state line. Shared by the card and the live activity.
public enum SessionPresentation {
    public static func symbol(for state: SessionState) -> String {
        switch state {
        case .needsPermission: "hand.raised.fill"
        case .needsInput: "questionmark.bubble.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .idle: "moon.zzz.fill"
        }
    }

    public static func tint(for state: SessionState) -> TintRole {
        switch state {
        case .needsPermission, .needsInput: .warning
        case .working: .accent
        case .finished: .success
        case .idle: .secondary
        }
    }

    public static func stateLine(for state: SessionState) -> String {
        switch state {
        case .needsPermission: "Needs permission"
        case .needsInput: "Needs input"
        case .working: "Working"
        case .finished: "Done"
        case .idle: "Idle"
        }
    }

    /// Longer description for tooltips and accessibility: names the tool or the question when known.
    public static func detailLine(for state: SessionState) -> String {
        switch state {
        case .needsPermission(let tool?): "Asking permission to use \(tool)"
        case .needsInput(let detail?): "Needs input: \(detail)"
        default: stateLine(for: state)
        }
    }

    /// Time in the current state: "now", "4m", "1h", "3d".
    public static func elapsed(since: Date, now: Date) -> String {
        Format.age(seconds: now.timeIntervalSince(since))
    }

    /// A title cut to fit a wing: at most six characters, the last an ellipsis when shortened.
    public static func wingTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 6 ? t : String(t.prefix(5)) + "\u{2026}"
    }
}

/// The module's single live activity, derived purely from the session list.
public enum ClaudeActivity {
    /// How long the "done" confirmation stays beside the notch.
    public static let doneDuration: TimeInterval = 6
    /// Longest session title passed to a wing (the wing truncates further).
    public static let maxTitleLength = 60
    /// Longest tool name passed to a wing.
    public static let maxToolLength = 32

    /// `.attention` while any session needs the user; a short `.passive` confirmation right after a session
    /// finishes; otherwise `nil`. With `showNames`, the wings name the session and what it wants
    /// ("niche" · "Allow Bash", or the longest-waiting session · "3 sessions"); without, the activity is the
    /// original glyph-only one. The `id` depends only on the condition, so the wing animates in place.
    public static func make(for sessions: [ClaudeSession], now: Date, showNames: Bool = true) -> LiveActivity? {
        let waiting = SessionReducer.ordered(sessions.filter(\.state.needsUser))
        if let first = waiting.first {
            let allPermission = waiting.allSatisfy { if case .needsPermission = $0.state { true } else { false } }
            let symbol = allPermission ? SessionPresentation.symbol(for: .needsPermission(detail: nil))
                : SessionPresentation.symbol(for: .needsInput(detail: nil))
            var activity = LiveActivity(
                id: "claudeAgents.attention", module: .claudeAgents, priority: .attention,
                leading: .symbol(symbol, tint: .warning, pulse: true),
                updatedAt: waiting.map(\.since).max() ?? now, accessibilityLabel: ""
            )
            if showNames {
                let title = wingText(first.title, limit: maxTitleLength)
                let want = request(for: first.state)
                activity.leadingText = title
                activity.trailingText = waiting.count == 1 ? want : "\(waiting.count) sessions"
                activity.accessibilityLabel = waiting.count == 1
                    ? "\(title) is waiting: \(want)"
                    : "\(waiting.count) Claude sessions are waiting; \(title) has waited longest: \(want)"
            } else {
                activity.trailing = .text(waiting.count == 1 ? SessionPresentation.wingTitle(first.title) : "\(waiting.count)")
                activity.accessibilityLabel = waiting.count == 1
                    ? "\(first.title): \(SessionPresentation.stateLine(for: first.state))"
                    : "\(waiting.count) Claude sessions need attention"
            }
            return activity
        }
        let done = sessions.compactMap { s -> (ClaudeSession, Date)? in
            if case .finished(let at) = s.state, now.timeIntervalSince(at) < doneDuration, at <= now.addingTimeInterval(1) { return (s, at) }
            return nil
        }
        if let (session, at) = done.max(by: { $0.1 < $1.1 }) {
            var activity = LiveActivity(
                id: "claudeAgents.done", module: .claudeAgents, priority: .passive,
                leading: .symbol(SessionPresentation.symbol(for: .finished(at: at)), tint: .success),
                expiresAt: at.addingTimeInterval(doneDuration), updatedAt: at, accessibilityLabel: ""
            )
            if showNames {
                let title = wingText(session.title, limit: maxTitleLength)
                activity.leadingText = title
                activity.trailingText = "Done"
                activity.accessibilityLabel = "\(title) is done"
            } else {
                activity.trailing = .text(done.count == 1 ? SessionPresentation.wingTitle(session.title) : "\(done.count)")
                activity.accessibilityLabel = "\(session.title): done"
            }
            return activity
        }
        return nil
    }

    /// What a waiting session wants, in wing words: "Allow Bash", "Needs permission", "Needs input".
    /// The tool comes only from the hook's `tool_name`; the registry never supplies one.
    public static func request(for state: SessionState) -> String {
        switch state {
        case .needsPermission(let tool?):
            let name = wingText(tool, limit: maxToolLength)
            return name.isEmpty ? "Needs permission" : "Allow \(name)"
        case .needsPermission: return "Needs permission"
        case .needsInput: return "Needs input"
        default: return SessionPresentation.stateLine(for: state)
        }
    }

    /// One clean line: whitespace and newlines collapsed to single spaces, trimmed, capped with an ellipsis.
    public static func wingText(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(max(1, limit - 1))) + "\u{2026}"
    }
}

/// Whether alerts are on, combining the user's choice (`ClaudeAgentsModule.alertsEnabled`) with what Claude Code
/// has registered.
public enum AlertsState: Sendable, Equatable {
    /// Enabled and registered: events flow while Niche runs.
    case on
    /// Not registered in Claude Code.
    case off
    /// Switched off in Niche, but Claude Code still lists the plugin (a removal failed, or it was installed
    /// before this setting existed). Nothing is collected: the spool folder does not exist.
    case offStillRegistered
    /// Not registered and no `claude` executable to register it with.
    case unavailable

    public init(enabled: Bool, hookStatus: HookInstallStatus) {
        switch hookStatus {
        case .installed: self = enabled ? .on : .offStillRegistered
        case .notInstalled: self = .off
        case .cliNotFound: self = .unavailable
        }
    }
}

/// What the half-height card shows: the most important sessions, how many are left out, and whether the quiet
/// "Enable alerts" affordance appears (alerts not on and at least one session running).
public struct SessionCardContent: Sendable, Equatable {
    public var rows: [ClaudeSession]
    public var hiddenCount: Int
    public var showsEnableAlerts: Bool

    public static func make(sessions: [ClaudeSession], alerts: AlertsState, limit: Int = ClaudeAgentsModuleLayout.visibleRows) -> SessionCardContent {
        let ordered = SessionReducer.ordered(sessions)
        let rows = Array(ordered.prefix(max(0, limit)))
        return SessionCardContent(
            rows: rows, hiddenCount: ordered.count - rows.count,
            showsEnableAlerts: alerts != .on && !ordered.isEmpty
        )
    }
}

public enum ClaudeAgentsModuleLayout {
    /// Rows that fit the 210 × 87 `leadingBottom` card.
    public static let visibleRows = 2
}

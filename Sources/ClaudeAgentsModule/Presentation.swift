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
        case .needsInput: "Waiting for you"
        case .working: "Working"
        case .finished: "Done"
        case .idle: "Idle"
        }
    }

    /// Longer description for tooltips and accessibility: names the tool or the question when known.
    public static func detailLine(for state: SessionState) -> String {
        switch state {
        case .needsPermission(let tool?): "Asking permission to use \(tool)"
        case .needsInput(let detail?): "Waiting for you: \(detail)"
        default: stateLine(for: state)
        }
    }

    /// Time in the current state: "now", "45s", "12m", "1h 5m".
    public static func elapsed(since: Date, now: Date) -> String {
        Format.countdown(seconds: max(0, now.timeIntervalSince(since)))
    }

    /// A title cut to fit a wing (about six characters).
    public static func wingTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 7 ? t : String(t.prefix(6)) + "\u{2026}"
    }
}

/// The module's single live activity, derived purely from the session list.
public enum ClaudeActivity {
    /// How long the "done" confirmation stays beside the notch.
    public static let doneDuration: TimeInterval = 6

    /// `.attention` while any session needs the user; a short `.passive` confirmation right after a session
    /// finishes; otherwise `nil`.
    public static func make(for sessions: [ClaudeSession], now: Date) -> LiveActivity? {
        let waiting = SessionReducer.ordered(sessions.filter(\.state.needsUser))
        if let first = waiting.first {
            let allPermission = waiting.allSatisfy { if case .needsPermission = $0.state { true } else { false } }
            let symbol = allPermission ? SessionPresentation.symbol(for: .needsPermission(detail: nil))
                : SessionPresentation.symbol(for: .needsInput(detail: nil))
            let trailing = waiting.count == 1 ? SessionPresentation.wingTitle(first.title) : "\(waiting.count)"
            let label = waiting.count == 1
                ? "\(first.title): \(SessionPresentation.stateLine(for: first.state))"
                : "\(waiting.count) Claude sessions need you"
            return LiveActivity(
                id: "claudeAgents.attention", module: .claudeAgents, priority: .attention,
                leading: .symbol(symbol, tint: .warning, pulse: true), trailing: .text(trailing),
                updatedAt: waiting.map(\.since).max() ?? now, accessibilityLabel: label
            )
        }
        let done = sessions.compactMap { s -> (ClaudeSession, Date)? in
            if case .finished(let at) = s.state, now.timeIntervalSince(at) < doneDuration, at <= now.addingTimeInterval(1) { return (s, at) }
            return nil
        }
        if let (session, at) = done.max(by: { $0.1 < $1.1 }) {
            return LiveActivity(
                id: "claudeAgents.done", module: .claudeAgents, priority: .passive,
                leading: .symbol(SessionPresentation.symbol(for: .finished(at: at)), tint: .success),
                trailing: .text(done.count == 1 ? SessionPresentation.wingTitle(session.title) : "\(done.count)"),
                expiresAt: at.addingTimeInterval(doneDuration), updatedAt: at,
                accessibilityLabel: "\(session.title) is done"
            )
        }
        return nil
    }
}

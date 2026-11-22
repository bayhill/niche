import Foundation

/// A short message a module wants in front of the user right now ("time to head to the meeting").
///
/// While a nudge is pending the notch grows below the band to show it, on its own, and stays grown until the user
/// answers it (the action button or Dismiss) or it expires. It is the only thing that makes the notch grow unasked,
/// so a module publishes one only for something the user would be sorry to miss, and at most one at a time.
/// NotchUI owns the rendering so every nudge looks the same; `NudgeArbiter` picks the one on screen.
public struct Nudge: Identifiable, Equatable, Sendable {
    /// Stable per logical nudge, so updates (a changed message) animate in place. Once the user has answered an id,
    /// the module must not publish it again.
    public var id: String
    public var module: ModuleID
    /// SF Symbol name.
    public var symbol: String
    /// Main line: what it is about (the meeting's title). One line, truncated with an ellipsis.
    public var title: String
    /// Second line: what to do about it. One line, truncated with an ellipsis.
    public var message: String
    /// Optional live countdown at the trailing side (the meeting's start). Reads "now" once the date has passed.
    public var countdown: Date?
    /// Label of the one accent button ("Join"), or `nil` for none. A click calls `performNudgeAction(_:)`.
    public var actionTitle: String?
    /// After this instant the nudge is ignored even if the module has not cleared it.
    public var expiresAt: Date?
    public var accessibilityLabel: String

    public init(
        id: String, module: ModuleID, symbol: String, title: String, message: String, countdown: Date? = nil,
        actionTitle: String? = nil, expiresAt: Date? = nil, accessibilityLabel: String
    ) {
        self.id = id; self.module = module; self.symbol = symbol; self.title = title; self.message = message
        self.countdown = countdown; self.actionTitle = actionTitle; self.expiresAt = expiresAt
        self.accessibilityLabel = accessibilityLabel
    }

    /// Built-in sample for `--force-state nudge`, the playground and snapshots when no module has one.
    public static func sample(now: Date = .now) -> Nudge {
        Nudge(
            id: "sample.nudge", module: .calendar, symbol: "calendar", title: "Design review",
            message: "Hey buddy, time to head over", countdown: now.addingTimeInterval(5 * 60), actionTitle: "Join",
            accessibilityLabel: "Design review starts in 5 minutes. Time to head over."
        )
    }
}

public enum NudgeArbiter {
    /// The one nudge to show: unexpired, then the one that expires soonest (the most pressing), then the smallest id.
    /// A nudge without an expiry counts as expiring last. Nudges show over fullscreen apps too.
    public static func select(_ nudges: [Nudge], now: Date = .now) -> Nudge? {
        nudges
            .filter { nudge in nudge.expiresAt.map { $0 > now } ?? true }
            .min { a, b in
                let ea = a.expiresAt ?? .distantFuture, eb = b.expiresAt ?? .distantFuture
                if ea != eb { return ea < eb }
                return a.id < b.id
            }
    }
}

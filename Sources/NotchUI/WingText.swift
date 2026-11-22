import AppKit
import NotchCore

/// What the current activity asks of the wings: the measured width of each text line (0 for none).
public struct WingRequest: Sendable, Equatable {
    public var leadingTextWidth: CGFloat
    public var trailingTextWidth: CGFloat
    public var hasTrailingGlyph: Bool

    public init(leadingTextWidth: CGFloat = 0, trailingTextWidth: CGFloat = 0, hasTrailingGlyph: Bool = true) {
        self.leadingTextWidth = leadingTextWidth; self.trailingTextWidth = trailingTextWidth
        self.hasTrailingGlyph = hasTrailingGlyph
    }

    /// Glyphs only.
    public static let none = WingRequest()
}

/// Resolved width of each wing (activity and hover states) and whether its text line fits.
public struct WingWidths: Sendable, Equatable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var showsLeadingText: Bool
    public var showsTrailingText: Bool

    public init(leading: CGFloat, trailing: CGFloat, showsLeadingText: Bool = false, showsTrailingText: Bool = false) {
        self.leading = leading; self.trailing = trailing
        self.showsLeadingText = showsLeadingText; self.showsTrailingText = showsTrailingText
    }

    public static let glyphOnly = WingWidths(leading: PanelLayout.wingWidth, trailing: PanelLayout.wingWidth)
}

/// Sizing of the text lines in the wings beside the closed notch. Each wing sizes to its own content.
///
/// Left wing, outer edge inward: glyph column (`PanelLayout.wingWidth`), text, `innerInset` to the notch.
/// Right wing, notch outward: `innerInset`, text, glyph column (or `outerInset` when there is no trailing glyph).
public enum WingText {
    /// Gap between the text and the notch.
    public static let innerInset: CGFloat = Tokens.Spacing.s
    /// Gap between trailing text and the outer edge when there is no trailing glyph.
    public static let outerInset: CGFloat = Tokens.Spacing.m
    /// Below this much room for text (an ellipsis and a couple of letters) the line is dropped rather than shown.
    public static let minimumTextWidth: CGFloat = 24

    /// The AppKit twin of `NotchTextStyle.wing` (11 pt medium system), used only for measuring.
    public static func font() -> NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }

    /// Rendered width of one line of wing text, rounded up.
    public static func measure(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = NSAttributedString(string: text, attributes: [.font: font()]).size().width
        return (width + 1).rounded(.up)
    }

    public static func request(for activity: LiveActivity) -> WingRequest {
        WingRequest(
            leadingTextWidth: measure(activity.leadingText ?? ""), trailingTextWidth: measure(activity.trailingText ?? ""),
            hasTrailingGlyph: activity.trailing != nil
        )
    }

    /// Width one side needs to show its whole text (0 for none).
    public static func sideWidth(textWidth: CGFloat, hasGlyph: Bool) -> CGFloat {
        guard textWidth > 0 else { return 0 }
        return (hasGlyph ? PanelLayout.wingWidth : outerInset) + textWidth + innerInset
    }

    /// One wing.
    /// - Parameters:
    ///   - hardRoom: space the wing may never exceed (screen edge, fixed window).
    ///   - softRoom: space before the nearest status item; limits the text, but the glyph-only wing is kept even
    ///     when there is less.
    /// - Returns: the width (glyph-only width when there is no text or no room for it) and whether the text shows.
    public static func side(textWidth: CGFloat, hasGlyph: Bool, hardRoom: CGFloat, softRoom: CGFloat? = nil) -> (width: CGFloat, showsText: Bool) {
        let glyphOnly = max(0, min(PanelLayout.wingWidth, hardRoom))
        guard textWidth > 0 else { return (glyphOnly, false) }
        let room = min(PanelLayout.wingMaxWidth, hardRoom, softRoom ?? .infinity)
        let minimal = (hasGlyph ? PanelLayout.wingWidth : outerInset) + minimumTextWidth + innerInset
        guard room >= minimal else { return (glyphOnly, false) }
        return (min(sideWidth(textWidth: textWidth, hasGlyph: hasGlyph), room).rounded(.down), true)
    }

    public static func resolve(_ request: WingRequest, leadingRoom: CGFloat, trailingRoom: CGFloat, statusRoom: CGFloat? = nil) -> WingWidths {
        let l = side(textWidth: request.leadingTextWidth, hasGlyph: true, hardRoom: leadingRoom)
        let r = side(textWidth: request.trailingTextWidth, hasGlyph: request.hasTrailingGlyph, hardRoom: trailingRoom, softRoom: statusRoom)
        return WingWidths(leading: l.width, trailing: r.width, showsLeadingText: l.showsText, showsTrailingText: r.showsText)
    }
}

/// Keeps the right wing clear of menu-bar status items.
///
/// The left side has no equivalent: the extent of the frontmost app's menus can only be read through Accessibility,
/// which Niche does not use, so the left wing is limited only by `wingMaxWidth` and the screen edge.
public enum StatusItemClearance {
    /// `kCGStatusWindowLevel`.
    public static let statusItemLayer = 25

    /// Width the right wing's body may take before the nearest status item, keeping `PanelLayout.wingClearance`
    /// and the wing's concave ear clear. `nil` when no status item sits right of the notch on this menu bar.
    /// - Parameters:
    ///   - notch: the notch rect (AppKit global points).
    ///   - menuBar: the notch screen's menu-bar strip (AppKit global points).
    ///   - statusItems: status-item window frames (AppKit global points), any screen.
    public static func trailingRoom(notch: CGRect, menuBar: CGRect, statusItems: [CGRect]) -> CGFloat? {
        let nearest = statusItems
            .filter { $0.width > 0 && $0.height > 0 && $0.intersects(menuBar) && $0.minX >= notch.maxX - 0.5 }
            .map(\.minX)
            .min()
        return nearest.map { max(0, $0 - PanelLayout.wingClearance - Tokens.Radius.notchClosedTop - notch.maxX) }
    }
}

/// The "Click to expand Niche" line shown below the notch while it swells on hover.
public enum HoverHint {
    public static let text = "Click to expand Niche"
    /// When the activity carries files that can be dragged out of the bar.
    public static let dragText = "Drag out, or click to expand"

    public static func text(hasFiles: Bool) -> String { hasFiles ? dragText : text }
    /// Scale at the start of the swell; it grows to 1 with the shape.
    public static let startScale: CGFloat = 0.82

    /// Shown only while hovering and only when a click is what opens the panel.
    public static func isVisible(state: NotchState, openOnHover: Bool) -> Bool { state == .hover && !openOnHover }

    /// Scale for a swell progress of 0...1 (1 under Reduce Motion: fade only).
    public static func scale(progress: Double, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : startScale + (1 - startScale) * CGFloat(min(1, max(0, progress)))
    }
}

/// Telling a click on the bar from the start of a drag of the activity's files.
public struct BarPress: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Still deciding (the button is down, the pointer has not moved far enough).
        case pending
        case click
        case drag
    }

    /// Movement beyond this starts a drag.
    public static let dragThreshold: CGFloat = 4

    public let start: CGPoint
    public let hasFiles: Bool

    public init(at start: CGPoint, hasFiles: Bool) { self.start = start; self.hasFiles = hasFiles }

    /// Without files a press is a click at once, exactly as before; with files the decision waits.
    public var onPress: Outcome { hasFiles ? .pending : .click }

    public func onMove(to point: CGPoint) -> Outcome {
        guard hasFiles else { return .pending }
        let dx = point.x - start.x, dy = point.y - start.y
        return (dx * dx + dy * dy).squareRoot() > Self.dragThreshold ? .drag : .pending
    }

    /// Released without having become a drag: a click (already sent at press time when there are no files).
    public var onRelease: Outcome { hasFiles ? .click : .pending }
}

/// Keeps an activity with files on screen while it is in use, even past `expiresAt` or when the arbiter would now
/// pick another one. Activities without files are selected exactly as `ActivityArbiter` says.
public enum ActivityHold {
    /// - Parameters:
    ///   - pointerOnBar: the pointer is over the bar (activity or hover state).
    ///   - releaseAt: the pointer left the bar; the hold lasts until this instant (the leave delay).
    public static func isHolding(
        displayed: LiveActivity?, pointerOnBar: Bool, ownDragInFlight: Bool, releaseAt: NotchInstant?, now: NotchInstant
    ) -> Bool {
        guard let displayed, !displayed.files.isEmpty else { return false }
        return pointerOnBar || ownDragInFlight || releaseAt.map { now < $0 } == true
    }

    /// The held activity (its latest version if the module still publishes it), or the arbiter's choice.
    public static func select(
        _ candidates: [LiveActivity], now: Date, fullscreen: Bool, displayed: LiveActivity?, holding: Bool
    ) -> LiveActivity? {
        if holding, let displayed {
            return candidates.first { $0.id == displayed.id && !$0.files.isEmpty } ?? displayed
        }
        return ActivityArbiter.select(candidates, now: now, fullscreen: fullscreen)
    }
}

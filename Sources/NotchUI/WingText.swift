import AppKit
import NotchCore

/// Sizing of the text lines in the wings beside the closed notch.
///
/// Left wing, outer edge inward: glyph column (`PanelLayout.wingWidth`), text, `innerInset` to the notch.
/// Right wing, notch outward: `innerInset`, text, glyph column (or `outerInset` when there is no trailing glyph).
/// Both wings take the wider side's width so the shape stays symmetric, between `wingWidth` and `wingMaxWidth`.
public enum WingText {
    /// Gap between the text and the notch.
    public static let innerInset: CGFloat = Tokens.Spacing.s
    /// Gap between trailing text and the outer edge when there is no trailing glyph.
    public static let outerInset: CGFloat = Tokens.Spacing.m

    /// The AppKit twin of `NotchTextStyle.wing` (11 pt medium system), used only for measuring.
    public static func font() -> NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }

    /// Rendered width of one line of wing text, rounded up.
    public static func measure(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = NSAttributedString(string: text, attributes: [.font: font()]).size().width
        return (width + 1).rounded(.up)
    }

    /// Width one side needs for its text (0 for none).
    public static func sideWidth(textWidth: CGFloat, hasGlyph: Bool) -> CGFloat {
        guard textWidth > 0 else { return 0 }
        return (hasGlyph ? PanelLayout.wingWidth : outerInset) + textWidth + innerInset
    }

    /// The wing width for given text widths: glyph-only width without text, the wider side's need otherwise,
    /// capped at `PanelLayout.wingMaxWidth`.
    public static func width(leadingTextWidth: CGFloat, trailingTextWidth: CGFloat, hasTrailingGlyph: Bool) -> CGFloat {
        let need = max(
            sideWidth(textWidth: leadingTextWidth, hasGlyph: true),
            sideWidth(textWidth: trailingTextWidth, hasGlyph: hasTrailingGlyph)
        )
        return min(PanelLayout.wingMaxWidth, max(PanelLayout.wingWidth, need))
    }

    public static func width(for activity: LiveActivity) -> CGFloat {
        width(
            leadingTextWidth: measure(activity.leadingText ?? ""), trailingTextWidth: measure(activity.trailingText ?? ""),
            hasTrailingGlyph: activity.trailing != nil
        )
    }
}

/// The "Click to expand Notcher" line shown below the notch while it swells on hover.
public enum HoverHint {
    public static let text = "Click to expand Notcher"
    /// Scale at the start of the swell; it grows to 1 with the shape.
    public static let startScale: CGFloat = 0.82

    /// Shown only while hovering and only when a click is what opens the panel.
    public static func isVisible(state: NotchState, openOnHover: Bool) -> Bool { state == .hover && !openOnHover }

    /// Scale for a swell progress of 0...1 (1 under Reduce Motion: fade only).
    public static func scale(progress: Double, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : startScale + (1 - startScale) * CGFloat(min(1, max(0, progress)))
    }
}

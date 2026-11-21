import SwiftUI

/// The only source of colours, radii, spacing and type sizes for anything drawn in the notch.
/// Module views must not introduce their own.
public enum Tokens {
    public enum Colors {
        /// The hardware notch. Everything touching the notch line is exactly this.
        public static let notchBlack = Color.black
        public static let textPrimary = Color.white
        public static let textSecondary = Color.white.opacity(0.62)
        public static let textTertiary = Color.white.opacity(0.38)
        /// The single accent.
        public static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
        public static let success = Color(red: 0.30, green: 0.85, blue: 0.48)
        public static let warning = Color(red: 1.0, green: 0.66, blue: 0.20)
        /// Tint mixed into the panel's Liquid Glass.
        public static let glassTint = Color.black.opacity(0.55)
        /// How dark the surface stays below the black cap (0 = pure glass, 1 = black).
        public static let glassFloor = 0.30
        public static let cardFill = Color.white.opacity(0.07)
        public static let cardFillHover = Color.white.opacity(0.11)
        public static let cardStroke = Color.white.opacity(0.10)
        public static let hairline = Color.white.opacity(0.08)
    }

    public enum Radius {
        public static let card: CGFloat = 16
        public static let control: CGFloat = 10
        public static let thumbnail: CGFloat = 6
        /// Notch shape corner radii (top = the concave ears, bottom = the convex corners).
        public static let notchClosedTop: CGFloat = 6
        public static let notchClosedBottom: CGFloat = 13
        public static let notchOpenTop: CGFloat = 14
        public static let notchOpenBottom: CGFloat = 28
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
    }
}

public extension TintRole {
    var color: Color {
        switch self {
        case .primary: Tokens.Colors.textPrimary
        case .secondary: Tokens.Colors.textSecondary
        case .accent: Tokens.Colors.accent
        case .success: Tokens.Colors.success
        case .warning: Tokens.Colors.warning
        }
    }
}

/// Type scale. Use `Text(...).notchStyle(.title)`.
public enum NotchTextStyle: Sendable, CaseIterable {
    /// 13 semibold, primary. Card titles, the main line of a row.
    case title
    /// 12 regular, primary.
    case body
    /// 11 regular, secondary. Details, timestamps.
    case caption
    /// 10 semibold uppercase-tracking, tertiary. Section labels.
    case label
    /// 12 medium with monospaced digits, primary. Sizes, percentages, countdowns.
    case numeric
    /// 20 semibold rounded, primary. One hero figure per card at most.
    case display

    public var font: Font {
        switch self {
        case .title: .system(size: 13, weight: .semibold)
        case .body: .system(size: 12)
        case .caption: .system(size: 11)
        case .label: .system(size: 10, weight: .semibold)
        case .numeric: .system(size: 12, weight: .medium).monospacedDigit()
        case .display: .system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
        }
    }

    public var color: Color {
        switch self {
        case .title, .body, .numeric, .display: Tokens.Colors.textPrimary
        case .caption: Tokens.Colors.textSecondary
        case .label: Tokens.Colors.textTertiary
        }
    }
}

public extension View {
    func notchStyle(_ style: NotchTextStyle) -> some View {
        font(style.font).foregroundStyle(style.color).tracking(style == .label ? 0.6 : 0)
    }
}

/// Sizes of the notch's states, in points. The notch band (menu-bar strip, height = notch height) sits on top
/// of the content sizes given here.
public enum PanelLayout {
    /// Width of each live-activity wing beside the closed notch.
    public static let wingWidth: CGFloat = 40
    /// How much the notch swells on hover.
    public static let hoverGrowth = CGSize(width: 12, height: 6)
    /// Drop target shown while a drag is near the notch.
    public static let dropSize = CGSize(width: 420, height: 92)
    /// Expanded panel content, below the notch band.
    public static let expandedSize = CGSize(width: 680, height: 204)
    public static let contentInsets = EdgeInsets(top: 6, leading: 14, bottom: 14, trailing: 14)
    public static let gap: CGFloat = 10

    /// Size of a Home dashboard card.
    public static func cardSize(for slot: DashboardSlot) -> CGSize {
        let innerWidth = expandedSize.width - contentInsets.leading - contentInsets.trailing
        let innerHeight = expandedSize.height - contentInsets.top - contentInsets.bottom
        let column = ((innerWidth - 2 * gap) / 3).rounded(.down)
        switch slot {
        case .leadingTop, .leadingBottom: return CGSize(width: column, height: ((innerHeight - gap) / 2).rounded(.down))
        case .center, .trailing: return CGSize(width: column, height: innerHeight)
        }
    }

    /// Size available to a `.page` module.
    public static var pageSize: CGSize {
        CGSize(
            width: expandedSize.width - contentInsets.leading - contentInsets.trailing,
            height: expandedSize.height - contentInsets.top - contentInsets.bottom
        )
    }
}

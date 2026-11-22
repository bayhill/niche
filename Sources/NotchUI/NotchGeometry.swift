import CoreGraphics
import NotchCore

/// Where everything is for one state on one screen. Global rects are AppKit points (origin bottom-left of the primary
/// display); `shapeRect` is in the window's SwiftUI space (origin top-left).
public struct NotchLayout: Sendable, Equatable {
    public var state: NotchState
    /// The panel's frame. Identical for every state on a screen: only the SwiftUI shape inside it animates.
    public var windowFrame: CGRect
    /// The hardware notch (or the virtual one).
    public var notchRect: CGRect
    /// The visible shape, ears included, in window coordinates.
    public var shapeRect: CGRect
    /// The visible shape in global coordinates.
    public var visibleRect: CGRect
    /// Where the window takes mouse events (global): exactly the visible shape. Everything else passes through to the
    /// apps and menu bar below. An invisible closed virtual notch on a notchless display takes nothing: `.null`.
    public var hitRect: CGRect
    /// 0 hides the surface entirely (the closed state of a virtual notch on a notchless display).
    public var surfaceOpacity: Double
    /// Each wing's width beside the notch in the activity and hover states, after clamping, and whether its text fits.
    public var wings: WingWidths
    /// The hover swell makes room for the hint (`hoverGrowth`) rather than the compact swell.
    public var hoverHint: Bool
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    /// 0 = solid black, 1 = full Liquid Glass below the band.
    public var glassAmount: Double

    /// Height of the menu-bar band (the notch height).
    public var bandHeight: CGFloat { notchRect.height }
    /// The concave ears at the top corners.
    public var earWidth: CGFloat { topRadius }
    /// Width of the shape between the ears.
    public var bodyWidth: CGFloat { shapeRect.width - 2 * topRadius }
    /// Horizontal offset of the shape's centre from the window's centre.
    public var centerOffset: CGFloat { shapeRect.midX - windowFrame.width / 2 }
    /// Horizontal offset of the notch's centre from the shape's centre (non-zero when the wings differ).
    public var notchOffsetInShape: CGFloat { notchRect.midX - visibleRect.midX }

    /// Hit test with inclusive edges, so the pointer pinned against the top of the screen still counts.
    public func hits(_ point: CGPoint) -> Bool { !hitRect.isNull && NotchGeometry.contains(hitRect, point) }
}

public enum NotchGeometry {
    /// Room around the largest state inside the fixed window, for spring overshoot.
    public static let windowMargin: CGFloat = 36
    /// A file drag closer than this to the notch opens the drop target.
    public static let dropProximity: CGFloat = 120
    /// Extra slack around the drop target once it is open, so its edge does not flicker.
    public static let dropHysteresis: CGFloat = 16

    /// How far the body (between the ears) reaches left and right of the notch's edges.
    /// - Parameters:
    ///   - wings: resolved wing widths for the activity and hover states.
    ///   - hoverHint: the hover state shows the "Click to expand" hint and swells by `hoverGrowth`;
    ///     otherwise (open-on-hover) it only swells by `hoverGrowthCompact`.
    public static func extents(
        _ state: NotchState, notch: CGSize, hasActivity: Bool, wings: WingWidths = .glyphOnly, hoverHint: Bool = true
    ) -> (left: CGFloat, right: CGFloat) {
        let ear = Tokens.Radius.notchClosedTop
        switch state {
        case .closed: return (-ear, -ear)
        case .activity: return (wings.leading, wings.trailing)
        case .hover:
            let base = hasActivity ? (wings.leading, wings.trailing) : (-ear, -ear)
            let grow = hoverGrowth(hint: hoverHint).width / 2
            return (base.0 + grow, base.1 + grow)
        case .nudge, .drop, .expanded:
            let content = openContentSize(state).width
            let side = (max(content, notch.width + 2 * PanelLayout.wingWidth) - notch.width) / 2
            return (side, side)
        }
    }

    /// Content below the band for the open states (`.zero` for the others).
    public static func openContentSize(_ state: NotchState) -> CGSize {
        switch state {
        case .nudge: PanelLayout.nudgeSize
        case .drop: PanelLayout.dropSize
        case .expanded: PanelLayout.expandedSize
        case .closed, .activity, .hover: .zero
        }
    }

    /// Width between the ears.
    public static func bodyWidth(
        _ state: NotchState, notch: CGSize, hasActivity: Bool, wings: WingWidths = .glyphOnly, hoverHint: Bool = true
    ) -> CGFloat {
        let e = extents(state, notch: notch, hasActivity: hasActivity, wings: wings, hoverHint: hoverHint)
        return notch.width + e.left + e.right
    }

    public static func radii(_ state: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        state.isOpen
            ? (Tokens.Radius.notchOpenTop, Tokens.Radius.notchOpenBottom)
            : (Tokens.Radius.notchClosedTop, Tokens.Radius.notchClosedBottom)
    }

    /// Outer size of the visible shape, ears included.
    public static func hoverGrowth(hint: Bool) -> CGSize { hint ? PanelLayout.hoverGrowth : PanelLayout.hoverGrowthCompact }

    public static func shapeSize(
        _ state: NotchState, notch: CGSize, hasActivity: Bool, wings: WingWidths = .glyphOnly, hoverHint: Bool = true
    ) -> CGSize {
        let width = bodyWidth(state, notch: notch, hasActivity: hasActivity, wings: wings, hoverHint: hoverHint)
            + 2 * radii(state).top
        let height: CGFloat = switch state {
        case .closed, .activity: notch.height
        case .hover: notch.height + hoverGrowth(hint: hoverHint).height
        case .nudge, .drop, .expanded: notch.height + openContentSize(state).height
        }
        return CGSize(width: width, height: height)
    }

    /// The fixed panel frame: wide and tall enough for the largest state (both wings at `wingMaxWidth` included)
    /// plus `windowMargin`, centred on the notch, flush with the top of the screen and kept inside it. Its size does
    /// not matter for click-through: only `hitRect` ever takes events.
    public static func windowFrame(metrics: ScreenMetrics, notch: CGRect) -> CGRect {
        let widest = WingWidths(leading: PanelLayout.wingMaxWidth, trailing: PanelLayout.wingMaxWidth)
        let largest = NotchState.allCases.map { shapeSize($0, notch: notch.size, hasActivity: true, wings: widest) }
        let width = min(metrics.frame.width, largest.map(\.width).max()! + 2 * windowMargin)
        let height = min(metrics.frame.height, largest.map(\.height).max()! + windowMargin)
        let x = min(max(notch.midX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        return CGRect(x: x, y: metrics.frame.maxY - height, width: width, height: height)
    }

    /// Room for each wing's body: the hover shape (the widest wing state) must stay inside the screen and inside the
    /// fixed window with `windowMargin / 2` left for spring overshoot.
    public static func wingRooms(metrics: ScreenMetrics, notch: CGRect, window: CGRect) -> (left: CGFloat, right: CGFloat) {
        let extra = Tokens.Radius.notchClosedTop + max(PanelLayout.hoverGrowth.width, PanelLayout.hoverGrowthCompact.width) / 2
        let leftEdge = max(metrics.frame.minX, window.minX + windowMargin / 2)
        let rightEdge = min(metrics.frame.maxX, window.maxX - windowMargin / 2)
        return (max(0, (notch.minX - leftEdge - extra).rounded(.down)), max(0, (rightEdge - notch.maxX - extra).rounded(.down)))
    }

    /// - Parameters:
    ///   - wings: what the current activity's text asks for (`WingText.request(for:)`).
    ///   - statusRoom: room before the nearest status item right of the notch (`StatusItemClearance.trailingRoom`).
    ///   - hoverHint: false when `NotchSettings.openOnHover` is on (nothing to click, compact swell).
    public static func layout(
        metrics: ScreenMetrics, state: NotchState, hasActivity: Bool = false, wings request: WingRequest = .none,
        statusRoom: CGFloat? = nil, hoverHint: Bool = true, simulatedNotch: CGSize? = nil
    ) -> NotchLayout {
        let notch = metrics.effectiveNotchRect(simulated: simulatedNotch)
        let window = windowFrame(metrics: metrics, notch: notch)
        let rooms = wingRooms(metrics: metrics, notch: notch, window: window)
        let wings = WingText.resolve(request, leadingRoom: rooms.left, trailingRoom: rooms.right, statusRoom: statusRoom)
        let size = shapeSize(state, notch: notch.size, hasActivity: hasActivity, wings: wings, hoverHint: hoverHint)
        let r = radii(state)
        let top = metrics.frame.maxY
        // Anchored on the notch's left edge, so the notch stays pixel-aligned with the hardware whatever the wings.
        let left = extents(state, notch: notch.size, hasActivity: hasActivity, wings: wings, hoverHint: hoverHint).left
        let visible = CGRect(x: notch.minX - left - r.top, y: top - size.height, width: size.width, height: size.height)
        let shape = CGRect(x: visible.minX - window.minX, y: window.maxY - visible.maxY, width: size.width, height: size.height)
        // Without a hardware notch the closed pill would sit over real menu-bar items, so it is not drawn and claims
        // nothing; the notch there opens by hotkey, the app's menu-bar item or a drag. `--simulate-notch` keeps it.
        let passive = state == .closed && !metrics.hasNotch && simulatedNotch == nil
        // Whatever is drawn takes the pointer, and nothing else: the whole bar with both wings at their target
        // (clamped, possibly unequal) widths, the swollen bar with its hint line, or the open panel. The right wing is
        // already clamped clear of status items; a menu title under the left wing is covered by it anyway.
        let hit: CGRect = passive ? .null : visible
        return NotchLayout(
            state: state, windowFrame: window, notchRect: notch, shapeRect: shape, visibleRect: visible, hitRect: hit,
            surfaceOpacity: passive ? 0 : 1, wings: wings, hoverHint: hoverHint, topRadius: r.top, bottomRadius: r.bottom, glassAmount: state.isOpen ? 1 : 0
        )
    }

    /// The enter/exit event, if any, for a pointer at `point` given whether it was inside before. Evaluated against
    /// the target layout, so a wing growing under a resting pointer starts the dwell and one shrinking away from it
    /// ends hover at once.
    public static func pointerEvent(at point: CGPoint, layout: NotchLayout, wasInside: Bool) -> NotchEvent? {
        let inside = layout.hits(point)
        guard inside != wasInside else { return nil }
        return inside ? .pointerEntered : .pointerExited
    }

    /// Whether a file drag at `point` should show (or keep showing) the drop target.
    public static func isNearForDrop(_ point: CGPoint, layout: NotchLayout) -> Bool {
        if distance(from: point, to: layout.notchRect) <= dropProximity { return true }
        return layout.state == .drop && contains(layout.visibleRect.insetBy(dx: -dropHysteresis, dy: -dropHysteresis), point)
    }

    /// Euclidean distance from a point to a rect (0 inside).
    public static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
}

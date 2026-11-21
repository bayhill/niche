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
    /// Where the window takes mouse events (global). Everything else passes through to the apps and menu bar below.
    /// Activity wings are visual only (the notch itself is interactive), and an invisible closed virtual notch on a
    /// notchless display takes nothing: `.null`.
    public var hitRect: CGRect
    /// 0 hides the surface entirely (the closed state of a virtual notch on a notchless display).
    public var surfaceOpacity: Double
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
    /// Horizontal offset of the shape's centre from the window's centre (constant per screen).
    public var centerOffset: CGFloat { shapeRect.midX - windowFrame.width / 2 }

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

    /// Width between the ears.
    public static func bodyWidth(_ state: NotchState, notch: CGSize, hasActivity: Bool) -> CGFloat {
        let closed = notch.width - 2 * Tokens.Radius.notchClosedTop
        let activity = notch.width + 2 * PanelLayout.wingWidth
        switch state {
        case .closed: return closed
        case .activity: return activity
        case .hover: return (hasActivity ? activity : closed) + PanelLayout.hoverGrowth.width
        case .drop: return max(PanelLayout.dropSize.width, activity)
        case .expanded: return max(PanelLayout.expandedSize.width, activity)
        }
    }

    public static func radii(_ state: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        state.isOpen
            ? (Tokens.Radius.notchOpenTop, Tokens.Radius.notchOpenBottom)
            : (Tokens.Radius.notchClosedTop, Tokens.Radius.notchClosedBottom)
    }

    /// Outer size of the visible shape, ears included.
    public static func shapeSize(_ state: NotchState, notch: CGSize, hasActivity: Bool) -> CGSize {
        let width = bodyWidth(state, notch: notch, hasActivity: hasActivity) + 2 * radii(state).top
        let height: CGFloat = switch state {
        case .closed, .activity: notch.height
        case .hover: notch.height + PanelLayout.hoverGrowth.height
        case .drop: notch.height + PanelLayout.dropSize.height
        case .expanded: notch.height + PanelLayout.expandedSize.height
        }
        return CGSize(width: width, height: height)
    }

    /// The fixed panel frame: wide and tall enough for the largest state plus `windowMargin`, centred on the notch,
    /// flush with the top of the screen and kept inside it.
    public static func windowFrame(metrics: ScreenMetrics, notch: CGRect) -> CGRect {
        let largest = NotchState.allCases.map { shapeSize($0, notch: notch.size, hasActivity: true) }
        let width = min(metrics.frame.width, largest.map(\.width).max()! + 2 * windowMargin)
        let height = min(metrics.frame.height, largest.map(\.height).max()! + windowMargin)
        let x = min(max(notch.midX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        return CGRect(x: x, y: metrics.frame.maxY - height, width: width, height: height)
    }

    public static func layout(
        metrics: ScreenMetrics, state: NotchState, hasActivity: Bool = false, simulatedNotch: CGSize? = nil
    ) -> NotchLayout {
        let notch = metrics.effectiveNotchRect(simulated: simulatedNotch)
        let window = windowFrame(metrics: metrics, notch: notch)
        let size = shapeSize(state, notch: notch.size, hasActivity: hasActivity)
        let r = radii(state)
        let top = metrics.frame.maxY
        let visible = CGRect(x: notch.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let shape = CGRect(x: visible.minX - window.minX, y: window.maxY - visible.maxY, width: size.width, height: size.height)
        // Without a hardware notch the closed pill would sit over real menu-bar items, so it is not drawn and claims
        // nothing; the notch there opens by hotkey, the app's menu-bar item or a drag. `--simulate-notch` keeps it.
        let passive = state == .closed && !metrics.hasNotch && simulatedNotch == nil
        let hit: CGRect = switch state {
        case .closed: passive ? .null : notch
        case .activity: notch
        case .hover, .drop, .expanded: visible
        }
        return NotchLayout(
            state: state, windowFrame: window, notchRect: notch, shapeRect: shape, visibleRect: visible, hitRect: hit,
            surfaceOpacity: passive ? 0 : 1, topRadius: r.top, bottomRadius: r.bottom, glassAmount: state.isOpen ? 1 : 0
        )
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

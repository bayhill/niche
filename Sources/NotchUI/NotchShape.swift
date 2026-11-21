import SwiftUI

/// The notch outline: concave "ears" where the top edge meets the screen edge, straight sides, convex bottom corners.
/// Both radii animate, so the shape morphs smoothly between the hardware notch and the open panel.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius; self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        // Cubic control distance for a quarter circle.
        let k: CGFloat = 0.5523
        let left = rect.minX + t, right = rect.maxX - t

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(
            to: CGPoint(x: left, y: rect.minY + t),
            control1: CGPoint(x: rect.minX + t * k, y: rect.minY),
            control2: CGPoint(x: left, y: rect.minY + t * (1 - k))
        )
        p.addLine(to: CGPoint(x: left, y: rect.maxY - b))
        p.addCurve(
            to: CGPoint(x: left + b, y: rect.maxY),
            control1: CGPoint(x: left, y: rect.maxY - b * (1 - k)),
            control2: CGPoint(x: left + b * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: right - b, y: rect.maxY))
        p.addCurve(
            to: CGPoint(x: right, y: rect.maxY - b),
            control1: CGPoint(x: right - b * (1 - k), y: rect.maxY),
            control2: CGPoint(x: right, y: rect.maxY - b * (1 - k))
        )
        p.addLine(to: CGPoint(x: right, y: rect.minY + t))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: right, y: rect.minY + t * (1 - k)),
            control2: CGPoint(x: rect.maxX - t * k, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

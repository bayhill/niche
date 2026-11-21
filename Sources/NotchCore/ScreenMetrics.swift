import AppKit

/// The numbers needed to place the notch window, detached from `NSScreen` so geometry is testable.
/// Coordinates are AppKit global points (origin bottom-left of the primary display).
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the notch height, 0 on displays without one.
    public var safeTop: CGFloat
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu-bar strips either side of the notch.
    public var auxLeft: CGRect?
    public var auxRight: CGRect?
    public var scale: CGFloat
    public var maximumFramesPerSecond: Int

    public init(
        frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?,
        scale: CGFloat = 2, maximumFramesPerSecond: Int = 120
    ) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeTop = safeTop
        self.auxLeft = auxLeft; self.auxRight = auxRight; self.scale = scale
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }

    @MainActor
    public init(screen: NSScreen) {
        self.init(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea,
            scale: screen.backingScaleFactor, maximumFramesPerSecond: screen.maximumFramesPerSecond
        )
    }

    public var hasNotch: Bool {
        guard safeTop > 0, let l = auxLeft, let r = auxRight else { return false }
        return frame.width - l.width - r.width > 0
    }

    /// The physical notch, or `nil` on displays without one.
    public var notchRect: CGRect? {
        guard hasNotch, let l = auxLeft, let r = auxRight else { return nil }
        let width = frame.width - l.width - r.width
        return CGRect(x: frame.minX + l.width, y: frame.maxY - safeTop, width: width, height: safeTop)
    }

    /// Height of the menu bar strip; 0 when the menu bar auto-hides on a notchless display.
    public var menuBarHeight: CGFloat {
        max(safeTop, frame.maxY - visibleFrame.maxY)
    }

    /// Size used for the virtual notch on displays without a physical one.
    public static let virtualNotchSize = CGSize(width: 180, height: 24)

    /// The physical notch, or a virtual one centred at the top of the screen.
    public func effectiveNotchRect(simulated: CGSize? = nil) -> CGRect {
        if simulated == nil, let rect = notchRect { return rect }
        let size = simulated ?? Self.virtualNotchSize
        return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

import AppKit
import CoreGraphics
import NotchCore

/// One on-screen window as reported by the window server (bounds in CG space: origin top-left of the primary display).
public struct WindowSnapshot: Sendable, Equatable {
    public var ownerPID: pid_t
    public var layer: Int
    public var bounds: CGRect
    public init(ownerPID: pid_t, layer: Int, bounds: CGRect) { self.ownerPID = ownerPID; self.layer = layer; self.bounds = bounds }
}

/// Detects a fullscreen app on the notch screen from window bounds, layers and owners only. `CGWindowListCopyWindowInfo`
/// gives those without Screen Recording permission (only titles need it), so this never prompts.
///
/// Bounds alone cannot tell fullscreen from a zoomed window on a notched display: fullscreen windows stop below the
/// camera housing, exactly where a zoomed window starts. The deciding signal is the menu bar: in a fullscreen space the
/// window server's menu-bar window is not on that screen.
public enum FullscreenDetector {
    /// `kCGMainMenuWindowLevel`.
    public static let menuBarLayer = 24

    /// - Parameters:
    ///   - windows: on-screen windows in CG space (origin top-left of the primary display).
    ///   - screen: the notch screen.
    ///   - primaryHeight: height of the primary display, to convert the screen into CG space.
    public static func isFullscreen(windows: [WindowSnapshot], screen: ScreenMetrics, primaryHeight: CGFloat, ownPID: pid_t) -> Bool {
        let f = screen.frame
        let cg = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        let menuStrip = CGRect(x: cg.minX, y: cg.minY, width: cg.width, height: max(1, screen.menuBarHeight))
        let menuBarShown = windows.contains { w in
            w.ownerPID != ownPID && w.layer == menuBarLayer && w.bounds.height > 0 && w.bounds.intersects(menuStrip)
        }
        guard !menuBarShown else { return false }
        // A normal-layer window of another app spanning the screen's width down to its bottom edge, starting at the
        // top (or just below the camera housing).
        return windows.contains { w in
            w.ownerPID != ownPID && w.layer == 0
                && abs(w.bounds.minX - cg.minX) < 1 && abs(w.bounds.width - cg.width) < 1
                && abs(w.bounds.maxY - cg.maxY) < 1 && w.bounds.minY <= cg.minY + screen.safeTop + 1
        }
    }

    @MainActor
    static func current(screen: ScreenMetrics) -> Bool {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let windows = list.compactMap { info -> WindowSnapshot? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return nil }
            return WindowSnapshot(ownerPID: pid_t(pid), layer: layer, bounds: bounds)
        }
        return isFullscreen(windows: windows, screen: screen, primaryHeight: primary.frame.height, ownPID: getpid())
    }
}

/// Frame pacing statistics fed from a display link.
public struct FrameStats: Sendable, Equatable {
    public private(set) var frames = 0
    /// Vsyncs that passed without a callback.
    public private(set) var dropped = 0
    /// Longest gap between callbacks, in seconds.
    public private(set) var worst: Double = 0
    public private(set) var frameInterval: Double = 1.0 / 120
    public private(set) var lastTimestamp: Double?

    public init() {}

    /// - Parameters:
    ///   - timestamp: the display link's `timestamp`.
    ///   - frameInterval: `targetTimestamp - timestamp`, the current refresh period.
    public mutating func record(timestamp: Double, frameInterval: Double) {
        if frameInterval > 0 { self.frameInterval = frameInterval }
        if let last = lastTimestamp {
            let delta = timestamp - last
            worst = max(worst, delta)
            let missed = Int((delta / self.frameInterval).rounded()) - 1
            if missed > 0 { dropped += missed }
        }
        frames += 1
        lastTimestamp = timestamp
    }

    public mutating func resetWorst() { worst = 0 }
}

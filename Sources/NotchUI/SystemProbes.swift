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

/// Detects a fullscreen app on the notch screen from window bounds only. `CGWindowListCopyWindowInfo` gives bounds,
/// layer and owner without Screen Recording permission (only window titles need it), so this never prompts.
public enum FullscreenDetector {
    /// True when another process has a normal-layer window covering the whole screen, menu bar included.
    public static func isFullscreen(windows: [WindowSnapshot], screenFrame: CGRect, primaryHeight: CGFloat, ownPID: pid_t) -> Bool {
        let cg = CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY, width: screenFrame.width, height: screenFrame.height)
        return windows.contains { w in
            w.ownerPID != ownPID && w.layer == 0
                && abs(w.bounds.minX - cg.minX) < 1 && abs(w.bounds.minY - cg.minY) < 1
                && abs(w.bounds.width - cg.width) < 1 && abs(w.bounds.height - cg.height) < 1
        }
    }

    @MainActor
    static func current(screenFrame: CGRect) -> Bool {
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
        return isFullscreen(windows: windows, screenFrame: screenFrame, primaryHeight: primary.frame.height, ownPID: getpid())
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

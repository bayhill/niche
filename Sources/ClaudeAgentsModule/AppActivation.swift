import AppKit
import Foundation

/// Brings the app hosting a session (Terminal, iTerm, VS Code, ...) to the front.
@MainActor
public protocol SessionActivating: AnyObject {
    /// Returns whether an app was found and asked to activate.
    @discardableResult func activateHost(ofProcess pid: Int32) -> Bool
}

public enum ProcessAncestry {
    /// Walks from `pid` up through its parents and returns the first one `isApp` accepts. Stops at launchd,
    /// on a loop, or after `maxDepth` steps.
    public static func hostApp(of pid: Int32, inspector: any ProcessInspecting, maxDepth: Int = 64, isApp: (Int32) -> Bool) -> Int32? {
        var current: Int32? = pid
        var seen: Set<Int32> = []
        while let p = current, p > 1, seen.count < maxDepth, seen.insert(p).inserted {
            if isApp(p) { return p }
            current = inspector.parent(of: p)
        }
        return nil
    }
}

/// Uses `NSRunningApplication`; needs no permission. Helper processes (background-only apps) are skipped.
@MainActor
public final class HostAppActivator: SessionActivating {
    private let inspector: any ProcessInspecting
    public init(inspector: any ProcessInspecting = SystemProcessInspector()) { self.inspector = inspector }

    @discardableResult
    public func activateHost(ofProcess pid: Int32) -> Bool {
        let host = ProcessAncestry.hostApp(of: pid, inspector: inspector) { p in
            NSRunningApplication(processIdentifier: p)?.activationPolicy == .regular
        }
        guard let host, let app = NSRunningApplication(processIdentifier: host) else { return false }
        if app.activate() { return true }
        // Activation from a non-active app can be refused; asking Launch Services to open it brings it forward.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        }
        return false
    }
}

import AppKit
import Foundation

/// The app media is playing from, resolved from its bundle identifier.
public struct SourceApp: Sendable, Equatable {
    public var bundleID: String
    /// Display name ("Spotify"); `nil` when it cannot be read.
    public var name: String?
    /// "Open Spotify", or "Open app" without a name. Used for help text and the accessibility label.
    public var openLabel: String { name.map { "Open \($0)" } ?? "Open app" }

    public init(bundleID: String, name: String?) { self.bundleID = bundleID; self.name = name }
}

/// Brings a source app to the front. The primitives are injected so tests never activate or launch a real app.
@MainActor
public struct SourceAppOpener {
    public enum Result: Sendable, Equatable { case activated, launched, unavailable }

    /// Display name of a running instance, or `nil` when none runs.
    public var runningName: (String) -> String??
    /// Where the app is installed, or `nil`.
    public var appURL: (String) -> URL?
    /// Display name read from an installed app bundle.
    public var bundleName: (URL) -> String?
    /// Unhide and activate the running app with this bundle id.
    public var activate: (String) -> Void
    /// Launch (and activate) the app at this URL.
    public var launch: (URL) -> Void

    public init(
        runningName: @escaping (String) -> String??, appURL: @escaping (String) -> URL?, bundleName: @escaping (URL) -> String?,
        activate: @escaping (String) -> Void, launch: @escaping (URL) -> Void
    ) {
        self.runningName = runningName; self.appURL = appURL; self.bundleName = bundleName
        self.activate = activate; self.launch = launch
    }

    /// `nil` when the id is missing or names no running or installed app: the card is then not clickable.
    public func resolve(_ bundleID: String?) -> SourceApp? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let running = runningName(bundleID) { return SourceApp(bundleID: bundleID, name: running) }
        guard let url = appURL(bundleID) else { return nil }
        return SourceApp(bundleID: bundleID, name: bundleName(url))
    }

    /// Activates the app if it runs, otherwise launches it. Checked again at click time.
    @discardableResult
    public func open(_ app: SourceApp) -> Result {
        if runningName(app.bundleID) != nil {
            activate(app.bundleID)
            return .activated
        }
        guard let url = appURL(app.bundleID) else { return .unavailable }
        launch(url)
        return .launched
    }

    /// `NSRunningApplication` / `NSWorkspace`. Needs no permission.
    public static let live = SourceAppOpener(
        runningName: { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first.map { app -> String? in app.localizedName }
        },
        appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        bundleName: { url in
            let info = Bundle(url: url)?.infoDictionary ?? [:]
            if let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String), !name.isEmpty { return name }
            let display = FileManager.default.displayName(atPath: url.path)
            return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        },
        activate: { id in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
            app.unhide()
            app.activate()
        },
        launch: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    )

    /// Resolves nothing, so nothing is clickable (fixtures and tests).
    public static let inert = SourceAppOpener(
        runningName: { _ in nil }, appURL: { _ in nil }, bundleName: { _ in nil }, activate: { _ in }, launch: { _ in }
    )
}

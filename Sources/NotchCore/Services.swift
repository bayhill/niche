import Foundation
import Observation
import os

/// What to convert. Implemented by ConvertModule; used by Clipboard and anything else that wants a WebP.
public enum ConversionSource: Sendable, Equatable {
    /// Output goes next to the file.
    case file(URL)
    /// No file behind it; output goes to the user's Downloads folder as `<name>.webp`.
    case imageData(Data, name: String)
}

@MainActor
public protocol ImageConverting: AnyObject {
    /// Queue conversions with the current settings. Returns immediately; progress shows as a live activity.
    func convert(_ sources: [ConversionSource])
}

public enum ShelfOrigin: String, Sendable, Codable, CaseIterable {
    case dropped, converted, clipboard
}

@MainActor
public protocol ShelfAccepting: AnyObject {
    /// Add references to existing files. The shelf never copies, moves or deletes the files themselves.
    func add(_ urls: [URL], origin: ShelfOrigin)
}

@MainActor
public protocol PlaybackControlling: AnyObject {
    /// Pauses whatever is playing. Never starts playback: it does nothing when nothing is playing or nothing is known.
    func pauseIfPlaying()
}

@MainActor
public protocol NotchControlling: AnyObject {
    /// Open the panel, optionally on a module's page (`nil` = Home).
    func expand(page: ModuleID?)
    func collapse()
    func toggle()
}

/// Cross-module services, filled in by the app at launch. Modules look these up at use time, never at init,
/// and must tolerate `nil` (the providing module may be disabled).
@MainActor
@Observable
public final class AppServices {
    public var converter: (any ImageConverting)?
    public var shelf: (any ShelfAccepting)?
    public var notch: (any NotchControlling)?
    /// Implemented by Now Playing; used by Calendar when a meeting is joined.
    public var playback: (any PlaybackControlling)?
    /// Opens the Settings window, optionally on a module's pane.
    public var openSettings: ((ModuleID?) -> Void)?
    public init() {}
}

/// Filesystem roots. Injected so tests can point everything at a temporary directory.
public struct AppDirectories: Sendable, Equatable {
    /// `~/Library/Application Support/Niche` in the app.
    public var appSupport: URL
    /// `~/Library/Caches/Niche` in the app.
    public var caches: URL
    /// `~/Downloads` in the app. Destination for outputs that have no source folder.
    public var downloads: URL
    /// The user's home directory. Modules that read dotfiles (e.g. `~/.claude`) resolve them from here.
    public var home: URL

    public init(appSupport: URL, caches: URL, downloads: URL, home: URL) {
        self.appSupport = appSupport; self.caches = caches; self.downloads = downloads; self.home = home
    }

    public static var live: AppDirectories {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return AppDirectories(
            appSupport: home.appending(path: "Library/Application Support/Niche", directoryHint: .isDirectory),
            caches: home.appending(path: "Library/Caches/Niche", directoryHint: .isDirectory),
            downloads: home.appending(path: "Downloads", directoryHint: .isDirectory),
            home: home
        )
    }

    /// Everything under one root, for tests.
    public static func rooted(at root: URL) -> AppDirectories {
        AppDirectories(
            appSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory),
            downloads: root.appending(path: "Downloads", directoryHint: .isDirectory),
            home: root.appending(path: "Home", directoryHint: .isDirectory)
        )
    }
}

/// Handed to a module in `start`.
@MainActor
public final class ModuleContext {
    public let services: AppServices
    public let settings: SettingsStore
    public let directories: AppDirectories
    /// True only when the user is in onboarding/Settings and has asked to enable this module's feature.
    /// When false, a module must check permission status without triggering a system prompt.
    public let mayPrompt: Bool
    public let log: Logger

    public init(services: AppServices, settings: SettingsStore, directories: AppDirectories, mayPrompt: Bool, log: Logger) {
        self.services = services; self.settings = settings; self.directories = directories
        self.mayPrompt = mayPrompt; self.log = log
    }
}

public enum Log {
    /// The app's bundle identifier, as written in `Resources/Info.plist` (a test keeps the two equal).
    /// Also the log subsystem and the prefix for anything else that needs a reverse-DNS name.
    public static let subsystem = "dev.bayhill.niche"
    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
    public static func logger(for module: ModuleID) -> Logger { logger(module.rawValue) }
}

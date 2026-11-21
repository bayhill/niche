import Foundation
import NotchCore

/// What is playing right now, from whichever source is active.
public struct NowPlayingState: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// Decoded, downsampled artwork. Equality is identity, so an unchanged image never re-renders.
    public var artwork: SendableImage?
    public var isPlaying: Bool
    /// The app that owns playback (the parent app for helper processes, e.g. Safari for WebKit).
    public var bundleID: String?
    public var elapsed: TimeInterval?
    public var duration: TimeInterval?
    /// When `elapsed` was sampled.
    public var timestamp: Date?

    public init(
        title: String, artist: String? = nil, album: String? = nil, artwork: SendableImage? = nil, isPlaying: Bool,
        bundleID: String? = nil, elapsed: TimeInterval? = nil, duration: TimeInterval? = nil, timestamp: Date? = nil
    ) {
        self.title = title; self.artist = artist; self.album = album; self.artwork = artwork; self.isPlaying = isPlaying
        self.bundleID = bundleID; self.elapsed = elapsed; self.duration = duration; self.timestamp = timestamp
    }

    /// Identifies the track (not its play state), for transitions.
    public var trackKey: String { [title, artist ?? "", album ?? ""].joined(separator: "\u{1F}") }
}

public enum MediaCommand: Sendable, Equatable, CaseIterable {
    case togglePlayPause, next, previous

    /// MediaRemote command id understood by `mediaremote-adapter.pl send`.
    public var adapterID: Int {
        switch self {
        case .togglePlayPause: 2
        case .next: 4
        case .previous: 5
        }
    }
}

/// Which implementation feeds the module. Shown in Settings.
public enum NowPlayingSource: String, Sendable, Equatable, CaseIterable {
    /// Any app, through MediaRemote via the bundled adapter.
    case mediaRemote
    /// Spotify and Music only, through Apple Events.
    case appleScript
    /// Built-in fixtures.
    case sample

    public var label: String {
        switch self {
        case .mediaRemote: "All apps (MediaRemote)"
        case .appleScript: "Spotify and Music (Automation)"
        case .sample: "Sample data"
        }
    }
}

/// Why a provider stopped delivering.
public enum NowPlayingFailure: Sendable, Equatable {
    /// The adapter kept dying; restarting was abandoned.
    case gaveUp
    /// Apple Events were denied for the given app.
    case notAuthorized(bundleID: String)
}

/// A source of now-playing information. Providers do nothing until `start()` and must not prompt for permissions
/// except as a direct result of `start()` being called after the user opted in.
@MainActor
public protocol NowPlayingProvider: AnyObject {
    var source: NowPlayingSource { get }
    /// Called on the main actor with every change; `nil` = nothing is playing.
    var onUpdate: ((NowPlayingState?) -> Void)? { get set }
    var onFailure: ((NowPlayingFailure) -> Void)? { get set }
    /// Idempotent.
    func start()
    /// Idempotent. Terminates any child process.
    func stop()
    func send(_ command: MediaCommand)
}

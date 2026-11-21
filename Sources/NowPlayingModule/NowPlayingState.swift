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
    /// Playback speed reported by the source (1 = normal). `nil` = unknown, treated as 1 while playing.
    public var playbackRate: Double?

    public init(
        title: String, artist: String? = nil, album: String? = nil, artwork: SendableImage? = nil, isPlaying: Bool,
        bundleID: String? = nil, elapsed: TimeInterval? = nil, duration: TimeInterval? = nil, timestamp: Date? = nil,
        playbackRate: Double? = nil
    ) {
        self.title = title; self.artist = artist; self.album = album; self.artwork = artwork; self.isPlaying = isPlaying
        self.bundleID = bundleID; self.elapsed = elapsed; self.duration = duration; self.timestamp = timestamp
        self.playbackRate = playbackRate
    }

    /// The live playhead at `now`, extrapolated from the last sample. `nil` when elapsed or duration is unknown.
    public func position(at now: Date) -> TimeInterval? { PlaybackPosition.position(of: self, at: now) }

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

/// Where the playhead is between source updates. Pure.
public enum PlaybackPosition {
    /// `elapsed` advanced by the time since `timestamp` times the playback rate while playing, frozen while paused,
    /// clamped to `0...duration`. `nil` when elapsed or a positive duration is unknown, so the card hides the row.
    public static func position(of state: NowPlayingState, at now: Date) -> TimeInterval? {
        guard let elapsed = state.elapsed, elapsed.isFinite, let duration = state.duration, duration.isFinite, duration > 0 else {
            return nil
        }
        var position = elapsed
        if state.isPlaying, let timestamp = state.timestamp {
            let rate = state.playbackRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            position += max(0, now.timeIntervalSince(timestamp)) * rate
        }
        return min(duration, max(0, position))
    }

    /// 0...1 for a `PositionBar`.
    public static func progress(of state: NowPlayingState, at now: Date) -> Double? {
        guard let position = position(of: state, at: now), let duration = state.duration else { return nil }
        return position / duration
    }
}

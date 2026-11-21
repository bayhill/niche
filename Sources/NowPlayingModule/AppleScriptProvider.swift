import AppKit
import Foundation
import NotchCore
import os

/// The apps the Apple Events fallback can talk to.
public enum ScriptablePlayer: String, Sendable, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    public var bundleID: String { rawValue }
    public var name: String { self == .spotify ? "Spotify" : "Music" }

    /// Returns state, title, artist, album, duration (s), position (s), artwork URL, one per line.
    var statusScript: String {
        let duration = self == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let artwork = self == .spotify ? "(artwork url of t)" : "\"\""
        return """
        tell application id "\(bundleID)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (\(duration) as text) & linefeed & (player position as text) & linefeed & \(artwork)
        end tell
        """
    }

    func commandScript(_ command: MediaCommand) -> String {
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        return "tell application id \"\(bundleID)\" to \(verb)"
    }
}

/// Parsing for the status script's output. Pure.
public enum PlayerScriptOutput {
    /// Artwork URL is returned separately; the caller loads it.
    public static func parse(_ output: String, player: ScriptablePlayer, now: Date) -> (state: NowPlayingState, artworkURL: URL?)? {
        let lines = output.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        guard lines.count >= 2, lines[0] != "stopped" else { return nil }
        let title = lines[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        func field(_ i: Int) -> String? {
            guard i < lines.count else { return nil }
            let v = lines[i].trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == "missing value" ? nil : v
        }
        // `as text` follows the user's locale, so a decimal comma is possible.
        func number(_ i: Int) -> Double? { field(i).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } }
        let state = NowPlayingState(
            title: title, artist: field(2), album: field(3), isPlaying: lines[0] == "playing", bundleID: player.bundleID,
            elapsed: number(5), duration: number(4), timestamp: now
        )
        let artwork = field(6).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return (state, artwork)
    }

    /// Apple Events error -1743: the user denied Automation for this app.
    public static func isNotAuthorized(stderr: String) -> Bool { stderr.contains("-1743") }
}

/// Runs AppleScript source and returns stdout, or the error text.
public protocol ScriptRunning: Sendable {
    func run(_ source: String) async -> Result<String, ScriptError>
}

public struct ScriptError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// `osascript` as a child process: off the main thread, with a timeout, and the Automation prompt is attributed to
/// Notcher (the responsible process).
public struct OsascriptRunner: ScriptRunning {
    private let launcher: any ProcessLaunching
    public init(launcher: any ProcessLaunching = FoundationProcessLauncher()) { self.launcher = launcher }

    public func run(_ source: String) async -> Result<String, ScriptError> {
        let result = await launcher.run(URL(filePath: "/usr/bin/osascript"), arguments: ["-e", source], timeout: .seconds(4))
        let out = String(decoding: result.stdout, as: UTF8.self)
        if result.status == 0 { return .success(out) }
        return .failure(ScriptError(result.timedOut ? "timed out" : String(decoding: result.stderr, as: UTF8.self)))
    }
}

/// Fallback for Spotify and Music through Apple Events. Polls only while one of them is running.
/// Needs the Automation permission: construct freely, but only `start()` it after the user opted in.
@MainActor
public final class AppleScriptProvider: NowPlayingProvider {
    public let source = NowPlayingSource.appleScript
    public var onUpdate: ((NowPlayingState?) -> Void)?
    public var onFailure: ((NowPlayingFailure) -> Void)?

    private let runner: any ScriptRunning
    private let runningPlayers: @MainActor () -> [ScriptablePlayer]
    private let loadArtwork: @Sendable (URL) async -> SendableImage?
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @MainActor () -> Date
    private var task: Task<Void, Never>?
    private var last: NowPlayingState?
    private var lastPlayer: ScriptablePlayer?
    private var artworkCache: (url: URL, image: SendableImage?)?
    private var denied: Set<ScriptablePlayer> = []

    public init(
        runner: any ScriptRunning = OsascriptRunner(),
        runningPlayers: @escaping @MainActor () -> [ScriptablePlayer] = AppleScriptProvider.runningPlayers,
        loadArtwork: @escaping @Sendable (URL) async -> SendableImage? = AppleScriptProvider.downloadArtwork,
        interval: Duration = .milliseconds(1500),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.runner = runner; self.runningPlayers = runningPlayers; self.loadArtwork = loadArtwork
        self.interval = interval; self.sleep = sleep; self.now = now
    }

    public static func runningPlayers() -> [ScriptablePlayer] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return ScriptablePlayer.allCases.filter { ids.contains($0.bundleID) }
    }

    public static let downloadArtwork: @Sendable (URL) async -> SendableImage? = { url in
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return ArtworkDecoder.decode(data: data)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                let wait = await self.poll()
                do { try await self.sleep(wait) } catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func send(_ command: MediaCommand) {
        guard let player = lastPlayer else { return }
        if command == .togglePlayPause, var optimistic = last {
            optimistic.isPlaying.toggle()
            deliver(optimistic)
        }
        let runner = runner, script = player.commandScript(command)
        Task { [weak self] in
            _ = await runner.run(script)
            _ = await self?.poll()
        }
    }

    /// One polling round. Returns how long to wait before the next. Internal for tests.
    func poll() async -> Duration {
        let players = runningPlayers().filter { !denied.contains($0) }
        guard !players.isEmpty else {
            deliver(nil)
            // Checking the process list is cheap and sends no Apple Events.
            return interval * 2
        }
        var found: [(ScriptablePlayer, NowPlayingState, URL?)] = []
        for player in players {
            switch await runner.run(player.statusScript) {
            case .success(let output):
                if let parsed = PlayerScriptOutput.parse(output, player: player, now: now()) {
                    found.append((player, parsed.state, parsed.artworkURL))
                }
            case .failure(let error):
                if PlayerScriptOutput.isNotAuthorized(stderr: error.message) {
                    denied.insert(player)
                    onFailure?(.notAuthorized(bundleID: player.bundleID))
                }
            }
        }
        guard let pick = found.first(where: { $0.1.isPlaying }) ?? found.first(where: { $0.0 == lastPlayer }) ?? found.first else {
            deliver(nil)
            return interval
        }
        lastPlayer = pick.0
        var state = pick.1
        state.artwork = await artwork(for: pick.2)
        deliver(state)
        return interval
    }

    private func artwork(for url: URL?) async -> SendableImage? {
        guard let url else { return nil }
        if let cache = artworkCache, cache.url == url { return cache.image }
        let image = await loadArtwork(url)
        artworkCache = (url, image)
        return image
    }

    private func deliver(_ state: NowPlayingState?) {
        // Position changes every poll and the card extrapolates it; publish only what the extrapolation cannot know
        // (a seek shows up as a jump of more than two seconds).
        if let state, let last, state.trackKey == last.trackKey, state.isPlaying == last.isPlaying, state.artwork == last.artwork,
           state.bundleID == last.bundleID, state.duration == last.duration {
            let predicted = state.timestamp.flatMap { last.position(at: $0) }
            if let predicted, let actual = state.elapsed, abs(predicted - actual) <= 2 { return }
            if predicted == nil, state.elapsed == nil { return }
        }
        guard state != last else { return }
        last = state
        onUpdate?(state)
    }
}

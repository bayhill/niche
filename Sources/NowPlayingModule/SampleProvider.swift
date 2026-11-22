import CoreGraphics
import Foundation
import NotchCore

/// Fixture provider: one fixed track, never touches the system. Track, artist and album names are invented.
@MainActor
public final class SampleProvider: NowPlayingProvider {
    public let source = NowPlayingSource.sample
    public var onUpdate: ((NowPlayingState?) -> Void)?
    public var onFailure: ((NowPlayingFailure) -> Void)?
    public private(set) var state: NowPlayingState?
    public private(set) var sent: [MediaCommand] = []

    public init(state: NowPlayingState?) { self.state = state }

    public func start() { onUpdate?(state) }
    public func stop() {}

    public func send(_ command: MediaCommand) {
        sent.append(command)
        guard var s = state, let playing = command.isPlaying(after: s.isPlaying), playing != s.isPlaying else { return }
        s.isPlaying = playing
        state = s
        onUpdate?(s)
    }

    public static var track: NowPlayingState {
        NowPlayingState(
            title: "Paper Lanterns at Low Tide", artist: "Saltmere Quartet", album: "Harbour Hours, Vol. 2",
            artwork: sampleArtwork, isPlaying: true, bundleID: "com.spotify.client", elapsed: 154, duration: 480, timestamp: .now,
            playbackRate: 1
        )
    }

    /// A title and artist too long for the wings, to show truncation.
    public static var longTrack: NowPlayingState {
        var s = track
        s.title = "Paper Lanterns at Low Tide (Night Ferry Reprise, Restored Extended Edition)"
        s.artist = "Saltmere Quartet and the Glasswing Chamber Ensemble of Nowhere Near"
        s.album = "Harbour Hours, Vol. 2: The Long Crossing"
        return s
    }

    /// Generated album art: a soft two-colour gradient with a pale disc. Content, not chrome.
    public static let sampleArtwork: SendableImage? = {
        let size = 192
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [CGColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.45, green: 0.22, blue: 0.70, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.82, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 104, y: 104, width: 52, height: 52))
        return ctx.makeImage().map(SendableImage.init)
    }()
}

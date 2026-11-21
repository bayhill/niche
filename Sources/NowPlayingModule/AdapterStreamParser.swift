import CoreGraphics
import Foundation
import ImageIO
import NotchCore

/// A JSON scalar from the adapter's payload. Arrays and objects are not used by any key we read.
public enum AdapterValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(json: Any) {
        switch json {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case is NSNull: self = .null
        default: return nil
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        default: nil
        }
    }
}

/// Incremental parser for `mediaremote-adapter.pl stream` output: JSON lines of
/// `{"type":"data","diff":Bool,"payload":{...}}`. A non-diff payload replaces the state; a diff payload is merged into
/// it, with `null` removing a key. Lines may arrive split across any number of reads.
public struct AdapterStreamParser: Sendable {
    private var buffer = Data()
    private var scanned = 0
    private var payload: [String: AdapterValue] = [:]
    private var artworkBase64: String?
    private var artwork: SendableImage?
    /// Lines that were not valid adapter JSON. They are skipped.
    public private(set) var malformedLines = 0
    public let artworkPixelSize: Int

    public init(artworkPixelSize: Int = 192) { self.artworkPixelSize = artworkPixelSize }

    /// Forget everything (a new stream process starts with a full payload).
    public mutating func reset() { self = AdapterStreamParser(artworkPixelSize: artworkPixelSize) }

    /// Feeds raw stdout bytes. Returns the resulting state after each complete `data` line, in order
    /// (`nil` = nothing playing).
    public mutating func feed(_ chunk: Data) -> [NowPlayingState?] {
        buffer.append(chunk)
        var results: [NowPlayingState?] = []
        var lineStart = buffer.startIndex
        var cursor = buffer.startIndex + scanned
        while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
            if let state = apply(line: buffer[lineStart..<newline]) { results.append(state) }
            lineStart = newline + 1
            cursor = lineStart
        }
        if lineStart > buffer.startIndex { buffer = Data(buffer[lineStart...]) }
        scanned = buffer.count
        return results
    }

    /// The state the merged payload describes. Requires a title and a bundle identifier, like the adapter itself.
    public var current: NowPlayingState? { Self.state(from: payload, artwork: artwork) }

    /// Returns `.some(state)` for a `data` line, `nil` for anything to skip.
    private mutating func apply(line: Data) -> NowPlayingState?? {
        let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
        guard !trimmed.isEmpty else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: trimmed),
            let message = object as? [String: Any],
            (message["type"] as? String) == "data",
            let body = message["payload"] as? [String: Any]
        else {
            malformedLines += 1
            return nil
        }
        let diff = (message["diff"] as? Bool) ?? false
        if !diff { payload = [:] }
        for (key, raw) in body {
            guard let value = AdapterValue(json: raw) else { continue }
            if value == .null { payload.removeValue(forKey: key) } else { payload[key] = value }
        }
        updateArtwork()
        return .some(current)
    }

    private mutating func updateArtwork() {
        let base64 = payload["artworkData"]?.string
        guard base64 != artworkBase64 else { return }
        artworkBase64 = base64
        artwork = base64.flatMap { ArtworkDecoder.decode(base64: $0, maxPixelSize: artworkPixelSize) }
    }

    static func state(from payload: [String: AdapterValue], artwork: SendableImage?) -> NowPlayingState? {
        guard
            let title = payload["title"]?.string, !title.isEmpty,
            let bundle = payload["bundleIdentifier"]?.string
        else { return nil }
        let micros = { (key: String) in payload[key]?.number.map { $0 / 1_000_000 } }
        let timestamp: Date? = micros("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) }
            ?? payload["timestamp"]?.string.flatMap { try? Date($0, strategy: .iso8601) }
        return NowPlayingState(
            title: title,
            artist: payload["artist"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            album: payload["album"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            artwork: artwork,
            isPlaying: payload["playing"]?.bool ?? false,
            bundleID: payload["parentApplicationBundleIdentifier"]?.string ?? bundle,
            elapsed: micros("elapsedTimeMicros") ?? payload["elapsedTime"]?.number,
            duration: micros("durationMicros") ?? payload["duration"]?.number,
            timestamp: timestamp,
            playbackRate: payload["playbackRate"]?.number
        )
    }
}

/// Turns encoded artwork into a small `CGImage` without ever holding the full-size bitmap.
public enum ArtworkDecoder {
    public static func decode(base64: String, maxPixelSize: Int = 192) -> SendableImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    public static func decode(data: Data, maxPixelSize: Int = 192) -> SendableImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return SendableImage(image)
    }
}

import CoreGraphics
import Foundation

/// How to encode. Values outside their ranges are clamped when used.
public struct EncodeOptions: Sendable, Equatable, Hashable, Codable {
    /// 0...100. Ignored when `lossless` is on.
    public var quality: Int
    public var lossless: Bool
    /// libwebp effort, 0 (fast) ... 6 (slow, smaller).
    public var method: Int
    /// Downscale so the longer edge is at most this many pixels. `nil` keeps the original size
    /// (still capped at WebP's 16383 px limit).
    public var maxPixelEdge: Int?
    /// When false, an sRGB ICC profile and the source's EXIF are embedded.
    public var stripMetadata: Bool

    public init(quality: Int = 80, lossless: Bool = false, method: Int = 4, maxPixelEdge: Int? = nil, stripMetadata: Bool = true) {
        self.quality = quality; self.lossless = lossless; self.method = method
        self.maxPixelEdge = maxPixelEdge; self.stripMetadata = stripMetadata
    }

    public static let `default` = EncodeOptions()

    var clampedQuality: Int { min(100, max(0, quality)) }
    var clampedMethod: Int { min(6, max(0, method)) }
}

public struct PixelSize: Sendable, Hashable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var longEdge: Int { max(width, height) }
    /// "1920×1080"
    public var description: String { "\(width)\u{00D7}\(height)" }
}

/// Something to convert.
public enum ImageSource: Sendable, Hashable {
    /// Output goes next to the file.
    case file(URL)
    /// Encoded image bytes with no file behind them; output goes to the job's fallback folder as `<name>.webp`.
    case data(Data, name: String)

    /// File name (or suggested name) for display.
    public var displayName: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .data(_, let name): name
        }
    }
}

public enum ConversionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Not an image type ImageIO can read.
    case unsupported
    /// The input is already WebP; nothing was written.
    case alreadyWebP
    /// The file is missing, truncated or corrupt.
    case decodeFailed
    /// The source has more pixels than the engine will hold in memory.
    case tooLarge
    /// libwebp failed; `code` is its `WebPEncodingError` (or a `WebPMuxError` offset by -100).
    case encodeFailed(code: Int)
    /// Neither the source folder nor the fallback folder could be written.
    case writeFailed(String)

    /// Short text for a result row.
    public var message: String {
        switch self {
        case .unsupported: "Not a supported image"
        case .alreadyWebP: "Already WebP"
        case .decodeFailed: "Couldn\u{2019}t read image"
        case .tooLarge: "Image too large"
        case .encodeFailed(let code): "Encoding failed (\(code))"
        case .writeFailed: "Couldn\u{2019}t save"
        }
    }

    public var description: String {
        if case .writeFailed(let reason) = self { return "\(message): \(reason)" }
        return message
    }
}

/// One image to convert.
public struct ConversionJob: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var source: ImageSource
    /// Where output goes when the source folder is not writable, and for `.data` sources (the app passes Downloads).
    public var fallbackDirectory: URL

    public init(source: ImageSource, fallbackDirectory: URL, id: UUID = UUID()) {
        self.id = id; self.source = source; self.fallbackDirectory = fallbackDirectory
    }
}

public struct ConversionResult: Sendable, Hashable {
    /// The source file, or `nil` for a `.data` source.
    public let input: URL?
    public let inputName: String
    public let output: URL
    public let inputBytes: Int64
    public let outputBytes: Int64
    /// Pixel size written (after orientation and any downscale).
    public let pixelSize: PixelSize
    /// Pixel size of the source, oriented.
    public let originalPixelSize: PixelSize
    /// Things the user should know: first frame of an animation, WebP size cap, folder fallback.
    public let notes: [String]

    public init(
        input: URL?, inputName: String, output: URL, inputBytes: Int64, outputBytes: Int64,
        pixelSize: PixelSize, originalPixelSize: PixelSize, notes: [String] = []
    ) {
        self.input = input; self.inputName = inputName; self.output = output; self.inputBytes = inputBytes
        self.outputBytes = outputBytes; self.pixelSize = pixelSize; self.originalPixelSize = originalPixelSize; self.notes = notes
    }

    /// `1 - output/input`: 0.78 = 78% smaller; negative when the WebP is larger.
    public var savedFraction: Double {
        inputBytes > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : 0
    }
}

public enum ConversionEvent: Sendable {
    case started(ConversionJob)
    /// Progress of one file in flight, 0...1 (decoding counts for the first 10%).
    case fileProgress(ConversionJob, Double)
    case succeeded(ConversionJob, ConversionResult)
    case failed(ConversionJob, ConversionError)
    /// After every success or failure in this submission.
    case progress(completed: Int, total: Int)
}

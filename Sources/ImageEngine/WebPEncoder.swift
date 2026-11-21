import CoreGraphics
import Foundation
import Synchronization
import libwebp

public enum WebPEncoder {
    /// The ICC profile matching the pixels the encoder writes.
    public static let sRGBProfile: Data? = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?

    /// Encodes `image` as WebP. The image is first rendered into 8-bit sRGB with straight alpha, so any source
    /// colour space (Display P3, greyscale, CMYK, 16-bit, float) comes out right in browsers that assume sRGB.
    /// - Parameters:
    ///   - iccProfile: embedded as an `ICCP` chunk when non-nil. Pass `sRGBProfile` (the pixels are sRGB).
    ///   - exif: raw Exif embedded as an `EXIF` chunk when non-nil.
    ///   - progress: called with 0...1 as libwebp reports progress, in steps of at least 5%, possibly from an
    ///     encoder thread.
    ///   - cancellation: when set, libwebp is asked to stop and `.cancelled` is thrown.
    public static func encode(
        _ image: CGImage, options: EncodeOptions, iccProfile: Data? = nil, exif: Data? = nil,
        progress: (@Sendable (Double) -> Void)? = nil, cancellation: CancellationFlag? = nil
    ) throws(ConversionError) -> Data {
        try encode(raster: try Raster.make(image), options: options, iccProfile: iccProfile, exif: exif, progress: progress, cancellation: cancellation)
    }

    /// Encodes pixels already in a `Raster`. The raster's buffer is freed as soon as libwebp has its copy,
    /// so at most two full-size buffers are alive at once.
    static func encode(
        raster: Raster, options: EncodeOptions, iccProfile: Data?, exif: Data?,
        progress: (@Sendable (Double) -> Void)?, cancellation: CancellationFlag?
    ) throws(ConversionError) -> Data {
        let width = raster.width, height = raster.height
        if cancellation?.isCancelled == true { throw .cancelled }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue)) }
        if options.lossless {
            // Effort follows `method`; level 6 (method 4) is cwebp's `-lossless` default.
            let levels: [Int32] = [0, 1, 2, 4, 6, 8, 9]
            guard WebPConfigLosslessPreset(&config, levels[options.clampedMethod]) != 0 else {
                throw .encodeFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue))
            }
        } else {
            config.quality = Float(options.clampedQuality)
            config.method = Int32(options.clampedMethod)
            config.alpha_quality = 100
        }
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue)) }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue)) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        // Lossy imports straight into YUV (no ARGB copy); lossless needs ARGB.
        picture.use_argb = options.lossless ? 1 : 0
        defer { WebPPictureFree(&picture) }

        let stride = Int32(raster.bytesPerRow)
        let imported = raster.hasAlpha
            ? WebPPictureImportRGBA(&picture, raster.base, stride)
            : WebPPictureImportRGBX(&picture, raster.base, stride)
        raster.release()  // libwebp holds its own copy now
        guard imported != 0 else { throw .encodeFailed(code: Int(picture.error_code.rawValue)) }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite
        // The hook also carries cancellation: returning 0 makes libwebp abort with VP8_ENC_ERROR_USER_ABORT.
        let reporter = ProgressReporter(sink: progress, cancellation: cancellation)
        picture.user_data = Unmanaged.passUnretained(reporter).toOpaque()
        picture.progress_hook = { percent, picture in
            guard let raw = picture?.pointee.user_data else { return 1 }
            return Unmanaged<ProgressReporter>.fromOpaque(raw).takeUnretainedValue().report(percent) ? 1 : 0
        }
        let ok = withExtendedLifetime(reporter) {
            withUnsafeMutablePointer(to: &writer) { w -> Int32 in
                picture.custom_ptr = UnsafeMutableRawPointer(w)
                defer { picture.custom_ptr = nil }
                return WebPEncode(&config, &picture)
            }
        }
        picture.progress_hook = nil
        picture.user_data = nil
        if picture.error_code == VP8_ENC_ERROR_USER_ABORT || cancellation?.isCancelled == true { throw .cancelled }
        guard ok != 0, let mem = writer.mem, writer.size > 0 else { throw .encodeFailed(code: Int(picture.error_code.rawValue)) }
        let bitstream = Data(bytes: mem, count: writer.size)

        if iccProfile == nil && exif == nil { return bitstream }
        return try mux(bitstream, chunks: [("ICCP", iccProfile), ("EXIF", exif)])
    }

    /// Wraps a simple-format bitstream in an extended (VP8X) container with metadata chunks.
    static func mux(_ bitstream: Data, chunks: [(String, Data?)]) throws(ConversionError) -> Data {
        func check(_ err: WebPMuxError) throws(ConversionError) {
            if err != WEBP_MUX_OK { throw .encodeFailed(code: -100 + Int(err.rawValue)) }
        }
        guard let mux = WebPMuxNew() else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_OUT_OF_MEMORY.rawValue)) }
        defer { WebPMuxDelete(mux) }

        let setImage = bitstream.withUnsafeBytes { raw -> WebPMuxError in
            var data = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            return WebPMuxSetImage(mux, &data, 1)
        }
        try check(setImage)
        for (fourcc, payload) in chunks {
            guard let payload, !payload.isEmpty else { continue }
            let err = payload.withUnsafeBytes { raw -> WebPMuxError in
                var data = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
                return WebPMuxSetChunk(mux, fourcc, &data, 1)
            }
            try check(err)
        }

        var assembled = WebPData()
        WebPDataInit(&assembled)
        defer { WebPDataClear(&assembled) }
        try check(WebPMuxAssemble(mux, &assembled))
        guard let bytes = assembled.bytes else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_BAD_WRITE.rawValue)) }
        return Data(bytes: bytes, count: assembled.size)
    }
}

/// A thread-safe "stop" signal that can be checked from libwebp's threads.
public final class CancellationFlag: Sendable {
    private let state = Atomic<Bool>(false)
    public init() {}
    public var isCancelled: Bool { state.load(ordering: .acquiring) }
    public func cancel() { state.store(true, ordering: .releasing) }
}

/// Forwards libwebp's integer percentages, throttled, and answers whether to continue.
/// libwebp may call it from its alpha worker thread.
final class ProgressReporter: Sendable {
    private let sink: (@Sendable (Double) -> Void)?
    private let cancellation: CancellationFlag?
    private let last = Mutex<Int32>(-100)

    init(sink: (@Sendable (Double) -> Void)?, cancellation: CancellationFlag?) { self.sink = sink; self.cancellation = cancellation }

    /// - Returns: false to abort the encode.
    func report(_ percent: Int32) -> Bool {
        if cancellation?.isCancelled == true { return false }
        guard let sink else { return true }
        let send = last.withLock { last -> Bool in
            guard percent >= last + 5 || (percent >= 100 && last < 100) else { return false }
            last = percent
            return true
        }
        if send { sink(Double(min(100, max(0, percent))) / 100) }
        return true
    }
}

/// 8-bit sRGB RGBA pixels with straight (non-premultiplied) alpha, in anonymous memory that `release()` returns
/// to the system at once (a Swift array of this size lingered in the footprint after being freed).
final class Raster {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let hasAlpha: Bool
    private(set) var base: UnsafeMutablePointer<UInt8>?
    private let byteCount: Int

    static func make(_ image: CGImage) throws(ConversionError) -> Raster {
        guard image.width > 0, image.height > 0, image.width <= ImageDecoder.webPMaxEdge, image.height <= ImageDecoder.webPMaxEdge else {
            throw .encodeFailed(code: Int(VP8_ENC_ERROR_BAD_DIMENSION.rawValue))
        }
        guard let raster = Raster(image) else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_OUT_OF_MEMORY.rawValue)) }
        return raster
    }

    private init?(_ image: CGImage) {
        let width = image.width, height = image.height, bytesPerRow = image.width * 4
        let count = bytesPerRow * height
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.byteCount = count
        let alpha = image.alphaInfo
        let sourceHasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let mapped = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let mapped, mapped != MAP_FAILED else { return nil }
        let buffer = mapped.bindMemory(to: UInt8.self, capacity: count)
        base = buffer

        let info = sourceHasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: info.rawValue)
        else { munmap(mapped, count); base = nil; return nil }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var anyTransparent = false
        if sourceHasAlpha {
            // CoreGraphics only draws premultiplied; WebP stores straight alpha.
            for i in Swift.stride(from: 0, to: count, by: 4) {
                let a = Int(buffer[i + 3])
                if a == 255 { continue }
                anyTransparent = true
                if a == 0 { buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0; continue }
                for c in 0..<3 {
                    buffer[i + c] = UInt8(min(255, (Int(buffer[i + c]) * 255 + a / 2) / a))
                }
            }
        } else {
            for i in Swift.stride(from: 3, to: count, by: 4) { buffer[i] = 255 }
        }
        hasAlpha = anyTransparent
    }

    /// Unmaps the pixels. Safe to call more than once.
    func release() {
        guard let base else { return }
        munmap(UnsafeMutableRawPointer(base), byteCount)
        self.base = nil
    }

    deinit { release() }
}

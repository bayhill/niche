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
    public static func encode(
        _ image: CGImage, options: EncodeOptions, iccProfile: Data? = nil, exif: Data? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws(ConversionError) -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= ImageDecoder.webPMaxEdge, height <= ImageDecoder.webPMaxEdge else {
            throw .encodeFailed(code: Int(VP8_ENC_ERROR_BAD_DIMENSION.rawValue))
        }
        guard var raster = Raster(image) else { throw .encodeFailed(code: Int(VP8_ENC_ERROR_OUT_OF_MEMORY.rawValue)) }

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
        picture.use_argb = 1
        defer { WebPPictureFree(&picture) }

        let stride = Int32(raster.bytesPerRow)
        let imported = raster.pixels.withUnsafeMutableBufferPointer { buf -> Int32 in
            raster.hasAlpha ? WebPPictureImportRGBA(&picture, buf.baseAddress, stride) : WebPPictureImportRGBX(&picture, buf.baseAddress, stride)
        }
        guard imported != 0 else { throw .encodeFailed(code: Int(picture.error_code.rawValue)) }
        raster.pixels = []  // libwebp holds its own copy now

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite
        let reporter = progress.map(ProgressReporter.init)
        if let reporter {
            picture.user_data = Unmanaged.passUnretained(reporter).toOpaque()
            picture.progress_hook = { percent, picture in
                if let raw = picture?.pointee.user_data {
                    Unmanaged<ProgressReporter>.fromOpaque(raw).takeUnretainedValue().report(percent)
                }
                return 1
            }
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

/// Forwards libwebp's integer percentages, throttled. libwebp may call it from its alpha worker thread.
final class ProgressReporter: Sendable {
    private let sink: @Sendable (Double) -> Void
    private let last = Mutex<Int32>(-100)

    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    func report(_ percent: Int32) {
        let send = last.withLock { last -> Bool in
            guard percent >= last + 5 || (percent >= 100 && last < 100) else { return false }
            last = percent
            return true
        }
        if send { sink(Double(min(100, max(0, percent))) / 100) }
    }
}

/// 8-bit sRGB RGBA pixels with straight (non-premultiplied) alpha.
struct Raster {
    var pixels: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let hasAlpha: Bool

    init?(_ image: CGImage) {
        let width = image.width, height = image.height, bytesPerRow = image.width * 4
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
        let alpha = image.alphaInfo
        let sourceHasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let info = sourceHasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: info.rawValue)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var anyTransparent = false
        if sourceHasAlpha {
            // CoreGraphics only draws premultiplied; WebP stores straight alpha.
            for i in Swift.stride(from: 0, to: buffer.count, by: 4) {
                let a = Int(buffer[i + 3])
                if a == 255 { continue }
                anyTransparent = true
                if a == 0 { buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0; continue }
                for c in 0..<3 {
                    buffer[i + c] = UInt8(min(255, (Int(buffer[i + c]) * 255 + a / 2) / a))
                }
            }
        } else {
            for i in Swift.stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 255 }
        }
        pixels = buffer
        hasAlpha = anyTransparent
    }
}

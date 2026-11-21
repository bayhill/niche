import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageEngine

/// Decode → encode → decode-with-ImageIO round trips.
@Suite struct EncoderTests {
    func convert(_ source: ImageSource, _ options: EncodeOptions = .init()) throws -> (Data, ConversionQueue.Encoded) {
        let encoded = try ConversionQueue.convert(source, options: options)
        return (encoded.data, encoded)
    }

    @Test func dimensionsSurvive() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid(width: 64, height: 48, [0.2, 0.4, 0.6, 1]), to: fx.url("a.png"))
        let (data, enc) = try convert(.file(url))
        let out = try #require(Img.decode(data))
        #expect(out.width == 64 && out.height == 48)
        #expect(enc.pixelSize == PixelSize(width: 64, height: 48))
        #expect(Img.chunks(data).first == "VP8 ")
    }

    @Test func exifOrientationSixIsBakedIn() throws {
        let fx = try Fixture()
        // Stored 40×20: left half red, right half blue. Orientation 6 = rotate 90° clockwise for display,
        // so the upright image is 20×40 with red on top.
        let stored = Img.make(width: 40, height: 20) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        let url = try Img.write(stored, to: fx.url("rotated.jpg"), type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let (data, enc) = try convert(.file(url))
        let out = try #require(Img.decode(data))
        #expect(out.width == 20 && out.height == 40)
        #expect(enc.originalPixelSize == PixelSize(width: 20, height: 40))
        let top = Img.pixel(out, x: 10, y: 6), bottom = Img.pixel(out, x: 10, y: 34)
        #expect(top[0] > 200 && top[2] < 60, "top should be red, got \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "bottom should be blue, got \(bottom)")
        let orientation = (Img.properties(data)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        #expect(orientation == 1)
    }

    @Test(arguments: [true, false])
    func halfTransparentAlphaIsStraight(lossless: Bool) throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid([1, 0.5, 0.25, 0.5]), to: fx.url("alpha.png"))
        let (data, _) = try convert(.file(url), EncodeOptions(quality: 100, lossless: lossless))
        let out = try #require(Img.decode(data))
        #expect(out.alphaInfo != .none && out.alphaInfo != .noneSkipLast)
        let p = Img.pixel(out, x: 8, y: 8)
        #expect(near(p, [255, 128, 64, 128], lossless ? 2 : 4), "got \(p)")
        // Lossless carries alpha inside VP8L; lossy needs an extended container with an ALPH chunk.
        #expect(Img.chunks(data) == (lossless ? ["VP8L"] : ["VP8X", "ALPH", "VP8 "]))
    }

    @Test func displayP3IsConvertedToSRGB() throws {
        let fx = try Fixture()
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let components: [CGFloat] = [0.8, 0.4, 0.3, 1]
        let url = try Img.write(Img.solid(space: p3, components), to: fx.url("p3.png"))
        let expected = CGColor(colorSpace: p3, components: components)!
            .converted(to: Img.sRGB, intent: .defaultIntent, options: nil)!.components!.prefix(3).map { Int(($0 * 255).rounded()) }
        let (data, _) = try convert(.file(url), EncodeOptions(lossless: true))
        let p = Img.pixel(try #require(Img.decode(data)), x: 4, y: 4)
        #expect(near(Array(p.prefix(3)), expected, 3), "got \(p), expected \(expected)")
        #expect(!near(Array(p.prefix(3)), [204, 102, 77], 6), "P3 values were copied without conversion")
    }

    @Test func sixteenBitSourceDecodes() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid(bits: 16, [0.25, 0.5, 0.75, 1]), to: fx.url("deep.png"))
        #expect((Img.properties(try Data(contentsOf: url))[kCGImagePropertyDepth] as? Int) == 16)
        let (data, _) = try convert(.file(url), EncodeOptions(lossless: true))
        let p = Img.pixel(try #require(Img.decode(data)), x: 2, y: 2)
        #expect(near(p, [64, 128, 191, 255], 2), "got \(p)")
    }

    @Test func cmykSourceDecodes() throws {
        let fx = try Fixture()
        let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)!
        let image = Img.solid(space: cmyk, alpha: .none, [1, 0, 0, 0, 1])  // pure cyan ink
        let url = try Img.write(image, to: fx.url("cmyk.jpg"), type: .jpeg)
        let model = Img.properties(try Data(contentsOf: url))[kCGImagePropertyColorModel] as? String
        #expect(model == (kCGImagePropertyColorModelCMYK as String))
        let (data, _) = try convert(.file(url))
        let p = Img.pixel(try #require(Img.decode(data)), x: 8, y: 8)
        #expect(p[0] < 80 && p[1] > 120 && p[2] > 180, "cyan expected, got \(p)")
    }

    @Test func greyscaleSourceDecodes() throws {
        let fx = try Fixture()
        let grey = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let url = try Img.write(Img.solid(space: grey, alpha: .none, [0.5, 1]), to: fx.url("grey.png"))
        let (data, _) = try convert(.file(url), EncodeOptions(lossless: true))
        let p = Img.pixel(try #require(Img.decode(data)), x: 1, y: 1)
        #expect(abs(p[0] - p[1]) <= 1 && abs(p[1] - p[2]) <= 1 && abs(p[0] - 128) <= 4, "got \(p)")
    }

    @Test func losslessIsPixelExact() throws {
        let fx = try Fixture()
        let (image, bytes) = Img.pattern(width: 37, height: 29)
        let url = try Img.write(image, to: fx.url("pattern.png"))
        let (data, _) = try convert(.file(url), EncodeOptions(lossless: true))
        #expect(Img.chunks(data).first == "VP8L")
        let out = Img.rgba(try #require(Img.decode(data)))
        #expect(out == bytes)
    }

    @Test func lowerQualityIsSmaller() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.pattern(width: 128, height: 128, noise: true).0, to: fx.url("noise.png"))
        let low = try convert(.file(url), EncodeOptions(quality: 30)).0.count
        let high = try convert(.file(url), EncodeOptions(quality: 90)).0.count
        #expect(low < high, "q30 \(low) B, q90 \(high) B")
    }

    @Test func maxEdgeDownscalesKeepingAspect() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid(width: 400, height: 200, [0, 1, 0, 1]), to: fx.url("wide.png"))
        let (data, enc) = try convert(.file(url), EncodeOptions(maxPixelEdge: 100))
        let out = try #require(Img.decode(data))
        #expect(out.width == 100 && out.height == 50)
        #expect(enc.originalPixelSize == PixelSize(width: 400, height: 200))
        #expect(enc.notes.isEmpty)
        // A limit larger than the image never upscales.
        let (same, _) = try convert(.file(url), EncodeOptions(maxPixelEdge: 1000))
        #expect(try #require(Img.decode(same)).width == 400)
    }

    @Test func iccChunkFollowsStripMetadata() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid([0.3, 0.3, 0.9, 1]), to: fx.url("icc.png"))
        let kept = try convert(.file(url), EncodeOptions(stripMetadata: false)).0
        let stripped = try convert(.file(url), EncodeOptions(stripMetadata: true)).0
        #expect(Img.chunks(kept).contains("ICCP"))
        #expect(Img.chunks(kept).first == "VP8X")
        #expect(!Img.chunks(stripped).contains("ICCP"))
        #expect(Img.chunks(stripped) == ["VP8 "])
        #expect((Img.properties(kept)[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true)
        #expect(Img.decode(kept)?.width == 16)
    }

    @Test func exifIsKeptWithOrientationResetOrStripped() throws {
        let fx = try Fixture()
        let exif: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera", kCGImagePropertyTIFFOrientation: 6],
        ]
        let url = try Img.write(Img.solid(width: 30, height: 10, [1, 1, 0, 1]), to: fx.url("camera.jpg"), type: .jpeg, properties: exif)
        let kept = try convert(.file(url), EncodeOptions(stripMetadata: false)).0
        #expect(Img.chunks(kept).contains("EXIF"))
        let props = Img.properties(kept)
        let date = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
        let model = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String
        #expect(date == "2024:05:06 07:08:09")
        #expect(model == "Test Camera")
        #expect(((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1, "pixels are upright, so orientation must be 1")
        let out = try #require(Img.decode(kept))
        #expect(out.width == 10 && out.height == 30)

        let stripped = try convert(.file(url), EncodeOptions(stripMetadata: true)).0
        #expect(!Img.chunks(stripped).contains("EXIF"))
    }

    @Test func oversizedInputIsScaledToWebPLimit() throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid(width: 16_500, height: 8, alpha: .noneSkipLast, [0.5, 0.5, 0.5, 1]), to: fx.url("long.png"))
        let (data, enc) = try convert(.file(url))
        let out = try #require(Img.decode(data))
        #expect(out.width == ImageDecoder.webPMaxEdge)
        #expect(out.height >= 7 && out.height <= 8)
        #expect(enc.notes.contains { $0.contains("16383") })
    }

    @Test func animatedGifConvertsFirstFrameWithNote() throws {
        let fx = try Fixture()
        let frames = [Img.solid([1, 0, 0, 1]), Img.solid([0, 0, 1, 1])]
        try Img.encode(frames, type: .gif).write(to: fx.url("anim.gif"))
        let (data, enc) = try convert(.file(fx.url("anim.gif")), EncodeOptions(lossless: true))
        #expect(enc.notes.contains { $0.contains("first frame") })
        let p = Img.pixel(try #require(Img.decode(data)), x: 3, y: 3)
        #expect(p[0] > 200 && p[2] < 60, "first frame is red, got \(p)")
    }

    @Test func alreadyWebPIsSkipped() throws {
        let fx = try Fixture()
        let webp = try WebPEncoder.encode(Img.solid([0, 0, 0, 1]), options: .init())
        try webp.write(to: fx.url("done.webp"))
        #expect(throws: ConversionError.alreadyWebP) { try ImageDecoder.load(.file(fx.url("done.webp")), maxPixelEdge: nil) }
        #expect(throws: ConversionError.alreadyWebP) { try ImageDecoder.load(.data(webp, name: "x"), maxPixelEdge: nil) }
    }

    @Test func corruptAndNonImageFilesFailCleanly() throws {
        let fx = try Fixture()
        var junk = [UInt8](repeating: 0, count: 4096)
        for i in junk.indices { junk[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try Data(junk).write(to: fx.url("broken.png"))
        #expect(throws: ConversionError.decodeFailed) { try ImageDecoder.load(.file(fx.url("broken.png")), maxPixelEdge: nil) }
        // A real PNG cut off after its header.
        let png = Img.encode([Img.pattern(width: 64, height: 64, noise: true).0], type: .png)
        try png.prefix(40).write(to: fx.url("truncated.png"))
        #expect(throws: ConversionError.decodeFailed) { try ImageDecoder.load(.file(fx.url("truncated.png")), maxPixelEdge: nil) }
        try Data("hello".utf8).write(to: fx.url("notes.txt"))
        #expect(throws: ConversionError.unsupported) { try ImageDecoder.load(.file(fx.url("notes.txt")), maxPixelEdge: nil) }
        #expect(throws: ConversionError.decodeFailed) { try ImageDecoder.load(.file(fx.url("missing.png")), maxPixelEdge: nil) }
        #expect(throws: ConversionError.decodeFailed) { try ImageDecoder.load(.data(Data(junk), name: "x"), maxPixelEdge: nil) }
    }

    @Test func canConvertTypes() {
        #expect(ImageDecoder.canConvert(.png) && ImageDecoder.canConvert(.jpeg) && ImageDecoder.canConvert(.heic))
        #expect(ImageDecoder.canConvert(.tiff) && ImageDecoder.canConvert(.gif))
        #expect(!ImageDecoder.canConvert(.webP))
        #expect(!ImageDecoder.canConvert(.pdf) || ImageDecoder.decodableTypes.contains(UTType.pdf.identifier))
        #expect(!ImageDecoder.canConvert(.plainText))
    }

    @Test func savedFractionMayBeNegative() {
        let r = ConversionResult(input: nil, inputName: "a", output: URL(fileURLWithPath: "/a.webp"), inputBytes: 100, outputBytes: 112,
                                 pixelSize: .init(width: 1, height: 1), originalPixelSize: .init(width: 1, height: 1))
        #expect(abs(r.savedFraction - -0.12) < 1e-9)
    }
}

import AppKit
import Foundation
import ImageEngine
import NotchCore

extension ConvertModule {
    /// Built-in sample data for `--fixtures`, the playground and screenshots. Touches no files: drops are simulated.
    /// - Parameter inFlight: also show a batch in progress (3 of 12).
    public static func sample(inFlight: Bool = true) -> ConvertModule {
        let module = ConvertModule(
            runner: SimulatedRunner(), settings: .ephemeral(), fallbackDirectory: SimulatedRunner.folder,
            thumbnailer: { url in SampleArt.thumbnail(for: url.lastPathComponent) }, reveal: { _ in }, haptic: {},
            forwardsToShelf: false
        )
        module.settings.set(ConvertSettings.maxPixelEdge, 2560)
        let items = [
            ("hero-banner.webp", 1_240_000, 264_000),
            ("team-offsite.webp", 3_860_000, 512_000),
            ("pricing-chart.webp", 182_000, 41_000),
        ].map { name, input, output in
            ConvertedItem(
                name: name, output: SimulatedRunner.folder.appending(path: name), inputBytes: Int64(input), outputBytes: Int64(output),
                thumbnail: SampleArt.thumbnail(for: name)
            )
        }
        var batch: BatchProgress?
        if inFlight {
            batch = BatchProgress(total: 12)
            batch?.succeeded = 3
            batch?.inputBytes = 5_282_000
            batch?.outputBytes = 817_000
        }
        module.load(recent: items, batch: batch)
        return module
    }
}

/// Pretends to convert: emits plausible events with delays and never reads or writes a file.
struct SimulatedRunner: ConversionRunning {
    static let folder = URL(fileURLWithPath: "/Sample", isDirectory: true)

    func submit(_ jobs: [ConversionJob], options: EncodeOptions) -> AsyncStream<ConversionEvent> {
        AsyncStream { continuation in
            let task = Task {
                for (i, job) in jobs.enumerated() {
                    continuation.yield(.started(job))
                    try? await Task.sleep(for: .milliseconds(450))
                    if Task.isCancelled { break }
                    let name = job.source.displayName
                    let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
                    let input = Int64(400_000 + (seed * 7919) % 2_600_000)
                    let ratio = options.lossless ? 0.55 : 0.12 + Double(seed % 17) / 100
                    let result = ConversionResult(
                        input: nil, inputName: name,
                        output: Self.folder.appending(path: "\(OutputNamer.baseName(for: name)).webp"),
                        inputBytes: input, outputBytes: Int64(Double(input) * ratio),
                        pixelSize: PixelSize(width: 2560, height: 1440), originalPixelSize: PixelSize(width: 4032, height: 2268)
                    )
                    continuation.yield(.succeeded(job, result))
                    continuation.yield(.progress(completed: i + 1, total: jobs.count))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Generated thumbnails for sample rows.
enum SampleArt {
    static func thumbnail(for name: String) -> SendableImage? {
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palettes: [[TintRole]] = [[.accent, .success], [.warning, .accent], [.success, .warning]]
        let colors = palettes[seed % palettes.count].map { NSColor($0.color).cgColor }
        let size = 56
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])
        else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        return ctx.makeImage().map(SendableImage.init)
    }
}

import AppKit
import Foundation
import ImageEngine
import NotchCore

extension ConvertModule {
    /// The states `sample(_:)` can show, matching the design's previews.
    public enum SampleState: Sendable, CaseIterable {
        /// Nothing converted yet.
        case empty
        /// Two of five done, one converting, the rest waiting.
        case converting
        /// Three finished files, one of which grew.
        case done
    }

    /// Built-in sample data for `--fixtures`, the playground and screenshots. Touches no files: drops are simulated.
    public static func sample(_ state: SampleState = .converting) -> ConvertModule {
        let module = ConvertModule(
            runner: SimulatedRunner(), settings: .ephemeral(), fallbackDirectory: SimulatedRunner.folder,
            thumbnailer: { url in SampleArt.thumbnail(for: url.lastPathComponent) }, reveal: { _ in }, haptic: {},
            forwardsToShelf: false, fileExists: { _ in false }  // sample outputs are not real files
        )
        func done(_ name: String, _ input: Int64, _ output: Int64, batch: Int) -> ConvertRow {
            let webp = "\(OutputNamer.baseName(for: name)).webp"
            return ConvertRow(
                batch: batch, name: name,
                state: .done(output: SimulatedRunner.folder.appending(path: webp), inputBytes: input, outputBytes: output),
                thumbnail: SampleArt.thumbnail(for: webp)
            )
        }
        switch state {
        case .empty:
            break
        case .converting:
            let rows = [
                done("harbor-dusk.png", 2_100_000, 380_000, batch: 1),
                done("hero-banner.png", 1_200_000, 264_000, batch: 1),
                ConvertRow(batch: 1, name: "dunes-wide.jpeg", state: .converting(0.62)),
                ConvertRow(batch: 1, name: "fjord-morning.heic", state: .waiting),
                ConvertRow(batch: 1, name: "team-offsite.jpg", state: .waiting),
            ]
            var batch = BatchProgress(id: 1, total: 5)
            batch.succeeded = 2
            batch.inputBytes = 3_300_000
            batch.outputBytes = 644_000
            module.load(rows: rows, batch: batch)
        case .done:
            module.load(rows: [
                done("hero-banner.png", 1_200_000, 264_000, batch: 1),
                done("dunes-wide.jpeg", 3_400_000, 912_000, batch: 1),
                done("settings-panel.png", 86_000, 91_000, batch: 1),
            ], batch: nil)
        }
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
                    for step in 1...5 {
                        try? await Task.sleep(for: .milliseconds(120))
                        continuation.yield(.fileProgress(job, Double(step) / 5))
                    }
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

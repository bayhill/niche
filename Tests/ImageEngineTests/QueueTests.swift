import CoreGraphics
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ImageEngine

@Suite struct OutputNamerTests {
    let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)

    @Test func plainThenNumbered() {
        let src = URL(fileURLWithPath: "/tmp/x/hero.png")
        #expect(OutputNamer.destination(for: src, in: dir, reserved: [], exists: { _ in false }).lastPathComponent == "hero.webp")
        let existing: Set<String> = ["hero.webp", "hero-1.webp"]
        let next = OutputNamer.destination(for: src, in: dir, reserved: [], exists: { existing.contains($0.lastPathComponent) })
        #expect(next.lastPathComponent == "hero-2.webp")
    }

    @Test func reservedNamesAreSkippedCaseInsensitively() {
        let reserved: Set<URL> = [dir.appending(path: "Hero.webp")]
        let next = OutputNamer.destination(for: URL(fileURLWithPath: "/tmp/x/hero.jpg"), in: dir, reserved: reserved, exists: { _ in false })
        #expect(next.lastPathComponent == "hero-1.webp")
    }

    @Test func baseNames() {
        #expect(OutputNamer.baseName(for: "photo.final.jpeg") == "photo.final")
        #expect(OutputNamer.baseName(for: "a/b:c.png") == "a-b-c")
        #expect(OutputNamer.baseName(for: ".hidden") == "hidden")
        #expect(OutputNamer.baseName(for: "") == "image")
        #expect(OutputNamer.baseName(for: "Screenshot") == "Screenshot")
    }
}

@Suite struct QueueTests {
    func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    @Test func outputGoesNextToSourceAndOriginalIsUntouched() async throws {
        let fx = try Fixture()
        let url = try Img.write(Img.solid(width: 20, height: 10, [1, 0, 0, 1]), to: fx.url("hero.png"))
        let before = try sha(url)
        let events = await run(ConversionQueue(maxConcurrent: 1), [fx.job("hero.png")])
        let r = try #require(events.results.first)
        #expect(r.output == fx.url("hero.webp"))
        #expect(r.input == url && r.inputName == "hero.png")
        #expect(r.inputBytes == Int64(try Data(contentsOf: url).count))
        #expect(r.outputBytes == Int64(try Data(contentsOf: r.output).count))
        #expect(r.savedFraction == 1 - Double(r.outputBytes) / Double(r.inputBytes))
        #expect(try sha(url) == before)
        #expect(Img.decode(r.output)?.width == 20)
        // No temporary files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func eventsReportStartCompletionAndProgress() async throws {
        let fx = try Fixture()
        try Img.write(Img.solid([0, 1, 0, 1]), to: fx.url("a.png"))
        try Data("nope".utf8).write(to: fx.url("b.png"))
        let jobs = [fx.job("a.png"), fx.job("b.png")]
        let events = await run(ConversionQueue(maxConcurrent: 2), jobs)
        let started = events.compactMap { if case .started(let j) = $0 { j.id } else { nil } }
        #expect(Set(started) == Set(jobs.map(\.id)))
        #expect(events.results.count == 1)
        #expect(events.failures == [.decodeFailed])
        let progress = events.compactMap { if case .progress(let c, let t) = $0 { [c, t] } else { nil } }
        #expect(progress == [[1, 2], [2, 2]])
        if case .progress = events.last {} else { Issue.record("last event should be progress") }
    }

    @Test func collisionsWithinABatchAndOnDiskSerially() async throws {
        let fx = try Fixture()
        try Img.write(Img.solid([1, 0, 0, 1]), to: fx.url("hero.png"))
        try Img.write(Img.solid([0, 0, 1, 1]), to: fx.url("hero.jpg"), type: .jpeg)
        try Data("existing".utf8).write(to: fx.url("hero.webp"))
        let events = await run(ConversionQueue(maxConcurrent: 1), [fx.job("hero.png"), fx.job("hero.jpg")])
        let names = events.results.map { $0.output.lastPathComponent }
        #expect(Set(names) == ["hero-1.webp", "hero-2.webp"])
        // Names follow submission order.
        #expect(events.results.first { $0.inputName == "hero.png" }?.output.lastPathComponent == "hero-1.webp")
        #expect(try String(contentsOf: fx.url("hero.webp"), encoding: .utf8) == "existing")
    }

    @Test func collisionsUnderConcurrencyNeverOverwrite() async throws {
        let fx = try Fixture()
        let types: [(String, UTType)] = [("png", .png), ("jpg", .jpeg), ("jpeg", .jpeg), ("tiff", .tiff), ("tif", .tiff), ("gif", .gif), ("bmp", .bmp), ("heic", .heic)]
        for (i, (ext, type)) in types.enumerated() {
            try Img.write(Img.solid(width: 40 + i, height: 30, [Double(i) / 8, 0.5, 0.5, 1]), to: fx.url("hero.\(ext)"), type: type)
        }
        let queue = ConversionQueue(maxConcurrent: 4)
        // Two overlapping submissions of the same files, to also race across batches.
        async let a = run(queue, types.map { fx.job("hero.\($0.0)") })
        async let b = run(queue, types.map { fx.job("hero.\($0.0)") })
        let results = (await a).results + (await b).results
        #expect(results.count == 16)
        let outputs = Set(results.map(\.output))
        #expect(outputs.count == 16)
        let expected = Set(["hero.webp"] + (1..<16).map { "hero-\($0).webp" })
        #expect(Set(outputs.map(\.lastPathComponent)) == expected)
        for r in results {
            // Each file holds the image of the source that claimed it.
            #expect(Img.decode(r.output)?.width == r.pixelSize.width)
        }
    }

    @Test func unwritableFolderFallsBack() async throws {
        let fx = try Fixture()
        let locked = fx.dir.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let src = try Img.write(Img.solid([1, 1, 0, 1]), to: locked.appending(path: "shot.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let events = await run(ConversionQueue(), [ConversionJob(source: .file(src), fallbackDirectory: fx.fallback)])
        let r = try #require(events.results.first)
        #expect(r.output == fx.fallback.appending(path: "shot.webp"))
        #expect(r.notes.contains { $0.contains("not writable") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["shot.png"])
    }

    @Test func imageDataWritesToFallbackFolder() async throws {
        let fx = try Fixture()
        let png = Img.encode([Img.solid([0, 1, 1, 1])], type: .png)
        let jobs = [
            ConversionJob(source: .data(png, name: "pasted.png"), fallbackDirectory: fx.fallback),
            ConversionJob(source: .data(png, name: "pasted"), fallbackDirectory: fx.fallback),
        ]
        let events = await run(ConversionQueue(), jobs)
        #expect(Set(events.results.map { $0.output.lastPathComponent }) == ["pasted.webp", "pasted-1.webp"])
        #expect(events.results.allSatisfy { $0.input == nil && $0.output.deletingLastPathComponent().standardizedFileURL == fx.fallback.standardizedFileURL })
        #expect(events.results.allSatisfy { $0.inputBytes == Int64(png.count) })
    }

    @Test func alreadyWebPAndCorruptReportFailuresWithoutWriting() async throws {
        let fx = try Fixture()
        try WebPEncoder.encode(Img.solid([0, 0, 0, 1]), options: .init()).write(to: fx.url("done.webp"))
        try Data(repeating: 0xAB, count: 512).write(to: fx.url("bad.jpg"))
        let events = await run(ConversionQueue(), [fx.job("done.webp"), fx.job("bad.jpg")])
        #expect(Set(events.failures.map(\.message)) == [ConversionError.alreadyWebP.message, ConversionError.decodeFailed.message])
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: fx.dir.path))
        #expect(files == ["Fallback", "done.webp", "bad.jpg"])
    }

    @Test func concurrencyIsBounded() async throws {
        let fx = try Fixture()
        for i in 0..<6 { try Img.write(Img.pattern(width: 300, height: 300, seed: UInt64(i), noise: true).0, to: fx.url("n\(i).png")) }
        let events = await run(ConversionQueue(maxConcurrent: 2), (0..<6).map { fx.job("n\($0).png") })
        var inFlight = 0, peak = 0
        for e in events {
            switch e {
            case .started: inFlight += 1; peak = max(peak, inFlight)
            case .succeeded, .failed: inFlight -= 1
            case .progress: break
            }
        }
        #expect(events.results.count == 6)
        #expect(peak <= 2)
    }
}

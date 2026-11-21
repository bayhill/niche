import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageEngine

/// Files still downloading, cloud placeholders, and the memory/cancellation behaviour of the queue.
@Suite struct IncompleteFileTests {
    func photo(_ type: UTType, width: Int = 480, height: Int = 320) -> Data {
        let image = Img.pattern(width: width, height: height, seed: 7, noise: true).0
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test(arguments: [UTType.jpeg, .png, .heic, .gif])
    func cutToAThirdIsIncomplete(type: UTType) throws {
        let fx = try Fixture()
        let full = photo(type)
        let ext = type.preferredFilenameExtension!
        try full.write(to: fx.url("whole.\(ext)"))
        try full.prefix(full.count / 3).write(to: fx.url("cut.\(ext)"))
        if type == .jpeg || type == .png {
            // ImageIO alone decodes the cut file and calls it complete: the case this check exists for.
            #expect(Img.decode(full.prefix(full.count / 3)) != nil)
        }

        #expect(throws: ConversionError.incomplete) { try ImageDecoder.load(.file(fx.url("cut.\(ext)")), maxPixelEdge: nil) }
        #expect(throws: ConversionError.incomplete) { try ImageDecoder.load(.data(full.prefix(full.count / 3), name: "x"), maxPixelEdge: nil) }
        let whole = try ImageDecoder.load(.file(fx.url("whole.\(ext)")), maxPixelEdge: nil)
        #expect(whole.pixelSize == PixelSize(width: 480, height: 320))
    }

    @Test func cutJPEGThroughTheQueueWritesNothing() async throws {
        let fx = try Fixture()
        let full = photo(.jpeg)
        try full.prefix(full.count / 3).write(to: fx.url("partial.jpg"))
        try full.write(to: fx.url("whole.jpg"))
        let events = await run(ConversionQueue(), [fx.job("partial.jpg"), fx.job("whole.jpg")])
        #expect(events.failures == [.incomplete])
        #expect(ConversionError.incomplete.message == "File is incomplete")
        #expect(events.results.map { $0.output.lastPathComponent } == ["whole.webp"])
        #expect(!FileManager.default.fileExists(atPath: fx.url("partial.webp").path))
    }

    @Test func zeroByteFileIsIncomplete() throws {
        let fx = try Fixture()
        try Data().write(to: fx.url("empty.png"))
        #expect(throws: ConversionError.incomplete) { try ImageDecoder.load(.file(fx.url("empty.png")), maxPixelEdge: nil) }
        #expect(throws: ConversionError.incomplete) { try ImageDecoder.load(.data(Data(), name: "x"), maxPixelEdge: nil) }
    }

    @Test func jpegWithDataAfterEndOfImageIsComplete() throws {
        // iPhone photos append gain maps and depth after the primary image's EOI.
        var data = photo(.jpeg)
        data.append(Data(repeating: 0x5A, count: 3000))
        let decoded = try ImageDecoder.load(.data(data, name: "x.jpg"), maxPixelEdge: nil)
        #expect(decoded.pixelSize.width == 480)
    }

    @Test func cloudPlaceholdersAreNotConverted() {
        let dataless = UInt32(0x4000_0000)  // SF_DATALESS
        #expect(FileAvailability.problem(isUbiquitous: true, status: .notDownloaded, flags: 0) == .notDownloaded)
        #expect(FileAvailability.problem(isUbiquitous: true, status: .downloaded, flags: 0) == .notDownloaded)  // stale copy
        #expect(FileAvailability.problem(isUbiquitous: true, status: .current, flags: 0) == nil)
        #expect(FileAvailability.problem(isUbiquitous: false, status: nil, flags: dataless) == .notDownloaded)
        #expect(FileAvailability.problem(isUbiquitous: nil, status: nil, flags: 0) == nil)
        #expect(FileAvailability.problem(isUbiquitous: nil, status: nil, flags: nil) == .decodeFailed)
        #expect(ConversionError.notDownloaded.message == "Not downloaded from iCloud")
    }
}

@Suite struct AdmissionTests {
    let big: Int64 = 3_000, small: Int64 = 100

    @Test func oversizedJobsRunOneAtATime() {
        var a = Admission<String>(budgetBytes: 1_000, maxConcurrent: 4)
        let first = a.request("A", cost: big), second = a.request("B", cost: big)
        #expect(first)          // alone, even over budget
        #expect(!second)
        let afterA = a.finish("A")
        #expect(afterA == ["B"])
        #expect(a.running.keys.sorted() == ["B"])
        let afterB = a.finish("B")
        #expect(afterB.isEmpty)
        #expect(a.running.isEmpty && a.inUse == 0)
    }

    @Test func smallJobsRunInParallelUpToTheCount() {
        var a = Admission<Int>(budgetBytes: 1_000, maxConcurrent: 4)
        var admitted: [Bool] = []
        for i in 0..<5 { admitted.append(a.request(i, cost: small)) }
        #expect(admitted == [true, true, true, true, false])   // count limit
        let next = a.finish(0)
        #expect(next == [4])
    }

    @Test func budgetLimitsMixedSizesInOrder() {
        var a = Admission<String>(budgetBytes: 1_000, maxConcurrent: 4)
        let s1 = a.request("s1", cost: 400), s2 = a.request("s2", cost: 400)
        let m = a.request("m", cost: 400)           // 1200 > 1000
        let s3 = a.request("s3", cost: 50)          // fits, but waits behind "m": no starvation
        #expect(s1 && s2 && !m && !s3)
        let next = a.finish("s1")
        #expect(next == ["m", "s3"])
        #expect(a.inUse == 850)
    }

    @Test func withdrawingAWaiterAdmitsTheNext() {
        var a = Admission<String>(budgetBytes: 1_000, maxConcurrent: 1)
        let r = [a.request("A", cost: 10), a.request("B", cost: 10), a.request("C", cost: 10)]
        #expect(r == [true, false, false])
        let withdrawn = a.finish("B")
        #expect(withdrawn.isEmpty)
        let next = a.finish("A")
        #expect(next == ["C"])
    }

    @Test func costsAndDefaultBudget() {
        #expect(Admission<Int>.cost(sourcePixels: 100, outputPixels: 100, lossless: false) == 800)
        #expect(Admission<Int>.cost(sourcePixels: 100, outputPixels: 100, lossless: true) == 1_400)
        #expect(Admission<Int>.cost(sourcePixels: 10_000, outputPixels: 100, lossless: false) == 40_000)  // full decode dominates
        let budget = Admission<Int>.defaultBudget
        #expect(budget >= 512 << 20 && budget <= 4 << 30)
        // Two 12 MP photos share even the smallest budget.
        #expect(Admission<Int>.cost(sourcePixels: 12_000_000, outputPixels: 12_000_000, lossless: false) * 2 <= 512 << 20)
    }
}

@Suite struct QueueMemoryAndCancellationTests {
    func peak(_ events: [ConversionEvent]) -> Int {
        var inFlight = 0, peak = 0
        for e in events {
            switch e {
            case .started: inFlight += 1; peak = max(peak, inFlight)
            case .succeeded, .failed: inFlight -= 1
            case .progress, .fileProgress: break
            }
        }
        return peak
    }

    @Test func budgetSerialisesLargeJobsAndParallelisesSmallOnes() async throws {
        let fx = try Fixture()
        for i in 0..<4 { try Img.write(Img.pattern(width: 400, height: 400, seed: UInt64(i), noise: true).0, to: fx.url("p\(i).png")) }
        let jobs = (0..<4).map { fx.job("p\($0).png") }
        // 400×400 costs 1.28 MB: with a 1 MB budget each job runs alone.
        let tight = await run(ConversionQueue(maxConcurrent: 4, budgetBytes: 1_000_000), jobs)
        #expect(tight.results.count == 4)
        #expect(peak(tight) == 1)
        let roomy = await run(ConversionQueue(maxConcurrent: 4, budgetBytes: 100_000_000), jobs)
        #expect(roomy.results.count == 4)
        #expect(peak(roomy) >= 2)
    }

    @Test func cancellingMidEncodeLeavesNothingBehind() async throws {
        let fx = try Fixture()
        try Img.write(Img.pattern(width: 3000, height: 3000, seed: 3, noise: true).0, to: fx.url("huge.png"))
        let queue = ConversionQueue(maxConcurrent: 1)
        let job = fx.job("huge.png")
        let clock = ContinuousClock()
        // Like ConvertModule.stop(): the task consuming the events is cancelled while libwebp is encoding.
        let consumer = Task {
            var seen: [ConversionEvent] = []
            for await e in queue.submit([job], options: EncodeOptions(quality: 95, method: 6)) {
                seen.append(e)
                if case .fileProgress(_, let f) = e, f > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return seen
        }
        let seen = await consumer.value
        #expect(!seen.contains { if case .succeeded = $0 { true } else { false } })
        #expect(seen.contains { if case .fileProgress = $0 { true } else { false } })
        let cancelledAt = clock.now
        while await queue.runningCount > 0 {
            #expect(clock.now - cancelledAt < .seconds(5), "encode kept running after cancellation")
            if clock.now - cancelledAt > .seconds(5) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("encode stopped \(clock.now - cancelledAt) after cancellation")
        let files = try FileManager.default.contentsOfDirectory(atPath: fx.dir.path)
        #expect(Set(files) == ["huge.png", "Fallback"], "\(files)")
    }

    @Test func cancelledEncoderThrowsCancelled() {
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: ConversionError.cancelled) {
            try WebPEncoder.encode(Img.solid([1, 0, 0, 1]), options: .init(), cancellation: flag)
        }
    }
}

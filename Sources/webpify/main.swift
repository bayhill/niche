import Foundation
import ImageEngine

// webpify [-q N] [--lossless] [--max-edge N] [--keep-metadata] [-m N] [-j N] <files…>
// Converts each file to WebP next to it (or into the current directory when its folder is read-only)
// with the same engine the app uses, and prints one line per file.

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("webpify: \(message)\n".utf8))
    exit(2)
}

let usage = "usage: webpify [-q 0-100] [--lossless] [--max-edge N] [--keep-metadata] [-m 0-6] [-j N] <files…>"
var options = EncodeOptions()
var concurrency = ConversionQueue.defaultConcurrency
var files: [URL] = []
var args = CommandLine.arguments.dropFirst().makeIterator()

@MainActor func intArg(_ flag: String, _ range: ClosedRange<Int>) -> Int {
    guard let v = args.next(), let n = Int(v), range.contains(n) else { fail("\(flag) needs a number in \(range)") }
    return n
}

while let arg = args.next() {
    switch arg {
    case "-q", "--quality": options.quality = intArg(arg, 0...100)
    case "-m", "--method": options.method = intArg(arg, 0...6)
    case "-j", "--jobs": concurrency = intArg(arg, 1...64)
    case "--lossless": options.lossless = true
    case "--max-edge": options.maxPixelEdge = intArg(arg, 1...100_000)
    case "--keep-metadata": options.stripMetadata = false
    case "-h", "--help": print(usage); exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\(usage)") }
        files.append(URL(fileURLWithPath: arg).standardizedFileURL)
    }
}
if files.isEmpty { fail(usage) }

func bytes(_ n: Int64) -> String {
    if n < 1000 { return "\(n) B" }
    let kb = Double(n) / 1000
    if kb < 999.5 { return "\(Int(kb.rounded())) KB" }
    return String(format: "%.2f MB", kb / 1000)
}

func saving(_ f: Double) -> String {
    let pct = Int((abs(f) * 100).rounded())
    return pct == 0 ? "0%" : (f > 0 ? "-\(pct)%" : "+\(pct)%")
}

let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let jobs = files.map { ConversionJob(source: .file($0), fallbackDirectory: fallback) }
let queue = ConversionQueue(maxConcurrent: concurrency)
let clock = ContinuousClock()
let start = clock.now
var failures = 0, totalIn: Int64 = 0, totalOut: Int64 = 0

for await event in queue.submit(jobs, options: options) {
    switch event {
    case .succeeded(_, let r):
        totalIn += r.inputBytes; totalOut += r.outputBytes
        let notes = r.notes.isEmpty ? "" : "  (\(r.notes.joined(separator: "; ")))"
        print("\(r.inputName) -> \(r.output.lastPathComponent)  \(bytes(r.inputBytes)) -> \(bytes(r.outputBytes))  \(saving(r.savedFraction))  \(r.pixelSize)\(notes)")
    case .failed(let job, let error):
        failures += 1
        print("\(job.source.displayName): \(error)")
    case .started, .fileProgress, .progress:
        break
    }
}

let elapsed = clock.now - start
if jobs.count > 1, totalIn > 0 {
    print("total \(bytes(totalIn)) -> \(bytes(totalOut))  \(saving(1 - Double(totalOut) / Double(totalIn)))  \(jobs.count - failures)/\(jobs.count) in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
}
exit(failures == 0 ? 0 : 1)

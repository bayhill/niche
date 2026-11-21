import Foundation

/// Decides which jobs may run, by estimated memory rather than a fixed count: small images run in parallel,
/// one very large image runs alone. Strictly first-in, first-out so a large job is never starved by small ones.
/// Pure state; `ConversionQueue` wraps it.
public struct Admission<ID: Hashable & Sendable>: Sendable {
    public let budgetBytes: Int64
    public let maxConcurrent: Int
    public private(set) var running: [ID: Int64] = [:]
    public private(set) var waiting: [(id: ID, cost: Int64)] = []

    public init(budgetBytes: Int64, maxConcurrent: Int) {
        self.budgetBytes = max(1, budgetBytes); self.maxConcurrent = max(1, maxConcurrent)
    }

    public var inUse: Int64 { running.values.reduce(0, +) }

    /// A job fits when nothing runs (so an oversized job still runs, alone), or when both the count and the
    /// memory budget allow it.
    public func fits(_ cost: Int64) -> Bool {
        running.isEmpty || (running.count < maxConcurrent && inUse + cost <= budgetBytes)
    }

    /// Returns true when the job may start now; otherwise it waits its turn.
    public mutating func request(_ id: ID, cost: Int64) -> Bool {
        if waiting.isEmpty && fits(cost) { running[id] = cost; return true }
        waiting.append((id, cost))
        return false
    }

    /// Ends a running job (or withdraws a waiting one) and returns the jobs that may start now, in order.
    public mutating func finish(_ id: ID) -> [ID] {
        if running.removeValue(forKey: id) == nil { waiting.removeAll { $0.id == id } }
        var admitted: [ID] = []
        while let next = waiting.first, fits(next.cost) {
            waiting.removeFirst()
            running[next.id] = next.cost
            admitted.append(next.id)
        }
        return admitted
    }

    /// An eighth of physical memory, between 512 MB and 4 GB.
    public static var defaultBudget: Int64 {
        let eighth = Int64(clamping: ProcessInfo.processInfo.physicalMemory / 8)
        return min(4 << 30, max(512 << 20, eighth))
    }

    /// Peak bytes for one job, as measured on a 16000×16000 JPEG: lossy peaks at two 4 B/px buffers (ImageIO's
    /// decode and the encoder's raster); lossless at about 13 B/px inside libwebp. A downscaled job still decodes
    /// the source at full size (4 B/px).
    public static func cost(sourcePixels: Int, outputPixels: Int, lossless: Bool) -> Int64 {
        let perOutputPixel: Int64 = lossless ? 14 : 8
        return max(Int64(sourcePixels) * 4, Int64(outputPixels) * perOutputPixel)
    }
}

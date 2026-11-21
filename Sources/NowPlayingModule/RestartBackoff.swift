import Foundation

/// When to restart a child that died: exponential delays, reset after a run that lasted long enough,
/// and give up after too many quick failures in a row.
public struct RestartBackoff: Sendable, Equatable {
    public var initial: Duration
    public var maximum: Duration
    /// A run at least this long counts as healthy and resets the failure count.
    public var stableAfter: Duration
    /// Consecutive quick failures tolerated before giving up.
    public var maxQuickFailures: Int
    public private(set) var failures = 0

    public init(
        initial: Duration = .seconds(1), maximum: Duration = .seconds(60), stableAfter: Duration = .seconds(30),
        maxQuickFailures: Int = 6
    ) {
        self.initial = initial; self.maximum = maximum; self.stableAfter = stableAfter; self.maxQuickFailures = maxQuickFailures
    }

    /// Delay before the next start after a run of the given length, or `nil` to stop trying.
    public mutating func next(afterRunOf ran: Duration) -> Duration? {
        if ran >= stableAfter { failures = 0 }
        failures += 1
        guard failures <= maxQuickFailures else { return nil }
        var delay = initial
        for _ in 1..<failures {
            delay *= 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}

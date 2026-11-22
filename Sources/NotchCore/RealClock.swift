/// Sleeping for the modules that let tests supply their own `sleep`.
///
/// Modules keep an optional function and sleep through these helpers, so that in the app (`nil`) the call goes
/// straight to `Task.sleep`. The obvious shape, a parameter whose default is the real sleep as a function value
/// (`sleep: … = { try await Task.sleep(for: $0) }`), is miscompiled by Swift 6.2 and 6.3: a task that sleeps through
/// that value aborts with "freed pointer was not the last allocation" or a bad access.
public enum RealClock {
    /// Sleeps for `duration` with `custom` when there is one, else on the real clock. Throws when the task is
    /// cancelled first (and whatever `custom` throws).
    public static func sleep(_ duration: Duration, using custom: (@Sendable (Duration) async throws -> Void)?) async throws {
        if let custom {
            try await custom(duration)
        } else {
            try await Task.sleep(for: duration)
        }
    }

    /// Sleeps for `duration` with `custom` when there is one, else on the real clock, returning early when the task
    /// is cancelled.
    public static func sleepUnlessCancelled(_ duration: Duration, using custom: (@Sendable (Duration) async -> Void)?) async {
        if let custom {
            await custom(duration)
        } else {
            try? await Task.sleep(for: duration)
        }
    }
}

import CoreGraphics
import Foundation

/// A compact status shown in the "wings" beside the closed notch.
/// Each module publishes at most one; `ActivityArbiter` picks the single one on screen.
public struct LiveActivity: Identifiable, Equatable, Sendable {
    public enum Priority: Int, Comparable, Sendable, CaseIterable {
        /// Always-on background info (e.g. music is playing).
        case ambient = 0
        /// Time-relevant but not urgent (e.g. meeting in 12 min).
        case passive = 10
        /// Work in flight that the user started (e.g. converting 3/12).
        case progress = 20
        /// Needs the user now (e.g. a Claude session is waiting for permission). The only level shown over fullscreen apps.
        case attention = 30

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable per logical activity, so updates animate in place instead of cross-fading.
    public var id: String
    public var module: ModuleID
    public var priority: Priority
    /// Left wing. Rendered at roughly 18 pt.
    public var leading: ActivityGlyph
    /// Right wing, optional. Keep text to about 6 characters.
    public var trailing: ActivityGlyph?
    /// After this instant the activity is ignored even if the module has not cleared it.
    public var expiresAt: Date?
    /// Tie-breaker between equal priorities: most recently updated wins.
    public var updatedAt: Date
    public var accessibilityLabel: String

    public init(
        id: String, module: ModuleID, priority: Priority, leading: ActivityGlyph, trailing: ActivityGlyph? = nil,
        expiresAt: Date? = nil, updatedAt: Date = .now, accessibilityLabel: String
    ) {
        self.id = id; self.module = module; self.priority = priority; self.leading = leading; self.trailing = trailing
        self.expiresAt = expiresAt; self.updatedAt = updatedAt; self.accessibilityLabel = accessibilityLabel
    }
}

/// What a wing can show. NotchUI owns the rendering so every module looks the same.
public enum ActivityGlyph: Equatable, Sendable {
    /// SF Symbol name.
    case symbol(String, tint: TintRole = .primary, pulse: Bool = false)
    /// Determinate ring, 0...1.
    case progress(Double)
    /// Short text, monospaced digits. Tint carries meaning: `secondary` for neutral information, `success`/`warning` for outcomes.
    case text(String, tint: TintRole = .primary)
    /// Live countdown ("12m", "45s") to a date.
    case countdown(to: Date)
    /// Small rounded thumbnail (album art, image preview).
    case image(SendableImage)
    /// Animated bars for audio.
    case equalizer(playing: Bool)
}

public enum TintRole: Sendable, Equatable, CaseIterable {
    case primary, secondary, accent, success, warning
}

/// A `CGImage` that can cross actors. Images are immutable; equality is identity.
public struct SendableImage: Equatable, @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
    public static func == (a: SendableImage, b: SendableImage) -> Bool { a.cgImage === b.cgImage }
}

public enum ActivityArbiter {
    /// The one activity to show: unexpired, highest priority, then most recently updated, then smallest id.
    /// Over a fullscreen app only `.attention` is eligible.
    public static func select(_ activities: [LiveActivity], now: Date = .now, fullscreen: Bool = false) -> LiveActivity? {
        activities
            .filter { a in
                if let end = a.expiresAt, end <= now { return false }
                return !fullscreen || a.priority == .attention
            }
            .max { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.id > b.id
            }
    }
}

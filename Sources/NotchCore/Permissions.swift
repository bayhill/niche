import Foundation

public struct PermissionRequirement: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        case calendar
        /// Apple Events to one app (Spotify, Music).
        case automation(bundleID: String)
        /// Reading the general pasteboard (macOS may show its own privacy alert).
        case pasteboard
        /// Installing the Claude Code plugin that reports session events.
        case claudeHooks
    }

    public var kind: Kind
    /// Optional requirements improve a module; required ones gate it.
    public var optional: Bool
    /// One sentence shown to the user: what it enables, in their terms.
    public var rationale: String

    public var id: Kind { kind }

    public init(_ kind: Kind, optional: Bool = false, rationale: String) {
        self.kind = kind; self.optional = optional; self.rationale = rationale
    }
}

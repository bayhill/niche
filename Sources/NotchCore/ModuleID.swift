import Foundation

/// Stable identifier of a notch module. Also used as the settings namespace and log category.
public struct ModuleID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let convert: ModuleID = "convert"
    public static let shelf: ModuleID = "shelf"
    public static let clipboard: ModuleID = "clipboard"
    public static let nowPlaying: ModuleID = "nowPlaying"
    public static let calendar: ModuleID = "calendar"
    public static let claudeAgents: ModuleID = "claudeAgents"
}

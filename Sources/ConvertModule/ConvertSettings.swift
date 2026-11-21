import ImageEngine
import NotchCore

/// Persisted conversion settings. The last-used values apply to every drop.
public enum ConvertSettings {
    public static let quality = SettingsKey("convert.quality", default: 80)
    public static let lossless = SettingsKey("convert.lossless", default: false)
    /// `nil` = keep the original size.
    public static let maxPixelEdge = SettingsKey<Int?>("convert.maxPixelEdge", default: nil)
    public static let stripMetadata = SettingsKey("convert.stripMetadata", default: true)

    /// Choices offered for the longest edge.
    public static let maxEdgeChoices: [Int?] = [nil, 1920, 2560, 3840]
    public static let qualityStep = 5

    @MainActor
    public static func options(from store: SettingsStore) -> EncodeOptions {
        EncodeOptions(
            quality: min(100, max(0, store.get(quality))), lossless: store.get(lossless),
            maxPixelEdge: store.get(maxPixelEdge), stripMetadata: store.get(stripMetadata)
        )
    }

    /// "Quality 80 · max 2560 px", "Lossless", "Quality 80 · keep metadata".
    public static func summary(_ o: EncodeOptions) -> String {
        var parts = [o.lossless ? "Lossless" : "Quality \(o.quality)"]
        if let edge = o.maxPixelEdge { parts.append("max \(edge) px") }
        if !o.stripMetadata { parts.append("keep metadata") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Fits the card header: "Q80 · 2560", "Lossless".
    public static func shortSummary(_ o: EncodeOptions) -> String {
        var s = o.lossless ? "Lossless" : "Q\(o.quality)"
        if let edge = o.maxPixelEdge { s += " \u{00B7} \(edge)" }
        return s
    }

    public static func edgeLabel(_ edge: Int?) -> String { edge.map { "\($0) px" } ?? "Original" }
}

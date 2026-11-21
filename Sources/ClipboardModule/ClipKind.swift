import Foundation

/// A colour value copied as text, e.g. `#409EFF`, `#fff` or `rgb(64, 158, 255)`.
public struct ClipColour: Sendable, Equatable {
    /// Components 0...255.
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) { self.red = red; self.green = green; self.blue = blue }

    /// Normalised form: `#409EFF`.
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// What a clip is, for its card's label and preview.
public enum ClipKind: Sendable, Equatable {
    case text
    /// A single web URL. `display` drops the scheme and a trailing slash: `developer.apple.com/documentation`.
    case link(display: String)
    case colour(ClipColour)
    case image

    public var label: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .colour: "Colour"
        case .image: "Image"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .colour: "drop"
        case .image: "photo"
        }
    }

    /// Classifies copied text. Anything ambiguous stays `.text`.
    public static func detect(_ text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return .text }
        if let colour = parseColour(trimmed) { return .colour(colour) }
        if let display = linkDisplay(trimmed) { return .link(display: display) }
        return .text
    }

    // MARK: Links

    static func linkDisplay(_ s: String) -> String? {
        guard !s.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: s), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host, host.contains(".")
        else { return nil }
        var display = String(s.dropFirst(scheme.count + 3))  // "https://"
        if display.hasPrefix("www.") { display.removeFirst(4) }
        if display.hasSuffix("/") { display.removeLast() }
        return display.isEmpty ? nil : display
    }

    // MARK: Colours

    static func parseColour(_ s: String) -> ClipColour? {
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        let lower = s.lowercased()
        for prefix in ["rgba(", "rgb("] where lower.hasPrefix(prefix) && lower.hasSuffix(")") {
            return parseRGB(String(lower.dropFirst(prefix.count).dropLast()), allowAlpha: prefix == "rgba(")
        }
        return nil
    }

    private static func parseHex(_ digits: String) -> ClipColour? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(digits)
        let pairs: [String]
        switch chars.count {
        case 3: pairs = chars.map { "\($0)\($0)" }
        case 6: pairs = stride(from: 0, to: 6, by: 2).map { String(chars[$0..<$0 + 2]) }
        default: return nil
        }
        let values = pairs.compactMap { Int($0, radix: 16) }
        return values.count == 3 ? ClipColour(red: values[0], green: values[1], blue: values[2]) : nil
    }

    /// `64, 158, 255`, `64 158 255`, optionally with an alpha (`, 0.5` or `/ 50%`) which is ignored.
    private static func parseRGB(_ body: String, allowAlpha: Bool) -> ClipColour? {
        let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        guard parts.count == 3 || (parts.count == 4 && (allowAlpha || body.contains("/"))) else { return nil }
        let rgb = parts.prefix(3).compactMap { Int($0) }
        guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return nil }
        if parts.count == 4 {
            let alpha = parts[3].hasSuffix("%") ? Double(parts[3].dropLast()).map { $0 / 100 } : Double(parts[3])
            guard let alpha, (0...1).contains(alpha) else { return nil }
        }
        return ClipColour(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
}

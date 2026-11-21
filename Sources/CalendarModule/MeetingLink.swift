import Foundation

public enum MeetingProvider: String, Sendable, Equatable, CaseIterable {
    case teams, meet, zoom, webex

    public var label: String {
        switch self {
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .webex: "Webex"
        }
    }

    /// SF Symbol for the card header and the wing.
    public var symbol: String {
        switch self {
        case .teams: "person.2.fill"
        case .meet: "video.fill"
        case .zoom: "video.circle.fill"
        case .webex: "web.camera.fill"
        }
    }
}

public struct MeetingLink: Sendable, Equatable {
    public var provider: MeetingProvider
    public var url: URL
    public init(provider: MeetingProvider, url: URL) { self.provider = provider; self.url = url }
}

/// Finds the join link of a video meeting in an event. Pure.
public enum MeetingLinkExtractor {
    /// Looks at the event URL, then the location, then the notes, and returns the first recognised meeting link.
    /// Outlook Safe Links are unwrapped first.
    public static func extract(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = classify(url) { return link }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            for candidate in urls(in: text) {
                if let link = classify(candidate) { return link }
            }
        }
        return nil
    }

    /// The meeting link a single URL stands for, if any.
    public static func classify(_ url: URL) -> MeetingLink? {
        let url = unwrap(url)
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "zoommtg" || scheme == "zoomus" { return MeetingLink(provider: .zoom, url: url) }
        guard scheme == "https" || scheme == "http", let host = url.host()?.lowercased() else { return nil }
        let path = url.path(percentEncoded: true).lowercased()

        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host == "teams.microsoft.com" || host == "teams.cloud.microsoft" {
            if path.hasPrefix("/l/meetup-join") || path.hasPrefix("/meet/") { return MeetingLink(provider: .teams, url: url) }
        }
        if host == "teams.live.com", path.hasPrefix("/meet") { return MeetingLink(provider: .teams, url: url) }
        if host == "meet.google.com", path.count > 1, !path.hasPrefix("/_") { return MeetingLink(provider: .meet, url: url) }
        if isHost("zoom.us") || isHost("zoomgov.com") {
            if ["/j/", "/my/", "/w/", "/wc/join/"].contains(where: path.hasPrefix) { return MeetingLink(provider: .zoom, url: url) }
        }
        if isHost("webex.com"), !["www.webex.com", "help.webex.com", "webex.com"].contains(host), path.count > 1 {
            return MeetingLink(provider: .webex, url: url)
        }
        return nil
    }

    /// Removes Microsoft Safe Links wrappers (`*.safelinks.protection.outlook.com/?url=...` and the Teams
    /// `.../safelinks/...?url=...` page), up to a few levels deep.
    public static func unwrap(_ url: URL) -> URL {
        var current = url
        for _ in 0..<3 {
            guard
                let host = current.host()?.lowercased(),
                host.hasSuffix("safelinks.protection.outlook.com") || current.path().lowercased().contains("safelinks"),
                let components = URLComponents(url: current, resolvingAgainstBaseURL: false),
                let inner = components.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
                let next = URL(string: inner)
            else { break }
            current = next
        }
        return current
    }

    /// Every `scheme://...` run in free text or HTML, in order of appearance.
    public static func urls(in text: String) -> [URL] {
        let decoded = decodeEntities(text)
        let chars = Array(decoded.unicodeScalars)
        var results: [URL] = []
        var i = 0
        while i + 2 < chars.count {
            guard chars[i] == ":", chars[i + 1] == "/", chars[i + 2] == "/" else { i += 1; continue }
            var start = i
            while start > 0, isSchemeChar(chars[start - 1]) { start -= 1 }
            while start < i, !CharacterSet.letters.contains(chars[start]) { start += 1 }
            var end = i + 3
            while end < chars.count, !isDelimiter(chars[end]) { end += 1 }
            var scalars = String.UnicodeScalarView(chars[start..<end])
            while let last = scalars.last, ".,;:!?)]}*".unicodeScalars.contains(last) { scalars.removeLast() }
            let candidate = String(scalars)
            if start < i, end > i + 3, let url = URL(string: candidate) { results.append(url) }
            i = max(end, i + 3)
        }
        return results
    }

    private static func isSchemeChar(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "+" || c == "-" || c == ".")
    }

    private static func isDelimiter(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(c) || "<>\"'`|\\^{}".unicodeScalars.contains(c) || c == "\u{00A0}"
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

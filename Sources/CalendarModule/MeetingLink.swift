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

    /// The meeting link a single URL stands for, if any. Only https links on known meeting hosts are accepted
    /// (http is upgraded); custom schemes such as `zoommtg:` or `msteams:` from invite text are never opened, since
    /// anyone can send an invite. URLs with user info or a non-default port are rejected. The returned URL is rebuilt
    /// from the validated parts.
    public static func classify(_ url: URL) -> MeetingLink? {
        let url = unwrap(url)
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            components.user == nil, components.password == nil,
            components.port == nil || components.port == 443,
            let rawHost = components.percentEncodedHost, !rawHost.isEmpty,
            rawHost.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") })
        else { return nil }
        let host = rawHost.lowercased()
        let path = components.percentEncodedPath
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func rebuilt(query: [URLQueryItem]? = components.queryItems, keepQuery: Bool = true) -> URL? {
            var out = URLComponents()
            out.scheme = "https"
            out.host = host
            out.percentEncodedPath = path
            if keepQuery { out.percentEncodedQuery = components.percentEncodedQuery } else { out.queryItems = query }
            return out.url
        }
        func link(_ provider: MeetingProvider, _ url: URL?) -> MeetingLink? { url.map { MeetingLink(provider: provider, url: $0) } }

        if host == "teams.microsoft.com" || host == "teams.cloud.microsoft" {
            let lower = path.lowercased()
            if lower.hasPrefix("/l/meetup-join/") || lower.hasPrefix("/meet/") { return link(.teams, rebuilt()) }
        }
        if host == "teams.live.com", path.lowercased().hasPrefix("/meet/") { return link(.teams, rebuilt()) }
        if host == "meet.google.com", segments.count == 1, isMeetCode(segments[0]) {
            return link(.meet, rebuilt(query: nil, keepQuery: false))
        }
        if isHost("zoom.us") || isHost("zoomgov.com") {
            // /j/<id>, /w/<id> (webinar), /wc/join/<id>; the id must be numeric. Only the passcode query survives.
            let id: String? = switch segments.map({ $0.lowercased() }) {
            case let s where s.count == 2 && (s[0] == "j" || s[0] == "w"): segments[1]
            case let s where s.count == 3 && s[0] == "wc" && s[1] == "join": segments[2]
            default: nil
            }
            guard let id, (9...12).contains(id.count), id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
            let pwd = components.queryItems?.first(where: { $0.name == "pwd" }).flatMap { item in
                item.value.flatMap { v in v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") } ? item : nil }
            }
            return link(.zoom, rebuilt(query: pwd.map { [$0] }, keepQuery: false))
        }
        if isHost("webex.com"), !["www.webex.com", "help.webex.com", "webex.com"].contains(host), !segments.isEmpty {
            return link(.webex, rebuilt())
        }
        return nil
    }

    /// Google Meet codes look like `abc-defg-hij`.
    private static func isMeetCode(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.map(\.count) == [3, 4, 3] && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLetter && $0.isLowercase } }
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

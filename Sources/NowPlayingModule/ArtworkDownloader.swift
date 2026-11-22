import Foundation

/// Fetches artwork for the Apple Events fallback. The session is ephemeral (no disk cache, cookie store or credential
/// store), so what is playing leaves no trace under `~/Library/Caches`, and a response is capped so a huge one is never
/// held in memory.
public struct ArtworkDownloader: Sendable {
    /// Album art is a few hundred kilobytes; anything past this is not artwork.
    public static let defaultMaxBytes = 4 << 20

    /// The app's downloader: one ephemeral session for its lifetime.
    public static let shared = ArtworkDownloader()

    let session: URLSession
    let maxBytes: Int

    /// - Parameters:
    ///   - configuration: copied, then stripped of every cache and store; tests pass one with a stub `URLProtocol`.
    ///   - maxBytes: the largest body accepted.
    public init(configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = defaultMaxBytes) {
        session = URLSession(configuration: Self.private(configuration))
        self.maxBytes = maxBytes
    }

    /// An ephemeral-style copy: nothing is cached or stored, on disk or in memory.
    static func `private`(_ base: URLSessionConfiguration) -> URLSessionConfiguration {
        // `copy()` of a URLSessionConfiguration always returns one.
        let configuration = (base.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    /// The body of a successful https response of at most `maxBytes`, else `nil`. The address comes from Spotify's
    /// AppleScript reply, so it is fetched over https only, and a redirect away from https is not followed.
    public func data(from url: URL) async -> Data? {
        guard Self.isHTTPS(url) else { return nil }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: HTTPSOnlyRedirects.shared)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url.map(Self.isHTTPS) ?? false,
                  http.expectedContentLength <= Int64(maxBytes)
            else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maxBytes else {
                    bytes.task.cancel()
                    return nil
                }
                data.append(byte)
            }
            return data
        } catch {
            return nil
        }
    }

    static func isHTTPS(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" }
}

/// Refuses a redirect to anything but https.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HTTPSOnlyRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(ArtworkDownloader.isHTTPS) == true ? request : nil
    }
}

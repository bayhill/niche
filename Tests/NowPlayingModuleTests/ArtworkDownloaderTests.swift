import Foundation
@testable import NowPlayingModule
import Synchronization
import Testing

/// Answers every request from a table, so no test reaches the network.
final class StubArtworkProtocol: URLProtocol {
    struct Stub: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Sent instead of a body: a redirect to this address.
        var redirect: String?
    }

    private static let table = Mutex<[String: Stub]>([:])
    private static let log = Mutex<[URLRequest]>([])

    static func stub(_ url: String, _ stub: Stub) { table.withLock { $0[url] = stub } }
    static func requests(host: String) -> [URLRequest] { log.withLock { $0.filter { $0.url?.host() == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.withLock { $0.append(request) }
        guard let url = request.url, let stub = Self.table.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let redirect = stub.redirect, let target = URL(string: redirect) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct ArtworkDownloaderTests {
    /// A host of its own per test, under `.example`, so parallel tests never share stubs.
    let host = "art-\(UUID().uuidString.lowercased()).example"

    func downloader(maxBytes: Int = 1024) -> ArtworkDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubArtworkProtocol.self]
        return ArtworkDownloader(configuration: configuration, maxBytes: maxBytes)
    }

    @Test func theSessionKeepsNothing() {
        for configuration in [ArtworkDownloader.shared.session.configuration, downloader().session.configuration] {
            #expect(configuration.urlCache == nil)
            #expect(configuration.httpCookieStorage == nil)
            #expect(configuration.urlCredentialStorage == nil)
            #expect(!configuration.httpShouldSetCookies)
            #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }
        // Even a default configuration handed in comes out without its disk cache.
        let fromDefault = ArtworkDownloader.private(.default)
        #expect(fromDefault.urlCache == nil)
        #expect(fromDefault.httpCookieStorage == nil)
        #expect(URLSessionConfiguration.default.urlCache != nil) // the caller's configuration is left alone
    }

    @Test func loadsASmallHTTPSResponse() async {
        let body = Data(repeating: 7, count: 600)
        StubArtworkProtocol.stub("https://\(host)/a", .init(headers: ["Content-Length": "600"], chunks: [body]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/a")!) == body)
    }

    @Test func onlyHTTPSIsFetched() async {
        StubArtworkProtocol.stub("http://\(host)/a", .init(chunks: [Data([1])]))
        #expect(await downloader().data(from: URL(string: "http://\(host)/a")!) == nil)
        #expect(await downloader().data(from: URL(string: "file:///etc/hosts")!) == nil)
        #expect(StubArtworkProtocol.requests(host: host).isEmpty)
    }

    @Test func aDeclaredSizeOverTheCapIsRefused() async {
        StubArtworkProtocol.stub("https://\(host)/big", .init(headers: ["Content-Length": "5000"], chunks: [Data(count: 5000)]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/big")!) == nil)
    }

    @Test func anUndeclaredSizeOverTheCapIsCutOff() async {
        let chunks = Array(repeating: Data(count: 400), count: 4) // 1600 bytes, no Content-Length
        StubArtworkProtocol.stub("https://\(host)/stream", .init(chunks: chunks))
        #expect(await downloader().data(from: URL(string: "https://\(host)/stream")!) == nil)
        // Exactly at the cap is still accepted.
        StubArtworkProtocol.stub("https://\(host)/edge", .init(chunks: [Data(count: 1000), Data(count: 24)]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/edge")!)?.count == 1024)
    }

    @Test func anErrorStatusIsNotArtwork() async {
        StubArtworkProtocol.stub("https://\(host)/gone", .init(status: 404, chunks: [Data("not found".utf8)]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/gone")!) == nil)
        #expect(await downloader().data(from: URL(string: "https://\(host)/unstubbed")!) == nil)
    }

    @Test func redirectsStayOnHTTPS() async {
        let body = Data([1, 2, 3])
        StubArtworkProtocol.stub("https://\(host)/moved", .init(redirect: "https://\(host)/here"))
        StubArtworkProtocol.stub("https://\(host)/here", .init(chunks: [body]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/moved")!) == body)

        StubArtworkProtocol.stub("https://\(host)/downgrade", .init(redirect: "http://\(host)/plain"))
        StubArtworkProtocol.stub("http://\(host)/plain", .init(chunks: [body]))
        #expect(await downloader().data(from: URL(string: "https://\(host)/downgrade")!) == nil)
        #expect(!StubArtworkProtocol.requests(host: host).contains { $0.url?.scheme == "http" })
    }
}

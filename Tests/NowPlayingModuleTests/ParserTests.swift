import Foundation
import NotchCore
import NotchCoreTesting
@testable import NowPlayingModule
import Testing

@Suite struct ParserTests {
    @Test func fullPayloadThenDiffs() {
        var parser = AdapterStreamParser()
        let states = parser.feed(StreamFixture.full(StreamFixture.track))
        #expect(states.count == 1)
        let s = try! #require(states[0])
        #expect(s.title == "Weightless")
        #expect(s.artist == "Marconi Union")
        #expect(s.isPlaying)
        #expect(s.bundleID == "com.spotify.client")
        #expect(s.duration == 480)
        #expect(s.elapsed == 12.5)
        #expect(s.timestamp == Date(timeIntervalSince1970: 1_790_000_000))

        // Pause: only the changed key arrives.
        let paused = parser.feed(StreamFixture.diff(["playing": false]))
        #expect(paused.first??.isPlaying == false)
        #expect(paused.first??.title == "Weightless")

        // A vanished key arrives as null and must be removed.
        let noArtist = parser.feed(StreamFixture.diff(["artist": NSNull()]))
        #expect(noArtist.first??.artist == nil)
        #expect(noArtist.first??.album == "Ambient")
    }

    @Test func emptyPayloadMeansNothingPlaying() {
        var parser = AdapterStreamParser()
        _ = parser.feed(StreamFixture.full(StreamFixture.track))
        let states = parser.feed(StreamFixture.full([:]))
        #expect(states.count == 1)
        #expect(states[0] == nil)
    }

    @Test func recordedOutputOnThisMacParses() {
        // Exact first line `stream` printed on macOS 26.6.1 with nothing playing.
        var parser = AdapterStreamParser()
        let states = parser.feed(Data("{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n".utf8))
        #expect(states.count == 1)
        #expect(states[0] == nil)
        #expect(parser.malformedLines == 0)
    }

    @Test func partialLinesAcrossArbitraryChunks() {
        var stream = StreamFixture.full(StreamFixture.track)
        stream.append(StreamFixture.diff(["title": "Electra", "elapsedTimeMicros": 0]))
        stream.append(StreamFixture.diff(["playing": false]))
        for chunkSize in [1, 2, 7, 64, 1000] {
            var parser = AdapterStreamParser()
            var titles: [String?] = []
            var playing: [Bool?] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + chunkSize)
                for state in parser.feed(stream.subdata(in: offset..<end)) {
                    titles.append(state?.title); playing.append(state?.isPlaying)
                }
                offset = end
            }
            #expect(titles == ["Weightless", "Electra", "Electra"], "chunk size \(chunkSize)")
            #expect(playing == [true, true, false], "chunk size \(chunkSize)")
        }
    }

    @Test func lineWithoutNewlineWaits() {
        var parser = AdapterStreamParser()
        var data = StreamFixture.full(StreamFixture.track)
        data.removeLast()
        #expect(parser.feed(data).isEmpty)
        #expect(parser.feed(Data([0x0A])).count == 1)
    }

    @Test func garbageAndOtherTypesAreSkipped() {
        var parser = AdapterStreamParser()
        var data = Data("not json\n\n".utf8)
        data.append(StreamFixture.line(["type": "other", "payload": [:] as [String: Any]]))
        data.append(StreamFixture.full(StreamFixture.track))
        let states = parser.feed(data)
        #expect(states.count == 1)
        #expect(states[0]?.title == "Weightless")
        #expect(parser.malformedLines == 2)
    }

    @Test func missingTitleOrBundleIsNothing() {
        var parser = AdapterStreamParser()
        var payload = StreamFixture.track
        payload["title"] = ""
        #expect(parser.feed(StreamFixture.full(payload)) == [nil])
        payload = StreamFixture.track
        payload.removeValue(forKey: "bundleIdentifier")
        #expect(parser.feed(StreamFixture.full(payload)) == [nil])
    }

    @Test func parentBundleWins() {
        var parser = AdapterStreamParser()
        var payload = StreamFixture.track
        payload["bundleIdentifier"] = "com.apple.WebKit.GPU"
        payload["parentApplicationBundleIdentifier"] = "com.apple.Safari"
        #expect(parser.feed(StreamFixture.full(payload)).first??.bundleID == "com.apple.Safari")
    }

    @Test func artworkDecodesOnceAndIsReusedAcrossDiffs() throws {
        let png = TestImage.data(TestImage.solid(width: 600, height: 600, red: 0.2, green: 0.4, blue: 0.9))
        var payload = StreamFixture.track
        payload["artworkData"] = png.base64EncodedString()
        var parser = AdapterStreamParser(artworkPixelSize: 128)
        let first = try #require(parser.feed(StreamFixture.full(payload)).first ?? nil)
        let art = try #require(first.artwork)
        #expect(max(art.cgImage.width, art.cgImage.height) <= 128)
        let second = try #require(parser.feed(StreamFixture.diff(["playing": false])).first ?? nil)
        #expect(second.artwork == first.artwork) // identity: not decoded again
        let third = try #require(parser.feed(StreamFixture.diff(["artworkData": NSNull()])).first ?? nil)
        #expect(third.artwork == nil)
    }

    @Test func artworkDecoderRejectsJunk() {
        #expect(ArtworkDecoder.decode(base64: "%%%") == nil)
        #expect(ArtworkDecoder.decode(base64: Data("hello".utf8).base64EncodedString()) == nil)
        let jpeg = TestImage.data(TestImage.solid(width: 300, height: 200), type: .jpeg)
        let image = ArtworkDecoder.decode(data: jpeg, maxPixelSize: 100)
        #expect(image?.cgImage.width == 100)
        #expect(image?.cgImage.height == 67)
    }

    @Test func resetForgetsState() {
        var parser = AdapterStreamParser()
        _ = parser.feed(StreamFixture.full(StreamFixture.track))
        parser.reset()
        #expect(parser.current == nil)
        // A diff after reset applies to an empty state.
        #expect(parser.feed(StreamFixture.diff(["playing": true])) == [nil])
    }
}

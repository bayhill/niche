import Foundation
import Testing
@testable import ClaudeAgentsModule

@Suite struct RegistryParsingTests {
    @Test func parsesSanitisedRealSamples() throws {
        let busy = try #require(RegistryRecord.parse(Data(Fixture.busyAuto.utf8), fileName: "4242.json"))
        #expect(busy.pid == 4242)
        #expect(busy.sessionID == "11111111-aaaa-4bbb-8ccc-000000000001")
        #expect(busy.cwd == "/Users/dev/projects/demo")
        #expect(busy.name == "build-demo-app" && busy.nameSource == "auto")
        #expect(busy.status == "busy" && busy.entrypoint == "cli" && busy.kind == "interactive" && busy.version == "2.1.330")
        #expect(busy.statusUpdatedAt == Date(timeIntervalSince1970: 1_795_283_522.055))
        #expect(busy.startedAt == Date(timeIntervalSince1970: 1_795_280_402.474))
        #expect(busy.procStart == "Sat Nov 21 16:59:57 2026")

        let idle = try #require(RegistryRecord.parse(Data(Fixture.idleDerived.utf8)))
        #expect(idle.status == "idle" && idle.nameSource == "derived")
        let shell = try #require(RegistryRecord.parse(Data(Fixture.shell.utf8)))
        #expect(shell.status == "shell")
        let code = try #require(RegistryRecord.parse(Data(Fixture.vscode.utf8)))
        #expect(Entrypoint(code.entrypoint) == .vscode)
        #expect(Liveness.parseProcStart(code.procStart!) != nil, "double space before the day must parse")
    }

    @Test func rejectsOnlyWhatCannotBeASession() {
        #expect(RegistryRecord.parse(Data("not json".utf8)) == nil)
        #expect(RegistryRecord.parse(Data("[1,2]".utf8)) == nil)
        #expect(RegistryRecord.parse(Data("{}".utf8)) == nil, "no pid anywhere")
        #expect(RegistryRecord.parse(Data(#"{"pid":-3}"#.utf8)) == nil)
    }

    @Test func toleratesMissingAndOddFields() throws {
        let fromName = try #require(RegistryRecord.parse(Data(#"{"status":"idle"}"#.utf8), fileName: "777.json"))
        #expect(fromName.pid == 777 && fromName.sessionID == "pid:777")
        let strings = try #require(RegistryRecord.parse(Data(#"{"pid":"12","sessionId":"x","startedAt":"1795280402474","updatedAt":1795280402,"statusUpdatedAt":"2026-11-21T17:00:00Z","name":42}"#.utf8)))
        #expect(strings.pid == 12)
        #expect(strings.startedAt == Date(timeIntervalSince1970: 1_795_280_402.474))
        #expect(strings.updatedAt == Date(timeIntervalSince1970: 1_795_280_402), "seconds are accepted too")
        #expect(strings.statusUpdatedAt != nil)
        #expect(strings.name == "42")
    }

    @Test func futureShapedFilesKeepTheSession() throws {
        let json = #"{"pid":9,"sessionId":"f","status":"hibernating","waitingFor":"permission prompt","newField":{"a":[1]},"spare":false,"tempo":"active","entrypoint":"claude-holo"}"#
        let r = try #require(RegistryRecord.parse(Data(json.utf8)))
        #expect(r.status == "hibernating")
        #expect(Entrypoint(r.entrypoint) == .other("claude-holo"))
        #expect(SessionReducer.signal(for: r) == nil, "unknown status: no opinion, but the session stays")
        var reducer = SessionReducer()
        reducer.applyRegistry(RegistrySnapshot(records: [r], available: true))
        #expect(reducer.sessions(now: .now).map(\.id) == ["f"])
    }

    @Test func waitingStatusMapsToNeedsUser() {
        var r = Fixture.record(status: "waiting", at: 0, waitingFor: "permission prompt")
        #expect(SessionReducer.signal(for: r) == .needsPermission(nil))
        r.waitingFor = "input needed"
        #expect(SessionReducer.signal(for: r) == .needsInput("input needed"))
        r.waitingFor = nil
        #expect(SessionReducer.signal(for: r) == .needsInput(nil))
        r.status = "busy"; r.tempo = "blocked"; r.needs = "answer: which database"
        #expect(SessionReducer.signal(for: r) == .needsInput("answer: which database"))
    }
}

@Suite struct LivenessTests {
    let me = ProcessInfo.processInfo.processIdentifier
    let system = SystemProcessInspector()

    func lstart(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: date)
    }

    @Test func ownProcessIsLive() throws {
        let started = try #require(system.startTime(of: me))
        #expect(started <= Date())
        let utc = RegistryRecord(pid: me, sessionID: "me", procStart: lstart(started, zone: TimeZone(identifier: "UTC")!))
        #expect(Liveness.isLive(utc, inspector: system))
        let local = RegistryRecord(pid: me, sessionID: "me", procStart: lstart(started, zone: .current))
        #expect(Liveness.isLive(local, inspector: system))
        let viaStartedAt = RegistryRecord(pid: me, sessionID: "me", startedAt: started.addingTimeInterval(4))
        #expect(Liveness.isLive(viaStartedAt, inspector: system))
        #expect(Liveness.isLive(RegistryRecord(pid: me, sessionID: "me"), inspector: system))
        #expect(system.parent(of: me) != nil)
    }

    @Test func deadProcessIsNotLive() throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        let pid = p.processIdentifier
        #expect(system.startTime(of: pid) == nil)
        #expect(!Liveness.isLive(RegistryRecord(pid: pid, sessionID: "gone"), inspector: system))
    }

    @Test func mismatchedStartTimeMeansRecycledPid() throws {
        let started = try #require(system.startTime(of: me))
        let older = RegistryRecord(pid: me, sessionID: "old", procStart: lstart(started.addingTimeInterval(-86_400), zone: TimeZone(identifier: "UTC")!))
        #expect(!Liveness.isLive(older, inspector: system))
        let sessionBeforeProcess = RegistryRecord(pid: me, sessionID: "old", startedAt: started.addingTimeInterval(-600))
        #expect(!Liveness.isLive(sessionBeforeProcess, inspector: system))
    }

    @Test func readerSkipsStaleSpareAndBrokenFilesWithoutDeleting() throws {
        let dir = try Fixture.tempDir("registry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = try #require(system.startTime(of: me))
        let ms = Int(started.timeIntervalSince1970 * 1000) + 3000
        func write(_ name: String, _ body: String) throws { try Data(body.utf8).write(to: dir.appending(path: name)) }
        try write("\(me).json", #"{"pid":\#(me),"sessionId":"live","cwd":"/Users/dev/projects/demo","startedAt":\#(ms),"status":"busy","statusUpdatedAt":\#(ms)}"#)
        try write("recycled.json", #"{"pid":\#(me),"sessionId":"recycled","startedAt":\#(ms - 900_000),"status":"idle"}"#)
        try write("99999.json", #"{"pid":99999999,"sessionId":"dead","status":"idle"}"#)
        try write("spare.json", #"{"pid":\#(me),"sessionId":"spare","startedAt":\#(ms),"spare":true}"#)
        try write("dup.json", #"{"pid":\#(me),"sessionId":"live","startedAt":\#(ms),"status":"idle","statusUpdatedAt":\#(ms - 60_000)}"#)
        try write("garbage.json", "{{{")
        try write("123.key", "secret")
        let snapshot = RegistryReader(directory: dir, inspector: system).read()
        #expect(snapshot.available)
        #expect(snapshot.records.map(\.sessionID) == ["live"])
        #expect(snapshot.records.first?.status == "busy", "the most recently updated duplicate wins")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 7, "nothing is deleted")

        let missing = RegistryReader(directory: dir.appending(path: "nope"), inspector: system).read()
        #expect(!missing.available && missing.records.isEmpty)
    }

    @Test func ancestryFindsFirstApp() {
        let inspector = FakeInspector(parents: [500: 400, 400: 300, 300: 200, 200: 1])
        #expect(ProcessAncestry.hostApp(of: 500, inspector: inspector) { $0 == 300 } == 300)
        #expect(ProcessAncestry.hostApp(of: 500, inspector: inspector) { _ in false } == nil)
        let loop = FakeInspector(parents: [10: 11, 11: 10])
        #expect(ProcessAncestry.hostApp(of: 10, inspector: loop) { _ in false } == nil)
    }
}

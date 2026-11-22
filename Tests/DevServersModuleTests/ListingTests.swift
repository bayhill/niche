import Foundation
import NotchCore
import NotchCoreTesting
import Synchronization
import Testing
@testable import DevServersModule

/// Invented `lsof -F pcn` output: a node server on both loopbacks, a python server on all interfaces with an
/// inspector port on loopback, and a ruby server on one LAN address. Includes fields `parse` must skip.
let lsofFixture = """
p1201
cnode
f23
n127.0.0.1:5173
TST=LISTEN
TQR=0
TQS=0
f24
n[::1]:5173
TST=LISTEN
p1305
cpython3
f5
n*:8000
f6
n[::]:8000
f7
n127.0.0.1:9229
p1410
cruby
f9
n192.168.10.20:4000
tIPv4
"""

/// Answers from a table, which a test may change; counts lookups.
final class FakeInspector: ProcessInspecting {
    private let state: Mutex<(table: [Int32: ProcessDetails], lookups: [Int32])>

    init(_ table: [Int32: ProcessDetails] = [:]) { state = Mutex((table, [])) }

    func details(of pid: Int32) -> ProcessDetails? {
        state.withLock { $0.lookups.append(pid); return $0.table[pid] }
    }

    func set(_ pid: Int32, _ details: ProcessDetails?) { state.withLock { $0.table[pid] = details } }
    var lookups: [Int32] { state.withLock { $0.lookups } }
}

@Suite struct ListingTests {
    @Test func argumentsAskForListeningTCPSocketsOfOneUserInFieldFormat() {
        #expect(Listing.lsofArguments(uid: 777) == ["-nP", "-w", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "777", "-F", "pcn"])
    }

    @Test func parsesProcessesAndAddresses() {
        let sockets = Listing.parse(lsofFixture)
        #expect(sockets == [
            ListeningSocket(pid: 1201, command: "node", host: "127.0.0.1", port: 5173),
            ListeningSocket(pid: 1201, command: "node", host: "[::1]", port: 5173),
            ListeningSocket(pid: 1305, command: "python3", host: "*", port: 8000),
            ListeningSocket(pid: 1305, command: "python3", host: "[::]", port: 8000),
            ListeningSocket(pid: 1305, command: "python3", host: "127.0.0.1", port: 9229),
            ListeningSocket(pid: 1410, command: "ruby", host: "192.168.10.20", port: 4000),
        ])
    }

    @Test func skipsWhatDoesNotParse() {
        let text = """
        n127.0.0.1:1111
        pnot-a-pid
        n127.0.0.1:2222
        p42
        cx
        n127.0.0.1:3333->127.0.0.1:50000
        n*:*
        n127.0.0.1:0
        n127.0.0.1:70000
        n:8080
        n127.0.0.1:4444
        n127.0.0.1:4444

        """
        #expect(Listing.parse(text) == [ListeningSocket(pid: 42, command: "x", host: "127.0.0.1", port: 4444)])
        #expect(Listing.parse("").isEmpty)
    }

    @Test func addressSplitsAtTheLastColon() {
        #expect(Listing.address("[fe80::1%lo0]:8080")?.host == "[fe80::1%lo0]")
        #expect(Listing.address("[fe80::1%lo0]:8080")?.port == 8080)
        #expect(Listing.address("*:3000")?.host == "*")
        #expect(Listing.address("3000") == nil)
    }

    @Test func groupsOneServerPerProcessAndPortSortedByPort() {
        let groups = Listing.group(Listing.parse(lsofFixture))
        #expect(groups.map(\.id) == [
            DevServer.ID(pid: 1410, port: 4000), DevServer.ID(pid: 1201, port: 5173),
            DevServer.ID(pid: 1305, port: 8000), DevServer.ID(pid: 1305, port: 9229),
        ])
        #expect(groups[1].hosts == ["127.0.0.1", "[::1]"])
        #expect(groups[2].hosts == ["*", "[::]"])
        #expect(groups[2].command == "python3")
    }

    @Test func twoProcessesOnOnePortAreTwoServers() {
        let sockets = [
            ListeningSocket(pid: 9, command: "b", host: "*", port: 80),
            ListeningSocket(pid: 3, command: "a", host: "*", port: 80),
        ]
        #expect(Listing.group(sockets).map(\.id.pid) == [3, 9])
    }

    @Test func reachOfHosts() {
        #expect(Reach.of(host: "127.0.0.1") == .loopback)
        #expect(Reach.of(host: "127.0.0.2") == .loopback)
        #expect(Reach.of(host: "[::1]") == .loopback)
        #expect(Reach.of(host: "[::ffff:127.0.0.1]") == .loopback)
        #expect(Reach.of(host: "localhost") == .loopback)
        #expect(Reach.of(host: "*") == .allInterfaces)
        #expect(Reach.of(host: "0.0.0.0") == .allInterfaces)
        #expect(Reach.of(host: "[::]") == .allInterfaces)
        #expect(Reach.of(host: "192.168.10.20") == .address)
        #expect(Reach.of(host: "[fe80::1%en0]") == .address)
        #expect(!Reach.loopback.isExposed)
        #expect(Reach.address.isExposed && Reach.allInterfaces.isExposed)
    }

    @Test func aServerIsAsExposedAsItsWidestSocket() {
        #expect(DevServer(pid: 1, port: 1, command: "x", hosts: ["127.0.0.1", "[::1]"]).reach == .loopback)
        #expect(DevServer(pid: 1, port: 1, command: "x", hosts: ["[::1]", "*"]).reach == .allInterfaces)
        let lan = DevServer(pid: 1, port: 1, command: "x", hosts: ["127.0.0.1", "192.168.10.20"])
        #expect(lan.reach == .address)
        #expect(lan.exposedHost == "192.168.10.20")
    }

    @Test func names() {
        let server = DevServer(
            pid: 1, port: 5173, command: "node-trunc", executablePath: "/opt/tools/bin/node",
            workingDirectory: "/Users/sample/Projects/storefront"
        )
        #expect(server.processName == "node")
        #expect(server.projectName == "storefront")
        #expect(server.portText == ":5173")
        #expect(server.address == "http://localhost:5173")
        let bare = DevServer(pid: 1, port: 80, command: "httpd", workingDirectory: "/")
        #expect(bare.processName == "httpd")
        #expect(bare.projectName == nil)
    }
}

@Suite struct FilterTests {
    let home = "/Users/sample"

    private func server(cwd: String?, exe: String?) -> DevServer {
        DevServer(pid: 1, port: 3000, command: "x", executablePath: exe, workingDirectory: cwd)
    }

    @Test func workingDirectoryMustBeInsideHomeButNotHome() {
        #expect(DevServerFilter.isProjectFolder("/Users/sample/Projects/api", home: home))
        #expect(DevServerFilter.isProjectFolder("/Users/sample/api/", home: home + "/"))
        #expect(!DevServerFilter.isProjectFolder("/Users/sample", home: home))
        #expect(!DevServerFilter.isProjectFolder("/Users/sample/", home: home))
        #expect(!DevServerFilter.isProjectFolder("/Users/samplex/api", home: home))
        #expect(!DevServerFilter.isProjectFolder("/", home: home))
        #expect(!DevServerFilter.isProjectFolder("/private/tmp/api", home: home))
        #expect(!DevServerFilter.isProjectFolder(nil, home: home))
        #expect(!DevServerFilter.isProjectFolder("/Users/sample/api", home: ""))
        #expect(!DevServerFilter.isProjectFolder("/Users/sample/api", home: "/"))
    }

    @Test func appsAndSystemExecutablesAreLeftOut() {
        for path in [
            "/Applications/Editor.app/Contents/MacOS/Editor",
            "/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            "/Users/sample/Applications/Player.app/Contents/MacOS/Player",
            "/Applications/Tool.app/Contents/Resources/bin/node",
            "/System/Library/CoreServices/Agent",
            "/usr/libexec/daemon",
            "/Library/Application Support/Vendor/agent",
        ] {
            #expect(DevServerFilter.isAppOrSystem(path), "\(path)")
        }
    }

    @Test func toolsAndInterpretersAreKept() {
        for path in [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/ruby",
            "/Users/sample/.local/share/node/v22/bin/node",
            "/Users/sample/Projects/api/.build/debug/api",
            "/usr/bin/ruby",
            // Python runs from a Python.app inside its framework, wherever it was installed from.
            "/opt/homebrew/Cellar/python/3.13/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
            "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
            "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
            "/Library/Developer/CommandLineTools/usr/bin/tool",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/tool",
        ] {
            #expect(!DevServerFilter.isAppOrSystem(path), "\(path)")
        }
        #expect(!DevServerFilter.isAppOrSystem(nil))
    }

    @Test func aDevServerNeedsBoth() {
        #expect(DevServerFilter.isDevServer(server(cwd: "/Users/sample/Projects/api", exe: "/usr/local/bin/node"), home: home))
        #expect(DevServerFilter.isDevServer(server(cwd: "/Users/sample/Projects/api", exe: nil), home: home))
        #expect(!DevServerFilter.isDevServer(server(cwd: "/", exe: "/usr/local/bin/node"), home: home))
        #expect(!DevServerFilter.isDevServer(server(cwd: "/Users/sample", exe: "/usr/local/bin/node"), home: home))
        #expect(!DevServerFilter.isDevServer(
            server(cwd: "/Users/sample/Projects/api", exe: "/Applications/Editor.app/Contents/MacOS/Editor"), home: home
        ))
    }
}

@Suite struct ScannerTests {
    private let inspector = FakeInspector([
        1201: ProcessDetails(
            executablePath: "/usr/local/bin/node", workingDirectory: "/Users/sample/Projects/storefront",
            startTime: ProcessStartTime(seconds: 100)
        ),
        1305: ProcessDetails(
            executablePath: "/usr/local/bin/python3", workingDirectory: "/Users/sample/Projects/api",
            startTime: ProcessStartTime(seconds: 200)
        ),
    ])

    @Test func runsLsofAndFillsInEachProcessOnce() async throws {
        let runner = ScriptedCommandRunner { _ in CommandResult(status: 0, stdout: Data(lsofFixture.utf8)) }
        let scanner = LsofScanner(runner: runner, inspector: inspector, uid: 777)
        let servers = try await scanner.scan()
        #expect(runner.calls.map(\.executable) == [URL(fileURLWithPath: "/usr/sbin/lsof")])
        #expect(runner.calls.first?.arguments == Listing.lsofArguments(uid: 777))
        #expect(servers.map(\.portText) == [":4000", ":5173", ":8000", ":9229"])
        #expect(inspector.lookups.sorted() == [1201, 1305, 1410])

        let python = servers[2]
        #expect(python.projectName == "api")
        #expect(python.processName == "python3")
        #expect(python.startTime == ProcessStartTime(seconds: 200))
        #expect(python.reach == .allInterfaces)
        // A process the inspector knows nothing about keeps what lsof said.
        #expect(servers[0].processName == "ruby")
        #expect(servers[0].workingDirectory == nil)
        #expect(servers[0].reach == .address)
    }

    @Test func nothingListeningIsAnEmptyList() async throws {
        let scanner = LsofScanner(runner: ScriptedCommandRunner { _ in CommandResult(status: 1) }, inspector: inspector, uid: 1)
        #expect(try await scanner.scan().isEmpty)
    }

    @Test func aPartialListingStillCounts() async throws {
        let runner = ScriptedCommandRunner { _ in CommandResult(status: 1, stdout: Data("p1201\ncnode\nn*:3000\n".utf8)) }
        let scanner = LsofScanner(runner: runner, inspector: inspector, uid: 1)
        #expect(try await scanner.scan().map(\.port) == [3000])
    }

    @Test func failuresThrow() async {
        for result in [
            CommandResult(status: -1),
            CommandResult(status: 0, stdout: Data(lsofFixture.utf8), timedOut: true),
            CommandResult(status: 2),
        ] {
            let scanner = LsofScanner(runner: ScriptedCommandRunner { _ in result }, inspector: inspector, uid: 1)
            await #expect(throws: ScanError.listingFailed) { try await scanner.scan() }
        }
    }
}

/// Reads this test process only, which is neither a server nor anyone else's.
@Suite struct LibprocTests {
    @Test func readsTheTestProcessItself() throws {
        let details = try #require(LibprocInspector().details(of: getpid()))
        #expect(details.executablePath?.hasPrefix("/") == true)
        #expect(details.startTime != nil)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(details.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == cwd)
        // The same process reads the same start time twice.
        #expect(LibprocInspector().details(of: getpid())?.startTime == details.startTime)
    }

    @Test func noProcessNoDetails() {
        #expect(LibprocInspector().details(of: 0) == nil)
        #expect(LibprocInspector().details(of: -5) == nil)
    }
}

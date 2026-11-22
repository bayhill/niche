@testable import DevServersModule
import Foundation
import NotchCore
import NotchCoreTesting
import Testing

/// Writes the page in each state to $TMPDIR/niche-snapshots for visual review.
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "niche-snapshots", directoryHint: .isDirectory)

    private func write(_ module: DevServersModule, _ name: String) throws {
        let url = try ViewSnapshot.write(
            DevServersPage(module: module, scrolls: false), size: PanelLayout.pageSize,
            to: Self.dir.appending(path: "devservers-\(name).png")
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Ten invented listeners: dev servers, and processes listed only with `showAll`.
    private static var crowd: [DevServer] {
        let projects = ["storefront", "api", "docs", "admin-dashboard-with-a-long-name", "worker", "blog"]
        var servers = projects.enumerated().map { index, name in
            DevServer(
                pid: Int32(3000 + index), port: [5173, 8000, 3000, 4321, 9000, 4000][index], command: "node",
                executablePath: "/usr/local/bin/\(index == 1 ? "python3" : "node")",
                workingDirectory: "\(home)/Projects/\(name)", startTime: ProcessStartTime(seconds: UInt64(index + 1)),
                hosts: index == 2 ? ["*"] : (index == 5 ? ["192.168.10.20"] : ["127.0.0.1"])
            )
        }
        servers.append(DevServer(
            pid: 3100, port: 6463, command: "Helper", executablePath: "/Applications/Chat.app/Contents/MacOS/Helper",
            workingDirectory: "/", startTime: ProcessStartTime(seconds: 50), hosts: ["127.0.0.1"]
        ))
        servers.append(DevServer(
            pid: 3101, port: 50_421, command: "agent", executablePath: "/Library/Application Support/Vendor/agent",
            workingDirectory: "/", startTime: ProcessStartTime(seconds: 60), hosts: ["*"]
        ))
        return servers.sorted { $0.port < $1.port }
    }

    @Test func pages() async throws {
        let env = try TestEnvironment(); defer { env.cleanUp() }

        let sample = DevServersModule.sample()
        await sample.start(env.context(for: .devServers))
        try write(sample, "sample")

        sample.copy(sample.servers[1])
        try write(sample, "copied")
        sample.requestStop(sample.servers[0])
        try write(sample, "confirm-stop")
        sample.stop()

        let empty = makeModule(FakeScanner())
        await empty.start(env.context(for: .devServers))
        await empty.refresh()
        try write(empty, "empty")

        let waiting = makeModule(FakeScanner())
        try write(waiting, "waiting")

        let failing = FakeScanner()
        failing.setFails(true)
        let failed = makeModule(failing)
        await failed.start(env.context(for: .devServers))
        await failed.refresh()
        try write(failed, "failed")

        let one = makeModule(FakeScanner([storefront]))
        await one.start(env.context(for: .devServers))
        await one.refresh()
        try write(one, "one")

        let crowded = makeModule(FakeScanner(Self.crowd))
        await crowded.start(env.context(for: .devServers))
        await crowded.refresh()
        try write(crowded, "many")
        env.settings.set(DevServersModule.showAllKey, true)
        try write(crowded, "show-all")

        for module in [empty, failed, one, crowded] { module.stop() }
        print("snapshots in \(Self.dir.path)")
    }
}

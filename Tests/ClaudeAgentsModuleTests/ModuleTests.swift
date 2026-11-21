import AppKit
import Foundation
import NotchCore
import NotchCoreTesting
import SwiftUI
import Testing
@testable import ClaudeAgentsModule

@MainActor
final class RecordingActivator: SessionActivating {
    var pids: [Int32] = []
    func activateHost(ofProcess pid: Int32) -> Bool { pids.append(pid); return true }
}

@MainActor
@Suite struct ModuleTests {
    @Test func shapeMatchesTheContract() {
        let m = ClaudeAgentsModule.sample()
        #expect(m.id == .claudeAgents)
        #expect(m.placement == .dashboard(.leadingBottom))
        #expect(PanelLayout.cardSize(for: .leadingBottom) == CGSize(width: 210, height: 87))
        #expect(ClaudeAgentsModule.visibleLimit == 2)
        #expect(m.requirements == [PermissionRequirement(.claudeHooks, optional: true, rationale: m.requirements[0].rationale)])
        #expect(m.settingsView() != nil)
        #expect(m.dropAcceptance(for: .text("x")) == .reject)
    }

    @Test func sampleHasEveryStateAndAnAttentionActivity() {
        let m = ClaudeAgentsModule.sample()
        let states = m.sessions.map(\.state)
        #expect(states.contains { if case .needsPermission = $0 { true } else { false } })
        #expect(states.contains { if case .needsInput = $0 { true } else { false } })
        #expect(states.contains(.working))
        #expect(states.contains { if case .finished = $0 { true } else { false } })
        #expect(states.contains { if case .idle = $0 { true } else { false } })
        #expect(m.sessions.prefix(2).allSatisfy { $0.state.needsUser })
        #expect(m.liveActivity?.priority == .attention)
        #expect(m.liveActivity?.trailing == .text("2"))
        let card = SessionCardContent.make(sessions: m.sessions, alerts: m.alertsState)
        #expect(card.rows.count == 2 && card.hiddenCount == 3 && card.showsEnableAlerts)
    }

    @Test func liveModuleReadsRegistryAndSpoolFromInjectedDirectories() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let me = ProcessInfo.processInfo.processIdentifier
        let started = try #require(SystemProcessInspector().startTime(of: me))
        let ms = Int(started.timeIntervalSince1970 * 1000)  // in the past, so the hook event below is newer
        let sessions = env.directories.home.appending(path: ".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"pid":\#(me),"sessionId":"s1","cwd":"/Users/dev/projects/demo","name":"demo-task","nameSource":"auto","startedAt":\#(ms),"status":"busy","statusUpdatedAt":\#(ms),"entrypoint":"cli"}"#.utf8)
            .write(to: sessions.appending(path: "\(me).json"))
        let spool = env.directories.appSupport.appending(path: "claude-events")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let eventFile = spool.appending(path: "1-1-1.json")
        try Fixture.hook("PermissionRequest", extra: #","tool_name":"Bash""#).write(to: eventFile)

        let activator = RecordingActivator()
        let runner = RecordingRunner(settings: env.directories.home.appending(path: ".claude/settings.json"))
        let module = ClaudeAgentsModule(
            directories: nil, bundledPlugin: nil, runner: runner, activator: activator, pollInterval: .seconds(60)
        )
        var opened: [ModuleID?] = []
        env.services.openSettings = { opened.append($0) }
        env.settings.set(ClaudeAgentsModule.alertsEnabled, true)
        await module.start(env.context(for: .claudeAgents))
        await module.refresh()

        let session = try #require(module.sessions.first)
        #expect(module.sessions.count == 1)
        #expect(session.title == "demo-task" && session.pid == me && session.entrypoint == .cli)
        #expect(session.state == .needsPermission(detail: "Bash"))
        #expect(module.liveActivity?.priority == .attention)
        #expect(!FileManager.default.fileExists(atPath: eventFile.path), "spool file consumed")
        #expect(module.hookStatus == .cliNotFound || module.hookStatus == .notInstalled)

        module.activate(session)
        #expect(activator.pids == [me])
        module.openAlertSettings()
        #expect(opened == [.claudeAgents])

        try Fixture.hook("PostToolUse", extra: #","tool_name":"Bash""#).write(to: spool.appending(path: "2-1-1.json"))
        await module.refresh()
        #expect(module.sessions.first?.state == .working)
        #expect(module.liveActivity == nil)
        module.stop()
        await module.start(env.context(for: .claudeAgents))
        module.stop()
        #expect(await runner.calls.isEmpty, "starting never installs anything")
    }

    /// Builds a module around a real HookInstaller in temp dirs with a recording runner (no real `claude`).
    func installerModule(_ env: TestEnvironment, failOn: String? = nil) throws -> (ClaudeAgentsModule, RecordingRunner, HookInstaller.Paths) {
        let fm = FileManager.default
        let cli = env.directories.home.appending(path: ".local/bin/claude")
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.directories.home.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let paths = HookInstaller.Paths.standard(directories: env.directories, bundledPlugin: Fixture.repoRoot.appending(path: "Support/ClaudePlugin"), searchPath: "")
        let runner = RecordingRunner(settings: paths.claudeSettings, failOn: failOn)
        let installer = HookInstaller(paths: paths, runner: runner, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let module = ClaudeAgentsModule(directories: env.directories, bundledPlugin: nil, runner: runner, activator: RecordingActivator(),
                                        installer: installer, pollInterval: .seconds(60))
        return (module, runner, paths)
    }

    @Test func spoolExistsOnlyWhileRunningWithAlertsOn() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let (module, _, paths) = try installerModule(env)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.spool, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.spool.appending(path: "left-from-a-crash.json"))
        await module.start(env.context(for: .claudeAgents))
        #expect(!fm.fileExists(atPath: paths.spool.path), "alerts off: a leftover spool is removed at start")
        #expect(module.alertsState == .off)

        await module.installHooks()
        #expect(module.lastResult?.succeeded == true)
        #expect(env.settings.get(ClaudeAgentsModule.alertsEnabled))
        #expect(module.alertsState == .on)
        #expect(fm.fileExists(atPath: paths.spool.path))

        module.stop()
        #expect(!fm.fileExists(atPath: paths.spool.path), "stop removes the spool, so a quit or disabled app collects nothing")
        await module.start(env.context(for: .claudeAgents))
        #expect(fm.fileExists(atPath: paths.spool.path), "start after stop works and recreates it")
        try Fixture.hook("Stop").write(to: paths.spool.appending(path: "1-1-1.json"))
        await module.refresh()
        #expect(try fm.contentsOfDirectory(atPath: paths.spool.path).isEmpty)
        module.stop()
        module.stop()
        #expect(!fm.fileExists(atPath: paths.spool.path))
    }

    @Test func failedRemovalStaysOffAcrossRestarts() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let (module, _, paths) = try installerModule(env, failOn: "uninstall")
        await module.start(env.context(for: .claudeAgents))
        await module.installHooks()
        #expect(module.alertsState == .on)
        await module.uninstallHooks()
        #expect(module.lastResult?.succeeded == false)
        #expect(!env.settings.get(ClaudeAgentsModule.alertsEnabled))
        #expect(module.alertsState == .offStillRegistered, "honest: off, but still registered in Claude Code")
        #expect(!FileManager.default.fileExists(atPath: paths.spool.path))
        module.stop()
        await module.start(env.context(for: .claudeAgents))
        #expect(!FileManager.default.fileExists(atPath: paths.spool.path), "a relaunch does not re-enable collection")
        #expect(module.alertsState == .offStillRegistered)
        module.stop()
    }

    @Test func installNeedsTheSettingsStore() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let (module, runner, _) = try installerModule(env)
        #expect(!module.canChangeAlerts)
        await module.installHooks()
        #expect(await runner.calls.isEmpty, "not started: nothing to record the choice in, so nothing runs")
    }

    @Test func alertsStateTable() {
        #expect(AlertsState(enabled: true, hookStatus: .installed) == .on)
        #expect(AlertsState(enabled: false, hookStatus: .installed) == .offStillRegistered)
        #expect(AlertsState(enabled: true, hookStatus: .notInstalled) == .off)
        #expect(AlertsState(enabled: false, hookStatus: .notInstalled) == .off)
        #expect(AlertsState(enabled: false, hookStatus: .cliNotFound) == .unavailable)
    }

    @Test func cardFitsTwoRowsInItsFrame() {
        // Two rows of a 12 pt body line over an 11 pt caption line (about 28 pt each) with a 4 pt gap,
        // inside the 12 pt card padding.
        let inner = PanelLayout.cardSize(for: .leadingBottom).height - 2 * Tokens.Spacing.m
        #expect(2 * 28 + Tokens.Spacing.xs <= inner)
    }

    @Test func snapshots() throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "notcher-claude-snapshots", directoryHint: .isDirectory)
        let sample = ClaudeAgentsModule.sample()
        let card = try ViewSnapshot.write(module: sample, to: out.appending(path: "card-many-off.png"))
        let now = Date()
        func s(_ id: String, _ state: SessionState, ago: TimeInterval) -> ClaudeSession {
            ClaudeSession(id: id, pid: 1, cwd: "/Users/dev/projects/\(id)", title: id, entrypoint: .cli, state: state,
                          since: now.addingTimeInterval(-ago), lastEvent: now.addingTimeInterval(-ago))
        }
        let cases: [(String, [ClaudeSession], HookInstallStatus)] = [
            ("card-two-need-user", [s("notcher", .needsPermission(detail: "Bash"), ago: 95), s("fix-login-redirect-after-oauth", .needsInput(detail: nil), ago: 400)], .installed),
            ("card-one-working", [s("lanternfly", .working, ago: 380)], .installed),
            ("card-many", [s("notcher", .needsPermission(detail: "Bash"), ago: 95), s("lanternfly", .working, ago: 380),
                           s("garden-clock", .finished(at: now.addingTimeInterval(-40)), ago: 40), s("dotfiles", .idle(since: now), ago: 3900)], .installed),
            ("card-empty", [], .notInstalled),
            ("card-hooks-off", [s("lanternfly", .working, ago: 380), s("dotfiles", .idle(since: now), ago: 3900)], .notInstalled),
        ]
        for (name, sessions, status) in cases {
            let module = ClaudeAgentsModule(sampleSessions: sessions, now: now, hookStatus: status)
            try ViewSnapshot.write(module: module, to: out.appending(path: "\(name).png"))
        }
        // Forms are AppKit-backed and come out blank through ImageRenderer; cache an off-screen hosting view instead.
        let settings = out.appending(path: "settings-sample.png")
        let host = NSHostingView(rootView: try #require(sample.settingsView()).frame(width: 560, height: 1300))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 1300)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: settings)
        #expect(FileManager.default.fileExists(atPath: card.path) && FileManager.default.fileExists(atPath: settings.path))
        print("snapshots in \(out.path)")
    }
}

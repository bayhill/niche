import Foundation
import NotchCore
import Testing
@testable import ClaudeAgentsModule

@Suite struct InstallerTests {
    struct Setup {
        let root: URL
        let dirs: AppDirectories
        let cli: URL
        let paths: HookInstaller.Paths
        let settings: URL

        init(withCLI: Bool = true, settingsJSON: String? = #"{"model":"opus","enabledPlugins":{"formatter@team-tools":true},"permissions":{"allow":["Bash(ls)"]}}"#) throws {
            root = try Fixture.tempDir("installer")
            dirs = .rooted(at: root)
            let fm = FileManager.default
            for d in [dirs.appSupport, dirs.home.appending(path: ".claude"), dirs.home.appending(path: ".local/bin")] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            cli = dirs.home.appending(path: ".local/bin/claude")
            if withCLI {
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            }
            settings = dirs.home.appending(path: ".claude/settings.json")
            if let settingsJSON { try Data(settingsJSON.utf8).write(to: settings) }
            paths = .standard(directories: dirs, bundledPlugin: Fixture.repoRoot.appending(path: "Support/ClaudePlugin"), searchPath: "")
        }

        func installer(_ runner: RecordingRunner) -> HookInstaller {
            HookInstaller(paths: paths, runner: runner, now: { Fixture.t0 }, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        }

        func settingsObject() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func planShowsExactCommandsAndSettingsChange() throws {
        let s = try Setup()
        defer { s.cleanUp() }
        let plan = s.installer(RecordingRunner(settings: s.settings)).plan()
        let pluginDir = s.dirs.appSupport.appending(path: "claude-plugin").path
        #expect(plan.cli == s.cli)
        #expect(plan.installCommands == [
            PlannedCommand(executable: s.cli, arguments: ["plugin", "marketplace", "add", pluginDir, "--scope", "user"]),
            PlannedCommand(executable: s.cli, arguments: ["plugin", "install", "notcher-bridge@notcher-local", "--scope", "user"]),
        ])
        #expect(plan.uninstallCommands.map(\.arguments) == [
            ["plugin", "uninstall", "notcher-bridge@notcher-local", "--scope", "user"],
            ["plugin", "marketplace", "remove", "notcher-local", "--scope", "user"],
        ])
        #expect(plan.settingsBefore == """
        {
          "enabledPlugins" : {
            "formatter@team-tools" : true
          }
        }
        """)
        #expect(plan.settingsAfter == """
        {
          "enabledPlugins" : {
            "formatter@team-tools" : true,
            "notcher-bridge@notcher-local" : true
          },
          "extraKnownMarketplaces" : {
            "notcher-local" : {
              "source" : {
                "path" : "\(pluginDir)",
                "source" : "directory"
              }
            }
          }
        }
        """)
        #expect(!plan.settingsBefore.contains("permissions"), "only the relevant keys are shown")
        #expect(PlannedCommand(executable: s.cli, arguments: ["add", "/a b/it's"]).display == "\(s.cli.path) add '/a b/it'\\''s'")
    }

    @Test func installCopiesBacksUpRunsAndCreatesSpool() async throws {
        let s = try Setup()
        defer { s.cleanUp() }
        let runner = RecordingRunner(settings: s.settings)
        let installer = s.installer(runner)
        #expect(installer.status() == .notInstalled)
        let originalSettings = try Data(contentsOf: s.settings)

        let result = await installer.install()
        #expect(result.succeeded, "\(result.message) \(result.log)")
        let calls = await runner.calls
        #expect(calls.map(\.arguments) == installer.plan().installCommands.map(\.arguments))
        #expect(calls.allSatisfy { $0.executable == s.cli })

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: s.paths.installedPlugin.appending(path: ".claude-plugin/marketplace.json").path))
        #expect(fm.isExecutableFile(atPath: s.paths.installedPlugin.appending(path: "plugins/notcher-bridge/scripts/forward.sh").path))
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: s.paths.spool.path, isDirectory: &isDir) && isDir.boolValue)
        let backups = try fm.contentsOfDirectory(atPath: s.paths.backups.path)
        #expect(backups.count == 1 && backups[0].hasPrefix("settings-") && backups[0].hasSuffix(".json"))
        #expect(try Data(contentsOf: s.paths.backups.appending(path: backups[0])) == originalSettings)
        #expect(installer.status() == .installed)
        let after = try s.settingsObject()
        #expect(after["model"] as? String == "opus", "other keys untouched by our (simulated) CLI")
        #expect(HookInstaller.sameContents(s.paths.bundledPlugin!, s.paths.installedPlugin))
    }

    @Test func uninstallReversesEverything() async throws {
        let s = try Setup()
        defer { s.cleanUp() }
        let runner = RecordingRunner(settings: s.settings)
        let installer = s.installer(runner)
        _ = await installer.install()
        let result = await installer.uninstall()
        #expect(result.succeeded, "\(result.message) \(result.log)")
        let calls = await runner.calls
        #expect(calls.suffix(2).map(\.arguments) == installer.plan().uninstallCommands.map(\.arguments))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: s.paths.spool.path))
        #expect(!fm.fileExists(atPath: s.paths.installedPlugin.path))
        #expect(try fm.contentsOfDirectory(atPath: s.paths.backups.path).count >= 1, "backups are kept")
        #expect(installer.status() == .notInstalled)
        let settings = try s.settingsObject()
        #expect((settings["enabledPlugins"] as? [String: Any])?["notcher-bridge@notcher-local"] == nil)
        #expect((settings["enabledPlugins"] as? [String: Any])?["formatter@team-tools"] as? Bool == true)
    }

    @Test func cliNotFound() async throws {
        let s = try Setup(withCLI: false)
        defer { s.cleanUp() }
        let runner = RecordingRunner(settings: s.settings)
        let installer = s.installer(runner)
        #expect(installer.status() == .cliNotFound)
        #expect(installer.plan().cli == nil)
        let result = await installer.install()
        #expect(!result.succeeded && result.message.contains("not found"))
        #expect(await runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.paths.spool.path))
        #expect(!FileManager.default.fileExists(atPath: s.paths.installedPlugin.path))
    }

    @Test func failingCommandStopsBeforeEnablingAlerts() async throws {
        let s = try Setup()
        defer { s.cleanUp() }
        let runner = RecordingRunner(settings: s.settings, failOn: "install")
        let installer = s.installer(runner)
        let result = await installer.install()
        #expect(!result.succeeded)
        #expect(result.log.contains { $0.contains("exit 1") && $0.contains("boom") })
        #expect(!FileManager.default.fileExists(atPath: s.paths.spool.path), "no spool, so the bridge stays silent")
        #expect(installer.status() == .notInstalled)
    }

    @Test func uninstallWithoutCLIStillSilencesAndSaysWhatIsLeft() async throws {
        let s = try Setup(withCLI: false, settingsJSON: #"{"enabledPlugins":{"notcher-bridge@notcher-local":true},"extraKnownMarketplaces":{"notcher-local":{"source":{"source":"directory","path":"/x"}}}}"#)
        defer { s.cleanUp() }
        try FileManager.default.createDirectory(at: s.paths.spool, withIntermediateDirectories: true)
        let installer = s.installer(RecordingRunner(settings: s.settings))
        #expect(installer.status() == .installed)
        let result = await installer.uninstall()
        #expect(!result.succeeded && result.message.contains("not found"))
        #expect(!FileManager.default.fileExists(atPath: s.paths.spool.path))
    }

    @Test func prepareRefreshesAnOutdatedCopyOnlyWhenInstalled() async throws {
        let s = try Setup()
        defer { s.cleanUp() }
        let runner = RecordingRunner(settings: s.settings)
        let installer = s.installer(runner)
        _ = await installer.install()
        let script = s.paths.installedPlugin.appending(path: "plugins/notcher-bridge/scripts/forward.sh")
        try Data("old".utf8).write(to: script)
        try FileManager.default.removeItem(at: s.paths.spool)
        installer.prepare()
        #expect(HookInstaller.sameContents(s.paths.bundledPlugin!, s.paths.installedPlugin))
        #expect(FileManager.default.fileExists(atPath: s.paths.spool.path))

        let fresh = try Setup()
        defer { fresh.cleanUp() }
        fresh.installer(RecordingRunner(settings: fresh.settings)).prepare()
        #expect(!FileManager.default.fileExists(atPath: fresh.paths.installedPlugin.path), "not installed: prepare touches nothing")
    }

    @Test func missingSettingsFileIsFine() throws {
        let s = try Setup(settingsJSON: nil)
        defer { s.cleanUp() }
        let installer = s.installer(RecordingRunner(settings: s.settings))
        #expect(installer.status() == .notInstalled)
        #expect(installer.plan().settingsBefore == "{\n\n}" || installer.plan().settingsBefore == "{}")
        #expect(try installer.backupSettings() == nil)
    }
}

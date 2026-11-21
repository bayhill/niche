import Foundation
import NotchCore

// MARK: - Running processes

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult
}

/// Runs a command with stdin closed and its output captured, killing it after `timeout`.
public struct SystemProcessRunner: ProcessRunning {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 120) { self.timeout = timeout }

    /// `Process` is not `Sendable`, but `terminate()` and `isRunning` are safe to call from any thread.
    private final class Box: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    public func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appending(path: "notcher-run-\(UUID().uuidString).out")
        let errURL = fm.temporaryDirectory.appending(path: "notcher-run-\(UUID().uuidString).err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let box = Box(process)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.process.isRunning { box.process.terminate() }
            }
        }
        try? out.close(); try? err.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessResult(status: status, stdout: stdout, stderr: stderr)
    }
}

// MARK: - Plan and results

public enum HookInstallStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// Not installed, and no `claude` executable was found to install with.
    case cliNotFound
}

public struct PlannedCommand: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public init(executable: URL, arguments: [String]) { self.executable = executable; self.arguments = arguments }

    /// The command as you would type it in a shell.
    public var display: String { ([executable.path] + arguments).map(Self.quote).joined(separator: " ") }

    static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct InstallPlan: Sendable, Equatable {
    /// The `claude` executable that will run the commands; `nil` when none was found.
    public var cli: URL?
    public var installCommands: [PlannedCommand]
    public var uninstallCommands: [PlannedCommand]
    /// What `install()` does on disk besides the commands, in order, in plain words.
    public var installSteps: [String]
    public var uninstallSteps: [String]
    public var settingsFile: URL
    /// The `enabledPlugins` and `extraKnownMarketplaces` part of settings.json, now and after installing.
    public var settingsBefore: String
    public var settingsAfter: String

    public init(
        cli: URL?, installCommands: [PlannedCommand], uninstallCommands: [PlannedCommand], installSteps: [String],
        uninstallSteps: [String], settingsFile: URL, settingsBefore: String, settingsAfter: String
    ) {
        self.cli = cli; self.installCommands = installCommands; self.uninstallCommands = uninstallCommands
        self.installSteps = installSteps; self.uninstallSteps = uninstallSteps; self.settingsFile = settingsFile
        self.settingsBefore = settingsBefore; self.settingsAfter = settingsAfter
    }
}

public struct InstallResult: Sendable, Equatable {
    public var succeeded: Bool
    /// One sentence for the user.
    public var message: String
    /// Each command with its exit status and output, and each file step.
    public var log: [String]
    public init(succeeded: Bool, message: String, log: [String] = []) {
        self.succeeded = succeeded; self.message = message; self.log = log
    }
}

/// The installer as the module sees it, so the sample module can use a fake that touches nothing.
public protocol HookInstalling: Sendable {
    func status() -> HookInstallStatus
    func plan() -> InstallPlan
    func install() async -> InstallResult
    func uninstall() async -> InstallResult
    /// Called at start: when installed, refresh the plugin copy from the app bundle and make sure the spool exists.
    func prepare()
}

// MARK: - Installer

/// Installs the `notcher-bridge` plugin into the user's Claude Code configuration via the `claude` CLI, only when
/// asked. Paths and the process runner are injected; nothing here runs on its own.
public struct HookInstaller: HookInstalling {
    public static let marketplace = "notcher-local"
    public static let plugin = "notcher-bridge"
    public static var pluginID: String { "\(plugin)@\(marketplace)" }

    public struct Paths: Sendable, Equatable {
        /// `Notcher.app/Contents/Resources/ClaudePlugin` (the marketplace root). `nil` outside the app bundle.
        public var bundledPlugin: URL?
        /// Stable copy that Claude Code loads in place: `<appSupport>/claude-plugin`.
        public var installedPlugin: URL
        /// Where the bridge drops events: `<appSupport>/claude-events`.
        public var spool: URL
        /// Timestamped copies of settings.json taken before every change: `<appSupport>/claude-settings-backups`.
        public var backups: URL
        /// `~/.claude/settings.json`. Read here, written only by the `claude` CLI.
        public var claudeSettings: URL
        /// Where to look for the `claude` executable, in order.
        public var cliCandidates: [URL]

        public init(bundledPlugin: URL?, installedPlugin: URL, spool: URL, backups: URL, claudeSettings: URL, cliCandidates: [URL]) {
            self.bundledPlugin = bundledPlugin; self.installedPlugin = installedPlugin; self.spool = spool
            self.backups = backups; self.claudeSettings = claudeSettings; self.cliCandidates = cliCandidates
        }

        public static func standard(directories: AppDirectories, bundledPlugin: URL?, searchPath: String? = nil) -> Paths {
            let home = directories.home
            var candidates = [
                home.appending(path: ".local/bin/claude"), home.appending(path: ".claude/local/claude"),
                URL(filePath: "/opt/homebrew/bin/claude"), URL(filePath: "/usr/local/bin/claude"),
                home.appending(path: ".npm-global/bin/claude"), home.appending(path: ".bun/bin/claude"),
                home.appending(path: ".volta/bin/claude"),
            ]
            for dir in (searchPath ?? "").split(separator: ":") where !dir.isEmpty {
                let url = URL(filePath: String(dir), directoryHint: .isDirectory).appending(path: "claude")
                if !candidates.contains(url) { candidates.append(url) }
            }
            return Paths(
                bundledPlugin: bundledPlugin,
                installedPlugin: directories.appSupport.appending(path: "claude-plugin", directoryHint: .isDirectory),
                spool: directories.appSupport.appending(path: "claude-events", directoryHint: .isDirectory),
                backups: directories.appSupport.appending(path: "claude-settings-backups", directoryHint: .isDirectory),
                claudeSettings: home.appending(path: ".claude/settings.json"),
                cliCandidates: candidates
            )
        }
    }

    public let paths: Paths
    public let runner: any ProcessRunning
    public let now: @Sendable () -> Date
    public let baseEnvironment: [String: String]

    public init(
        paths: Paths, runner: any ProcessRunning, now: @escaping @Sendable () -> Date = { Date() },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.paths = paths; self.runner = runner; self.now = now; self.baseEnvironment = baseEnvironment
    }

    // MARK: Status and plan

    public func locateCLI() -> URL? {
        paths.cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func status() -> HookInstallStatus {
        if Self.isEnabled(in: readSettings()) { return .installed }
        return locateCLI() == nil ? .cliNotFound : .notInstalled
    }

    public func plan() -> InstallPlan {
        let cli = locateCLI() ?? URL(filePath: "claude")
        let settings = readSettings()
        var before: [String: Any] = [:]
        for key in ["enabledPlugins", "extraKnownMarketplaces"] { if let v = settings?[key] { before[key] = v } }
        var after = before
        var enabled = after["enabledPlugins"] as? [String: Any] ?? [:]
        enabled[Self.pluginID] = true
        after["enabledPlugins"] = enabled
        var markets = after["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        markets[Self.marketplace] = ["source": ["source": "directory", "path": paths.installedPlugin.path]]
        after["extraKnownMarketplaces"] = markets

        let stamp = "<timestamp>"
        let fileName = settingsBackupName(stamp)
        return InstallPlan(
            cli: locateCLI(),
            installCommands: [
                PlannedCommand(executable: cli, arguments: ["plugin", "marketplace", "add", paths.installedPlugin.path, "--scope", "user"]),
                PlannedCommand(executable: cli, arguments: ["plugin", "install", Self.pluginID, "--scope", "user"]),
            ],
            uninstallCommands: [
                PlannedCommand(executable: cli, arguments: ["plugin", "uninstall", Self.pluginID, "--scope", "user"]),
                PlannedCommand(executable: cli, arguments: ["plugin", "marketplace", "remove", Self.marketplace, "--scope", "user"]),
            ],
            installSteps: [
                "Copy the plugin from the app to \(paths.installedPlugin.path)",
                "Back up \(paths.claudeSettings.path) to \(paths.backups.appending(path: fileName).path)",
                "Run the two commands below",
                "Create \(paths.spool.path)",
            ],
            uninstallSteps: [
                "Remove \(paths.spool.path) (alerts stop at once)",
                "Back up \(paths.claudeSettings.path) to \(paths.backups.path)",
                "Run the two uninstall commands",
                "Remove \(paths.installedPlugin.path)",
            ],
            settingsFile: paths.claudeSettings,
            settingsBefore: settings == nil && FileManager.default.fileExists(atPath: paths.claudeSettings.path)
                ? "(settings.json could not be read)" : Self.render(before),
            settingsAfter: Self.render(after)
        )
    }

    // MARK: Install / uninstall

    public func install() async -> InstallResult {
        var log: [String] = []
        guard let cli = locateCLI() else {
            return InstallResult(succeeded: false, message: "Claude Code's command-line tool (claude) was not found. Install Claude Code, then try again.")
        }
        guard let source = paths.bundledPlugin,
              FileManager.default.fileExists(atPath: source.appending(path: ".claude-plugin/marketplace.json").path)
        else {
            return InstallResult(succeeded: false, message: "The plugin is missing from the app bundle. Reinstall Notcher and try again.")
        }
        do {
            try copyPlugin(from: source)
            log.append("Copied plugin to \(paths.installedPlugin.path)")
            if let backup = try backupSettings() { log.append("Backed up settings.json to \(backup.path)") }
        } catch {
            return InstallResult(succeeded: false, message: "Could not prepare the plugin: \(error.localizedDescription)", log: log)
        }
        for command in plan().installCommands {
            let resolved = PlannedCommand(executable: cli, arguments: command.arguments)
            let result = await run(resolved, log: &log)
            guard result?.status == 0 else {
                return InstallResult(succeeded: false, message: "Claude Code reported an error, so the remaining steps were skipped. Check the details below.", log: log)
            }
        }
        do {
            try FileManager.default.createDirectory(at: paths.spool, withIntermediateDirectories: true)
            log.append("Created \(paths.spool.path)")
        } catch {
            return InstallResult(succeeded: false, message: "Installed, but could not create the event folder: \(error.localizedDescription)", log: log)
        }
        return InstallResult(
            succeeded: true,
            message: "Alerts are on. Sessions started from now on report to Notcher; run /reload-plugins in sessions that are already open.",
            log: log
        )
    }

    public func uninstall() async -> InstallResult {
        var log: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.spool.path) {
            try? fm.removeItem(at: paths.spool)
            log.append("Removed \(paths.spool.path)")
        }
        if let backup = try? backupSettings() { log.append("Backed up settings.json to \(backup.path)") }
        let cli = locateCLI()
        if let cli {
            for command in plan().uninstallCommands {
                _ = await run(PlannedCommand(executable: cli, arguments: command.arguments), log: &log)
            }
        }
        let settings = readSettings()
        if Self.isEnabled(in: settings) || Self.declaresMarketplace(in: settings) {
            let why = cli == nil ? "Claude Code's command-line tool was not found, so" : "Claude Code did not confirm the removal, so"
            return InstallResult(
                succeeded: false,
                message: "Alerts are off, but \(why) settings.json still lists the plugin. Run the uninstall commands shown above in Terminal.",
                log: log
            )
        }
        if fm.fileExists(atPath: paths.installedPlugin.path) {
            try? fm.removeItem(at: paths.installedPlugin)
            log.append("Removed \(paths.installedPlugin.path)")
        }
        return InstallResult(succeeded: true, message: "Alerts are off and the plugin is removed from Claude Code.", log: log)
    }

    public func prepare() {
        guard status() == .installed else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.spool, withIntermediateDirectories: true)
        if let source = paths.bundledPlugin, fm.fileExists(atPath: source.path),
           !Self.sameContents(source, paths.installedPlugin) {
            try? copyPlugin(from: source)
        }
    }

    // MARK: Helpers

    private func run(_ command: PlannedCommand, log: inout [String]) async -> ProcessResult? {
        var env = baseEnvironment
        let dirs = [command.executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (dirs + (env["PATH"]?.split(separator: ":").map(String.init) ?? [])).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
        do {
            let result = try await runner.run(command.executable, arguments: command.arguments, environment: env)
            let output = [result.stdout, result.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            log.append("$ \(command.display)  → exit \(result.status)" + (output.isEmpty ? "" : "\n" + output.joined(separator: "\n")))
            return result
        } catch {
            log.append("$ \(command.display)  → could not run: \(error.localizedDescription)")
            return nil
        }
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.claudeSettings),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    static func isEnabled(in settings: [String: Any]?) -> Bool {
        (settings?["enabledPlugins"] as? [String: Any])?[pluginID] as? Bool == true
    }

    static func declaresMarketplace(in settings: [String: Any]?) -> Bool {
        (settings?["extraKnownMarketplaces"] as? [String: Any])?[marketplace] != nil
    }

    private func settingsBackupName(_ stamp: String) -> String { "settings-\(stamp).json" }

    /// Copies settings.json into the backups folder. Returns `nil` when there is no settings.json yet.
    @discardableResult
    func backupSettings() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.claudeSettings.path) else { return nil }
        try fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var url = paths.backups.appending(path: settingsBackupName(f.string(from: now())))
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = paths.backups.appending(path: settingsBackupName(f.string(from: now()) + "-\(n)")); n += 1
        }
        try fm.copyItem(at: paths.claudeSettings, to: url)
        return url
    }

    /// Replaces the installed copy with the bundle's, via a staging folder so a half-copied plugin is never live.
    func copyPlugin(from source: URL) throws {
        let fm = FileManager.default
        let parent = paths.installedPlugin.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".claude-plugin-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.copyItem(at: source, to: staging)
        let script = staging.appending(path: "plugins/\(Self.plugin)/scripts/forward.sh")
        if fm.fileExists(atPath: script.path) { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
        if fm.fileExists(atPath: paths.installedPlugin.path) {
            _ = try fm.replaceItemAt(paths.installedPlugin, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: paths.installedPlugin)
        }
    }

    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        func files(_ root: URL) -> [String: Data] {
            var out: [String: Data] = [:]
            let rootPath = root.resolvingSymlinksInPath().path
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = url.resolvingSymlinksInPath().path
                out[String(path.dropFirst(rootPath.count))] = try? Data(contentsOf: url)
            }
            return out
        }
        let fa = files(a)
        return !fa.isEmpty && fa == files(b)
    }

    static func render(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

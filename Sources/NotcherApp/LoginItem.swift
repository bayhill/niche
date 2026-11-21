import Foundation
import NotchCore
import ServiceManagement

/// Launch at login. Uses `SMAppService`; if the system refuses (it can for locally signed apps), falls back to a
/// per-user LaunchAgent that opens the installed app bundle.
@MainActor
enum LoginItem {
    private static let agentLabel = "dev.bayhill.notcher.login"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Human-readable mechanism in use, for Settings.
    static var mechanism: String {
        if SMAppService.mainApp.status == .enabled { return "Login item" }
        if FileManager.default.fileExists(atPath: agentURL.path) { return "Launch agent" }
        return "Off"
    }

    static func setEnabled(_ enabled: Bool) {
        let log = Log.logger("login")
        if enabled {
            do {
                try SMAppService.mainApp.register()
                removeAgent()
                log.notice("registered login item")
            } catch {
                log.error("SMAppService register failed: \(error.localizedDescription, privacy: .public); using launch agent")
                installAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeAgent()
            log.notice("launch at login disabled")
        }
    }

    private static func installAgent() {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
        } catch {
            Log.logger("login").error("launch agent install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removeAgent() { try? FileManager.default.removeItem(at: agentURL) }
}

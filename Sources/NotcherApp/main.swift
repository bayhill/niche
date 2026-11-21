import AppKit
import CalendarModule
import ClaudeAgentsModule
import ClipboardModule
import ConvertModule
import NotchCore
import NotchUI
import NowPlayingModule
import ShelfModule
import SwiftUI

/// Composition root: builds the modules, wires the shared services, starts the notch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let debug = DebugOptions.fromProcess
    private let log = Log.logger("app")
    private let settings = SettingsStore()
    private let services = AppServices()
    private let directories = AppDirectories.live
    private var modules: [any NotchModule] = []
    private var notch: NotchController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    /// True when launched with flags meant for screenshots and automated checks: no onboarding, no login item.
    private var isDebugRun: Bool { debug.forceState != nil || debug.demo || debug.fixtures }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            log.notice("another instance is running; exiting")
            NSApp.terminate(nil)
            return
        }
        for dir in [directories.appSupport, directories.caches] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let convert = debug.fixtures ? ConvertModule.sample() : ConvertModule.live()
        let shelf = debug.fixtures ? ShelfModule.sample() : ShelfModule.live()
        modules = [
            convert,
            shelf,
            debug.fixtures ? ClipboardModule.sample() : ClipboardModule.live(),
            debug.fixtures ? NowPlayingModule.sample() : NowPlayingModule.live(),
            debug.fixtures ? CalendarModule.sample() : CalendarModule.live(),
            debug.fixtures ? ClaudeAgentsModule.sample() : ClaudeAgentsModule.live(),
        ]
        services.converter = convert
        services.shelf = shelf

        let settingsWindow = SettingsWindowController(modules: modules, settings: settings, notchSettings: AnyView(NotchSettingsRows(settings: settings)))
        self.settingsWindow = settingsWindow
        services.openSettings = { [weak self] module in
            self?.notch?.collapse()
            self?.settingsWindow?.show(pane: module)
        }

        let notch = NotchController(modules: modules, services: services, settings: settings, directories: directories, debug: debug)
        self.notch = notch
        notch.start()

        let disabled = Set(settings.get(CoreSettings.disabledModules))
        for module in modules where !disabled.contains(module.id.rawValue) {
            let context = ModuleContext(
                services: services, settings: settings, directories: directories, mayPrompt: false, log: Log.logger(for: module.id)
            )
            Task { await module.start(context) }
        }

        trackMenuBarIcon()
        if !isDebugRun { firstRunIfNeeded() }
        log.notice("started; modules: \(self.modules.map(\.id.rawValue).joined(separator: ","), privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        modules.forEach { $0.stop() }
        notch?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }

    /// The user asked for Notcher to start with the Mac: switch that on once, then leave the choice to Settings.
    private func firstRunIfNeeded() {
        if !settings.get(AppSettings.loginItemInitialized) {
            LoginItem.setEnabled(true)
            settings.set(AppSettings.loginItemInitialized, true)
        }
        if !settings.get(AppSettings.onboarded) { settingsWindow?.show() }
    }

    // MARK: Menu bar icon

    private func trackMenuBarIcon() {
        let show = withObservationTracking { settings.get(AppSettings.showMenuBarIcon) } onChange: { [weak self] in
            Task { @MainActor in self?.trackMenuBarIcon() }
        }
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notcher")
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Notcher", action: #selector(togglePanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Notcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func togglePanel() { notch?.toggle() }
    @objc private func openSettings() { settingsWindow?.show() }
}

/// The notch layer's own switches, shown in Settings > General.
private struct NotchSettingsRows: View {
    let settings: SettingsStore
    var body: some View {
        Toggle("Open the panel by hovering over the notch", isOn: settings.binding(NotchSettings.openOnHover))
        Toggle("Open the panel with ⌃⌥N", isOn: settings.binding(NotchSettings.hotkeyEnabled))
    }
}

setvbuf(stdout, nil, _IONBF, 0)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

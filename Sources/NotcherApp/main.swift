import AppKit
import CalendarModule
import ClaudeAgentsModule
import ClipboardModule
import ColourModule
import ConvertModule
import NotchCore
import NotchUI
import NowPlayingModule
import ScreenshotsModule
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
    private var running: Set<ModuleID> = []
    private var converter: (any ImageConverting)?
    private var shelf: (any ShelfAccepting)?
    private var playback: (any PlaybackControlling)?
    private var notch: NotchController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    /// True when launched with flags meant for screenshots and automated checks: no onboarding, no login item.
    private var isDebugRun: Bool { debug.forceState != nil || debug.demo || debug.fixtures }

    /// First-run setup (login item, welcome) only makes sense for the installed app, never for `swift run`.
    private var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Another, older instance of this app is running. Only the newer one steps aside, so two near-simultaneous
    /// launches cannot both quit, and a relaunch is not fooled by an instance that is still shutting down.
    private var olderInstanceIsRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            guard let theirs = other.launchDate, let mine = me.launchDate else { return false }
            return theirs < mine || (theirs == mine && other.processIdentifier < me.processIdentifier)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if olderInstanceIsRunning {
            log.notice("another instance is running; exiting")
            NSApp.terminate(nil)
            return
        }
        for dir in [directories.appSupport, directories.caches] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let convert = debug.fixtures ? ConvertModule.sample() : ConvertModule.live()
        let shelf = debug.fixtures ? ShelfModule.sample() : ShelfModule.live()
        let nowPlaying = debug.fixtures ? NowPlayingModule.sample() : NowPlayingModule.live()
        modules = [
            convert,
            shelf,
            debug.fixtures ? ClipboardModule.sample() : ClipboardModule.live(),
            nowPlaying,
            debug.fixtures ? CalendarModule.sample() : CalendarModule.live(),
            debug.fixtures ? ClaudeAgentsModule.sample() : ClaudeAgentsModule.live(),
            debug.fixtures ? ScreenshotsModule.sample() : ScreenshotsModule.live(),
            debug.fixtures ? ColourModule.sample() : ColourModule.live(),
        ]
        self.converter = convert
        self.shelf = shelf
        self.playback = nowPlaying

        let settingsWindow = SettingsWindowController(modules: modules, settings: settings, notchSettings: AnyView(NotchSettingsRows(settings: settings)))
        self.settingsWindow = settingsWindow
        services.openSettings = { [weak self] module in
            self?.notch?.collapse()
            self?.settingsWindow?.show(pane: module)
        }

        let notch = NotchController(modules: modules, services: services, settings: settings, directories: directories, debug: debug)
        self.notch = notch
        notch.start()

        syncModules()
        trackMenuBarIcon()
        if !isDebugRun, isInstalledApp { firstRunIfNeeded() }
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

    /// Starts modules that are enabled and stops ones switched off in Settings, now and whenever the setting changes.
    /// A stopped module does no work at all (a disabled Clipboard must not keep recording), and the shared
    /// services of a disabled module are withdrawn so nothing hands it work.
    private func syncModules() {
        let disabled = withObservationTracking { Set(settings.get(CoreSettings.disabledModules)) } onChange: { [weak self] in
            Task { @MainActor in self?.syncModules() }
        }
        for module in modules {
            let id = module.id
            let enabled = !disabled.contains(id.rawValue)
            if enabled, !running.contains(id) {
                running.insert(id)
                let context = ModuleContext(
                    services: services, settings: settings, directories: directories, mayPrompt: false, log: Log.logger(for: id)
                )
                Task { [weak self] in
                    // The setting may have flipped back before this task ran.
                    guard let self, self.running.contains(id) else { return }
                    await module.start(context)
                }
            } else if !enabled, running.contains(id) {
                running.remove(id)
                module.stop()
            }
        }
        services.converter = running.contains(.convert) ? converter : nil
        services.shelf = running.contains(.shelf) ? shelf : nil
        services.playback = running.contains(.nowPlaying) ? playback : nil
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

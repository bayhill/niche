import AppKit
import NotchCore
import SwiftUI

/// What the Settings sidebar can show.
enum SettingsPane: Hashable {
    case general
    case module(ModuleID)
}

@MainActor
@Observable
final class SettingsModel {
    var selection: SettingsPane = .general
    var launchAtLogin = LoginItem.isEnabled
    let modules: [any NotchModule]
    let settings: SettingsStore
    /// Extra controls contributed by the notch layer (hover, shortcut).
    let notchSettings: AnyView?

    init(modules: [any NotchModule], settings: SettingsStore, notchSettings: AnyView?) {
        self.modules = modules; self.settings = settings; self.notchSettings = notchSettings
    }
}

private struct SettingsRoot: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                Section("Modules") {
                    ForEach(model.modules, id: \.id) { module in
                        Label(module.title, systemImage: module.symbol).tag(SettingsPane.module(module.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch model.selection {
                case .general: GeneralPane(model: model)
                case .module(let id): ModulePane(model: model, id: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 660, minHeight: 440)
    }
}

private struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if !model.settings.get(AppSettings.onboarded) {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to Niche").font(.title2.weight(.semibold))
                        Text("Drag images onto the notch to convert them to WebP, right next to the original. Click the notch or press ⌃⌥N to open the panel. Each module on the left can be set up or switched off at any time. Niche does not open at login unless that is switched on below.")
                            .foregroundStyle(.secondary)
                        Button("Got it") { model.settings.set(AppSettings.onboarded, true) }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Startup") {
                Toggle("Open Niche at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { LoginItem.setEnabled($0); model.launchAtLogin = LoginItem.isEnabled }
                ))
                Toggle("Show icon in the menu bar", isOn: model.settings.binding(AppSettings.showMenuBarIcon))
            }
            if let notch = model.notchSettings {
                Section("Notch") { notch }
            }
            Section("Modules") {
                ForEach(model.modules, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { CoreSettings.isEnabled(module.id, in: model.settings) },
                        set: { CoreSettings.setEnabled(module.id, $0, in: model.settings) }
                    )) { Label(module.title, systemImage: module.symbol) }
                }
                Text("A module that is switched off stops completely and disappears from the notch.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Niche \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Niche") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModulePane: View {
    @Bindable var model: SettingsModel
    let id: ModuleID

    var body: some View {
        if let module = model.modules.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                if !module.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(module.requirements) { requirement in
                            Label(requirement.rationale, systemImage: requirement.optional ? "info.circle" : "lock.shield")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding([.horizontal, .top], 20)
                }
                if let view = module.settingsView() {
                    view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ContentUnavailableView("No settings", systemImage: module.symbol, description: Text("\(module.title) works without any setup."))
                }
            }
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(modules: [any NotchModule], settings: SettingsStore, notchSettings: AnyView?) {
        model = SettingsModel(modules: modules, settings: settings, notchSettings: notchSettings)
    }

    func show(pane module: ModuleID? = nil) {
        if let module, model.modules.contains(where: { $0.id == module }) { model.selection = .module(module) }
        model.launchAtLogin = LoginItem.isEnabled
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Niche Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsRoot(model: model))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

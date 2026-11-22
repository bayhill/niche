import Foundation
import Observation
import SwiftUI

/// A typed setting. Declare keys as static constants next to the module that owns them,
/// named `"<moduleID>.<name>"`, e.g. `SettingsKey("convert.quality", default: 80)`.
public struct SettingsKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value
    public init(_ name: String, default defaultValue: Value) { self.name = name; self.defaultValue = defaultValue }
}

/// Persistent, observable key-value settings (JSON in `UserDefaults`).
/// Reading through `get` inside a SwiftUI body or `withObservationTracking` subscribes to changes.
@MainActor
@Observable
public final class SettingsStore {
    /// Where the JSON for each key lives.
    private enum Storage {
        case defaults(UserDefaults)
        /// Process memory only: nothing on disk and nothing registered with `cfprefsd`.
        case memory
    }

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private var memory: [String: Data] = [:]
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    private var revision = 0

    public init(defaults: UserDefaults = .standard) { storage = .defaults(defaults) }

    private init(storage: Storage) { self.storage = storage }

    /// A store that lives in memory and is gone with it, for tests, previews and fixtures.
    public static func ephemeral() -> SettingsStore { SettingsStore(storage: .memory) }

    /// Whether the store keeps its values in memory only.
    var isInMemory: Bool {
        if case .memory = storage { return true }
        return false
    }

    public func get<Value>(_ key: SettingsKey<Value>) -> Value {
        _ = revision
        guard let data = data(forKey: key.name), let value = try? decoder.decode(Value.self, from: data) else {
            return key.defaultValue
        }
        return value
    }

    public func set<Value>(_ key: SettingsKey<Value>, _ value: Value) {
        if let data = try? encoder.encode(value) { store(data, forKey: key.name) }
        revision &+= 1
    }

    public func reset<Value>(_ key: SettingsKey<Value>) {
        store(nil, forKey: key.name)
        revision &+= 1
    }

    private func data(forKey name: String) -> Data? {
        switch storage {
        case .defaults(let defaults): defaults.data(forKey: name)
        case .memory: memory[name]
        }
    }

    private func store(_ data: Data?, forKey name: String) {
        switch storage {
        case .defaults(let defaults):
            if let data { defaults.set(data, forKey: name) } else { defaults.removeObject(forKey: name) }
        case .memory:
            memory[name] = data
        }
    }

    /// Two-way binding for SwiftUI controls.
    public func binding<Value>(_ key: SettingsKey<Value>) -> Binding<Value> {
        Binding(get: { self.get(key) }, set: { self.set(key, $0) })
    }
}

/// App-wide keys that more than one target reads.
public enum CoreSettings {
    /// Module ids the user has switched off.
    public static let disabledModules = SettingsKey<[String]>("core.disabledModules", default: [])
    /// Opt-in module ids the user has switched on.
    public static let enabledModules = SettingsKey<[String]>("core.enabledModules", default: [])
    /// Modules that are off until switched on in Settings: tools that only some people have a use for.
    public static let optInModules: Set<ModuleID> = [.devServers, .builds]

    /// Whether a module runs and shows in the notch.
    /// - Parameter fixtures: a `--fixtures` run, which shows every module with its sample data.
    @MainActor
    public static func isEnabled(_ id: ModuleID, in settings: SettingsStore, fixtures: Bool = false) -> Bool {
        if optInModules.contains(id) { return fixtures || settings.get(enabledModules).contains(id.rawValue) }
        return !settings.get(disabledModules).contains(id.rawValue)
    }

    @MainActor
    public static func setEnabled(_ id: ModuleID, _ on: Bool, in settings: SettingsStore) {
        let optIn = optInModules.contains(id)
        let key = optIn ? enabledModules : disabledModules
        var listed = Set(settings.get(key))
        // One list names what is on, the other what is off.
        if on == optIn { listed.insert(id.rawValue) } else { listed.remove(id.rawValue) }
        settings.set(key, listed.sorted())
    }
}

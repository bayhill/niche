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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    private var revision = 0

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A store backed by a throwaway suite, for tests and previews.
    public static func ephemeral() -> SettingsStore {
        let suite = "notcher.ephemeral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    public func get<Value>(_ key: SettingsKey<Value>) -> Value {
        _ = revision
        guard let data = defaults.data(forKey: key.name), let value = try? decoder.decode(Value.self, from: data) else {
            return key.defaultValue
        }
        return value
    }

    public func set<Value>(_ key: SettingsKey<Value>, _ value: Value) {
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key.name) }
        revision &+= 1
    }

    public func reset<Value>(_ key: SettingsKey<Value>) {
        defaults.removeObject(forKey: key.name)
        revision &+= 1
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

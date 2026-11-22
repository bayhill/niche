import NotchCore

enum AppSettings {
    /// The welcome note in Settings has been dismissed.
    static let onboarded = SettingsKey<Bool>("app.onboarded", default: false)
    static let showMenuBarIcon = SettingsKey<Bool>("app.showMenuBarIcon", default: true)
}

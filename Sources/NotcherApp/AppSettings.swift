import NotchCore

enum AppSettings {
    /// The welcome note in Settings has been dismissed.
    static let onboarded = SettingsKey<Bool>("app.onboarded", default: false)
    /// Launch at login has been switched on once automatically (so turning it off sticks).
    static let loginItemInitialized = SettingsKey<Bool>("app.loginItemInitialized", default: false)
    static let showMenuBarIcon = SettingsKey<Bool>("app.showMenuBarIcon", default: true)
}

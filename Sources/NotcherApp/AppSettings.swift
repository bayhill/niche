import NotchCore

enum AppSettings {
    static let onboarded = SettingsKey<Bool>("app.onboarded", default: false)
    static let showMenuBarIcon = SettingsKey<Bool>("app.showMenuBarIcon", default: true)
}

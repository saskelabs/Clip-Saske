import Foundation

final class SettingsStore {
    static let didChangeNotification = Notification.Name("ClipSaskeSettingsDidChange")

    private let database: ClipboardDatabase

    init(database: ClipboardDatabase) {
        self.database = database
    }

    func ensureDefaults() {
        let defaults = AppSettings.defaults
        setDefault("auto_cleanup_days", "\(defaults.autoCleanupDays)")
        setDefault("max_items", "\(defaults.maxItems)")
        setDefault("sync_enabled", defaults.syncEnabled ? "true" : "false")
        setDefault("hotkey", defaults.hotkey)
        setDefault("theme", defaults.theme)
        setDefault("excluded_apps", defaults.excludedApps.joined(separator: "\n"))
    }

    var settings: AppSettings {
        AppSettings(
            autoCleanupDays: int("auto_cleanup_days", fallback: AppSettings.defaults.autoCleanupDays),
            maxItems: int("max_items", fallback: AppSettings.defaults.maxItems),
            syncEnabled: bool("sync_enabled", fallback: AppSettings.defaults.syncEnabled),
            hotkey: string("hotkey", fallback: AppSettings.defaults.hotkey),
            theme: string("theme", fallback: AppSettings.defaults.theme),
            excludedApps: string("excluded_apps", fallback: AppSettings.defaults.excludedApps.joined(separator: "\n"))
                .split(separator: "\n")
                .map(String.init)
        )
    }

    func set(_ key: String, value: String) {
        try? database.setSetting(key: key, value: value)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["key": key])
    }

    private func setDefault(_ key: String, _ value: String) {
        if (try? database.setting(key: key)) == nil {
            try? database.setSetting(key: key, value: value)
        }
    }

    private func string(_ key: String, fallback: String) -> String {
        (try? database.setting(key: key)) ?? fallback
    }

    private func int(_ key: String, fallback: Int) -> Int {
        Int(string(key, fallback: "\(fallback)")) ?? fallback
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        Bool(string(key, fallback: fallback ? "true" : "false")) ?? fallback
    }
}

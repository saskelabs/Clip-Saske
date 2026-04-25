import Foundation

struct ClipboardItem: Identifiable, Hashable {
    enum SyncStatus: String {
        case pending
        case synced
        case failed
    }

    let id: String
    var content: String
    var timestamp: Date
    var appSource: String
    var isPinned: Bool
    var isFavorite: Bool
    var isSensitive: Bool
    var syncStatus: SyncStatus
}

struct AppSettings {
    var autoCleanupDays: Int
    var maxItems: Int
    var syncEnabled: Bool
    var hotkey: String
    var theme: String
    var excludedApps: [String]

    static let defaults = AppSettings(
        autoCleanupDays: 30,
        maxItems: 500,
        syncEnabled: false,
        hotkey: "option+command+v",
        theme: "system",
        excludedApps: ["1Password", "Bitwarden", "Keychain Access", "Passwords"]
    )
}

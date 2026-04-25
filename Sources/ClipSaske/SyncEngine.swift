import Foundation

final class SyncEngine: NSObject {
    private let settingsStore: SettingsStore
    private let secureStore: SecureStore
    private let queue = DispatchQueue(label: "clip-saske.sync")
    private var running = false

    init(settingsStore: SettingsStore, secureStore: SecureStore) {
        self.settingsStore = settingsStore
        self.secureStore = secureStore
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: SettingsStore.didChangeNotification,
            object: settingsStore
        )
    }

    var statusText: String {
        settingsStore.settings.syncEnabled ? (running ? "Enabled" : "Paused") : "Off"
    }

    func start() {
        running = settingsStore.settings.syncEnabled
    }

    func stop() {
        running = false
    }

    func enqueue(_ item: ClipboardItem) {
        guard running else { return }
        queue.async { [secureStore] in
            _ = secureStore.data(account: "sync-token")
            // Provider adapters can be added here. Items are intentionally queued
            // after capture so cloud failures never block local clipboard history.
            _ = item
        }
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard notification.userInfo?["key"] as? String == "sync_enabled" else { return }
        settingsStore.settings.syncEnabled ? start() : stop()
    }
}

import Foundation

@MainActor
final class CleanupScheduler: NSObject {
    private let historyManager: HistoryManager
    private var timer: Timer?

    init(historyManager: HistoryManager, settingsStore: SettingsStore) {
        self.historyManager = historyManager
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: SettingsStore.didChangeNotification,
            object: settingsStore
        )
    }

    func start() {
        historyManager.cleanup()
        timer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self, selector: #selector(cleanup), userInfo: nil, repeats: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func cleanup() {
        historyManager.cleanup()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard ["auto_cleanup_days", "max_items"].contains(notification.userInfo?["key"] as? String) else { return }
        cleanup()
    }
}

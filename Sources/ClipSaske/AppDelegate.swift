import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let database = ClipboardDatabase()
    private lazy var settingsStore = SettingsStore(database: database)
    private lazy var secureStore = SecureStore(service: "ClipSaske")
    private lazy var historyManager = HistoryManager(database: database, settingsStore: settingsStore)
    private lazy var accessibilityMonitor = AccessibilityMonitor()
    private lazy var passwordDetector = PasswordDetector(accessibilityMonitor: accessibilityMonitor)
    private lazy var syncEngine = SyncEngine(settingsStore: settingsStore, secureStore: secureStore)
    private lazy var clipboardMonitor = ClipboardMonitor(
        historyManager: historyManager,
        passwordDetector: passwordDetector,
        syncEngine: syncEngine
    )
    private lazy var popupController = ClipboardPopupController(
        historyManager: historyManager,
        accessibilityMonitor: accessibilityMonitor
    )
    private lazy var hotkeyManager = HotkeyManager(
        accessibilityMonitor: accessibilityMonitor,
        popupController: popupController,
        settingsStore: settingsStore
    )
    private lazy var menuBarController = MenuBarController(
        historyManager: historyManager,
        popupController: popupController,
        settingsStore: settingsStore,
        syncEngine: syncEngine,
        hotkeyManager: hotkeyManager
    )
    private lazy var cleanupScheduler = CleanupScheduler(
        historyManager: historyManager,
        settingsStore: settingsStore
    )
    private lazy var updateChecker   = UpdateChecker()
    private lazy var licenseManager  = LicenseManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Security: verify bundle integrity, signatures, anti-debug ──
        IntegrityGuard.verify()

        do {
            try database.open()
            try database.migrate()
            settingsStore.ensureDefaults()
        } catch {
            guard offerDatabaseReset(after: error) else {
                NSApp.terminate(nil)
                return
            }
        }

        _ = menuBarController
        clipboardMonitor.start()
        hotkeyManager.start()
        cleanupScheduler.start()
        syncEngine.start()
        updateChecker.startAutoChecks()
        licenseManager.start()   // Silent license + integrity verification
        PermissionPrompter.promptIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPermissionsRequired),
            name: PermissionStatus.didRequirePermissionsNotification,
            object: nil
        )
        // Prevent app window contents from appearing in screen recordings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyWindowSecurity),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotkeyManager.stop()
        cleanupScheduler.stop()
        syncEngine.stop()
        updateChecker.stopAutoChecks()
        licenseManager.stop()
        database.close()
    }

    private func offerDatabaseReset(after error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clip Saske could not open its database."
        alert.informativeText = "\(error.localizedDescription)\n\nYou can move the existing database into a backup folder and create a fresh one."
        alert.addButton(withTitle: "Reset Database")
        alert.addButton(withTitle: "Quit")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try database.resetCorruptStore()
            settingsStore.ensureDefaults()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc private func showPermissionsRequired() {
        PermissionsWindowController.shared.show()
    }

    /// Called every time a window becomes key; enforces screen-capture exclusion.
    @objc private func applyWindowSecurity(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            window.sharingType = .none
        }
    }

    /// Exposed to MenuBarController so it can add a "Check for Updates…" action.
    func checkForUpdates() {
        updateChecker.checkForUpdatesManually()
    }
}

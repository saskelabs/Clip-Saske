import AppKit
import Carbon.HIToolbox

final class HotkeyManager: NSObject {
    private let popupController: ClipboardPopupController
    private let settingsStore: SettingsStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var shortcut: KeyboardShortcut
    private(set) var isActive = false

    /// Set to true while the settings hotkey recorder is listening — prevents
    /// the hotkey from both triggering the popup AND being swallowed.
    var isRecording = false

    init(accessibilityMonitor: AccessibilityMonitor,
         popupController: ClipboardPopupController,
         settingsStore: SettingsStore) {
        self.popupController = popupController
        self.settingsStore = settingsStore
        self.shortcut = KeyboardShortcut.parse(settingsStore.settings.hotkey)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: SettingsStore.didChangeNotification,
            object: settingsStore
        )
    }

    func start() {
        attemptTapCreation()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        teardownTap()
    }

    // MARK: - Private

    @discardableResult
    private func attemptTapCreation() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .keyDown, let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    guard let self, !self.isActive else { return }
                    if self.attemptTapCreation() {
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                    }
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: PermissionStatus.didRequirePermissionsNotification, object: nil)
                }
            }
            isActive = false
            return false
        }

        teardownTap()
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    private func teardownTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap = eventTap     { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        isActive = false
    }

    private func handle(_ event: CGEvent) -> Bool {
        // While the settings recorder is listening, pass ALL events through
        // so it can capture them — we must not swallow or open the popup.
        guard !isRecording else { return false }

        guard shortcut.matches(event) else { return false }

        Task { @MainActor [popupController] in
            // Toggle: opens if hidden, closes if visible
            popupController.toggle()
        }
        return true  // swallow the hotkey event
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard notification.userInfo?["key"] as? String == "hotkey" else { return }
        shortcut = KeyboardShortcut.parse(settingsStore.settings.hotkey)
    }
}

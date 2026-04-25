import AppKit

@MainActor
final class ClipboardMonitor: NSObject {
    private let pasteboard = NSPasteboard.general
    private let historyManager: HistoryManager
    private let passwordDetector: PasswordDetector
    private let syncEngine: SyncEngine
    private var timer: Timer?
    private var lastChangeCount: Int

    init(historyManager: HistoryManager, passwordDetector: PasswordDetector, syncEngine: SyncEngine) {
        self.historyManager = historyManager
        self.passwordDetector = passwordDetector
        self.syncEngine = syncEngine
        self.lastChangeCount = pasteboard.changeCount
        super.init()
    }

    func start() {
        timer = Timer.scheduledTimer(timeInterval: 0.6, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = pasteboard.types ?? []
        guard let content = pasteboard.string(forType: .string), !content.isEmpty else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        guard !passwordDetector.shouldIgnoreClipboard(content: content, sourceApp: appName, pasteboardTypes: types) else { return }

        historyManager.capture(content: content, appSource: appName, isSensitive: false)
        if let item = historyManager.recent(limit: 1).first {
            syncEngine.enqueue(item)
        }
    }
}

import AppKit

@MainActor
final class ClipboardPopupController: NSObject {
    private let historyManager: HistoryManager
    private let panel: ClipboardPanel
    private let contentView: ClipboardPopupView

    /// The frontmost app before we showed the popup — used to re-focus it for paste
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel.isVisible }

    init(historyManager: HistoryManager, accessibilityMonitor: AccessibilityMonitor) {
        self.historyManager = historyManager
        self.panel = ClipboardPanel()
        self.contentView = ClipboardPopupView()
        super.init()
        contentView.delegate = self
        panel.contentView = contentView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidChange),
            name: HistoryManager.didChangeNotification,
            object: nil
        )
    }

    /// Toggle: if visible → close. If hidden → open.
    func toggle() {
        if panel.isVisible {
            close()
        } else {
            showUnderCursor()
        }
    }

    func showUnderCursor() {
        // Remember the currently active app so we can re-focus it on paste
        previousApp = NSWorkspace.shared.frontmostApplication

        reload()

        let cursor = NSEvent.mouseLocation
        let width: CGFloat = 280
        let height = contentView.idealHeight
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(cursor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: cursor.x - width / 2, y: cursor.y - height - 14)
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - height - 8)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    @objc private func historyDidChange() {
        guard panel.isVisible else { return }
        reload()
    }

    private func reload() {
        contentView.render(items: historyManager.recent())
    }
}

extension ClipboardPopupController: ClipboardPopupViewDelegate {
    func popupView(_ view: ClipboardPopupView, didChoose item: ClipboardItem) {
        let app = previousApp
        close()

        // Re-activate the previous app (which has the text field), then paste
        if let app {
            app.activate(options: .activateIgnoringOtherApps)
        }
        // 0.1s gives the previous app time to regain focus before Cmd+V fires
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.historyManager.paste(item)
        }
    }

    func popupView(_ view: ClipboardPopupView, didTogglePin item: ClipboardItem) {
        historyManager.togglePinned(item)
    }
}

@MainActor
final class ClipboardPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    }
}

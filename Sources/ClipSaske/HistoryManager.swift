import AppKit

final class HistoryManager {
    static let didChangeNotification = Notification.Name("ClipSaskeHistoryDidChange")

    private let database: ClipboardDatabase
    private let settingsStore: SettingsStore

    init(database: ClipboardDatabase, settingsStore: SettingsStore) {
        self.database = database
        self.settingsStore = settingsStore
    }

    func capture(content: String, appSource: String, isSensitive: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Delete any existing entry with the same content so it bubbles to the top
        // without creating a duplicate (handles X → Y → X pattern)
        if let existing = recent().first(where: { $0.content == content }) {
            try? database.delete(id: existing.id)
        }

        let item = ClipboardItem(
            id: UUID().uuidString,
            content: content,
            timestamp: Date(),
            appSource: appSource,
            isPinned: false,
            isFavorite: false,
            isSensitive: isSensitive,
            syncStatus: .pending
        )
        try? database.insert(item)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: item)
    }

    func recent(limit: Int? = nil, query: String? = nil) -> [ClipboardItem] {
        let itemLimit = limit ?? settingsStore.settings.maxItems
        if let query, !query.isEmpty {
            return (try? database.recent(limit: itemLimit, query: query))
                ?? ((try? database.recentUsingLikeFallback(limit: itemLimit, query: query)) ?? [])
        }
        return (try? database.recent(limit: itemLimit, query: nil)) ?? []
    }

    func pinned(limit: Int = 10) -> [ClipboardItem] {
        (try? database.pinned(limit: limit)) ?? []
    }

    func favorites() -> [ClipboardItem] {
        (try? database.favorites()) ?? []
    }

    func togglePinned(_ item: ClipboardItem) {
        try? database.setFlag(id: item.id, column: "is_pinned", value: !item.isPinned)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func toggleFavorite(_ item: ClipboardItem) {
        try? database.setFlag(id: item.id, column: "is_favorite", value: !item.isFavorite)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func clearHistory() {
        try? database.clearUnprotected()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func cleanup() {
        let settings = settingsStore.settings
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.autoCleanupDays, to: Date()) ?? Date()
        try? database.cleanup(olderThan: cutoff, maxItems: settings.maxItems)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func paste(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    /// Just copies to clipboard — no Cmd+V simulation (used by menu bar)
    func copyToPasteboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
    }
}

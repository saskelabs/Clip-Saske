import AppKit
import ServiceManagement

// MARK: - MenuBarController
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let historyManager: HistoryManager
    private let settingsStore: SettingsStore
    private weak var hotkeyManager: HotkeyManager?
    private let panel    = MenuBarDropPanel()
    private let dropView = MenuBarDropView()
    private var clickMonitor: Any?

    init(historyManager: HistoryManager, popupController: ClipboardPopupController,
         settingsStore: SettingsStore, syncEngine: SyncEngine, hotkeyManager: HotkeyManager) {
        self.historyManager = historyManager
        self.settingsStore  = settingsStore
        self.hotkeyManager  = hotkeyManager
        super.init()
        dropView.delegate = self
        panel.contentView = dropView
        let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clip Saske")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseDown])
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
            name: HistoryManager.didChangeNotification, object: nil)
    }

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        guard let button = statusItem.button, let btnWin = button.window else { return }
        
        let recent = historyManager.recent(limit: 50)
        let pinned = historyManager.pinned(limit: 50)
        
        dropView.reload(recent: recent,
                        pinned: pinned,
                        settingsStore: settingsStore, 
                        hotkeyManager: hotkeyManager)
        let w: CGFloat = 300, h: CGFloat = MenuBarDropView.fixedHeight
        let br  = btnWin.convertToScreen(button.convert(button.bounds, to: nil))
        let scr = NSScreen.screens.first { $0.frame.contains(br.origin) } ?? NSScreen.main!
        var x   = br.midX - w / 2
        x = min(max(x, scr.visibleFrame.minX + 4), scr.visibleFrame.maxX - w - 4)
        panel.setFrame(NSRect(x: x, y: br.minY - h - 2, width: w, height: h), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    @objc private func historyChanged() {
        guard panel.isVisible else { return }
        let recent = historyManager.recent(limit: 50)
        let pinned = historyManager.pinned(limit: 50)
        dropView.reload(recent: recent,
                        pinned: pinned,
                        settingsStore: settingsStore, 
                        hotkeyManager: hotkeyManager)
    }
}

extension MenuBarController: MenuBarDropDelegate {
    func didSelect(_ item: ClipboardItem)    { close(); historyManager.copyToPasteboard(item) }
    func didTogglePin(_ item: ClipboardItem) { historyManager.togglePinned(item) }
    func didClear()                          { historyManager.clearHistory() }
    func didQuit()                           { close(); NSApp.terminate(nil) }
    func didSaveHotkey(_ s: KeyboardShortcut) { settingsStore.set("hotkey", value: s.storageValue) }
    func didSaveCleanup(_ v: Int)            { settingsStore.set("auto_cleanup_days", value: "\(v)") }
    func didSaveMaxItems(_ v: Int)           { settingsStore.set("max_items", value: "\(v)") }
    func didSaveSync(_ on: Bool)             { settingsStore.set("sync_enabled", value: on ? "true" : "false") }
    func didSaveLogin(_ on: Bool) {
        if on { try? StartupAgent.install() } else { try? StartupAgent.uninstall() }
    }
    func didCheckForUpdates() {
        close()
        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
    }
}

// MARK: - Panel
@MainActor final class MenuBarDropPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true; level = .popUpMenu; hidesOnDeactivate = false
        backgroundColor = .clear; isOpaque = false; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        // Prevent panel content from appearing in screen recordings.
        sharingType = .none
    }
}

// MARK: - Delegate
@MainActor protocol MenuBarDropDelegate: AnyObject {
    func didSelect(_ item: ClipboardItem)
    func didTogglePin(_ item: ClipboardItem)
    func didClear()
    func didQuit()
    func didSaveHotkey(_ s: KeyboardShortcut)
    func didSaveCleanup(_ v: Int)
    func didSaveMaxItems(_ v: Int)
    func didSaveSync(_ on: Bool)
    func didSaveLogin(_ on: Bool)
    func didCheckForUpdates()
}

// MARK: - Drop View
@MainActor final class MenuBarDropView: NSView {
    weak var delegate: MenuBarDropDelegate?

    static let navH:    CGFloat = 44
    static let rowH:    CGFloat = 44
    static let rows:    Int     = 5
    static let fixedHeight: CGFloat = navH + 1 + CGFloat(rows) * rowH  // 265

    private enum Tab { case recent, pinned, settings }
    private var tab: Tab = .recent
    private var recentItems: [ClipboardItem] = []
    private var pinnedItems: [ClipboardItem] = []

    // Navbar
    private let fx          = NSVisualEffectView()
    private let navbar      = NSView()
    private let recentBtn   = MBTab(title: "Recent",   sf: "clock")
    private let pinnedBtn   = MBTab(title: "Pinned",   sf: "pin.fill")
    private let settingsBtn = MBTab(title: "Settings", sf: "gearshape.fill")
    private let clearBtn    = MBIcon(sf: "trash",  tip: "Clear")
    private let quitBtn     = MBIcon(sf: "power",  tip: "Quit")
    private let divider     = NSBox()

    // Content pages
    private let listPage     = NSScrollView()
    private let tableView    = NSTableView()
    private let settingsPage = NSView()

    // Settings controls
    private let hotkeyField    = HotkeyRecorderField()
    private let cleanupStepper = NSStepper()
    private let cleanupLabel   = NSTextField(labelWithString: "")
    private let maxStepper     = NSStepper()
    private let maxLabel       = NSTextField(labelWithString: "")
    private let syncBox        = NSButton(checkboxWithTitle: "Cloud Sync", target: nil, action: nil)
    private let loginBox       = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let checkUpdatesBtn = NSButton(title: "Check for Updates\u{2026}", target: nil, action: nil)

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    func reload(recent: [ClipboardItem], pinned: [ClipboardItem],
                settingsStore: SettingsStore, hotkeyManager: HotkeyManager?) {
        recentItems = recent
        pinnedItems = pinned
        
        // Update settings fields
        let s = settingsStore.settings
        hotkeyField.setShortcut(KeyboardShortcut.parse(s.hotkey))
        
        // Only set closures once or if they change
        if hotkeyField.onRecordingChanged == nil {
            hotkeyField.onRecordingChanged = { hotkeyManager?.isRecording = $0 }
        }
        if hotkeyField.onShortcutRecorded == nil {
            hotkeyField.onShortcutRecorded = { [weak self] sh in self?.delegate?.didSaveHotkey(sh) }
        }
        
        cleanupStepper.doubleValue = Double(s.autoCleanupDays)
        cleanupLabel.stringValue = "\(s.autoCleanupDays)"
        maxStepper.doubleValue = Double(s.maxItems)
        maxLabel.stringValue = "\(s.maxItems)"
        syncBox.state  = s.syncEnabled ? .on : .off
        loginBox.state = StartupAgent.isInstalled ? .on : .off
        tableView.reloadData()
    }

    private var displayed: [ClipboardItem] {
        switch tab { case .recent: return recentItems; case .pinned: return pinnedItems; case .settings: return [] }
    }

    private func switchTab(_ t: Tab) {
        tab = t
        recentBtn.isActive   = (t == .recent)
        pinnedBtn.isActive   = (t == .pinned)
        settingsBtn.isActive = (t == .settings)
        listPage.isHidden    = (t == .settings)
        settingsPage.isHidden = (t != .settings)
        if t != .settings { tableView.reloadData() }
    }

    // MARK: Build
    private func build() {
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        fx.material = .popover; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.layer?.masksToBounds = true
        fx.translatesAutoresizingMaskIntoConstraints = false; addSubview(fx)

        navbar.wantsLayer = true
        navbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        navbar.translatesAutoresizingMaskIntoConstraints = false; addSubview(navbar)

        recentBtn.target = self;   recentBtn.action   = #selector(tapRecent)
        pinnedBtn.target = self;   pinnedBtn.action   = #selector(tapPinned)
        settingsBtn.target = self; settingsBtn.action = #selector(tapSettings)
        clearBtn.target = self;    clearBtn.action    = #selector(tapClear)
        quitBtn.target = self;     quitBtn.action     = #selector(tapQuit)
        recentBtn.isActive = true

        let left  = NSStackView(views: [recentBtn, pinnedBtn, settingsBtn])
        left.orientation = .horizontal; left.spacing = 2
        left.translatesAutoresizingMaskIntoConstraints = false
        let right = NSStackView(views: [clearBtn, quitBtn])
        right.orientation = .horizontal; right.spacing = 4
        right.translatesAutoresizingMaskIntoConstraints = false
        navbar.addSubview(left); navbar.addSubview(right)

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false; addSubview(divider)

        // Table
        tableView.headerView = nil; tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowHeight = Self.rowH
        tableView.dataSource = self; tableView.delegate = self
        tableView.target = self; tableView.action = #selector(rowClicked)
        let col = NSTableColumn(identifier: .init("c")); col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        listPage.documentView = tableView; listPage.drawsBackground = false
        listPage.borderType = .noBorder; listPage.hasVerticalScroller = true
        listPage.translatesAutoresizingMaskIntoConstraints = false; addSubview(listPage)

        // Settings page
        buildSettingsPage()
        settingsPage.translatesAutoresizingMaskIntoConstraints = false; addSubview(settingsPage)
        settingsPage.isHidden = true

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            navbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navbar.topAnchor.constraint(equalTo: topAnchor),
            navbar.heightAnchor.constraint(equalToConstant: Self.navH),
            left.leadingAnchor.constraint(equalTo: navbar.leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: navbar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: navbar.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: navbar.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: navbar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            listPage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            listPage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            listPage.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            listPage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            settingsPage.leadingAnchor.constraint(equalTo: leadingAnchor),
            settingsPage.trailingAnchor.constraint(equalTo: trailingAnchor),
            settingsPage.topAnchor.constraint(equalTo: divider.bottomAnchor),
            settingsPage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func buildSettingsPage() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsPage.addSubview(stack)

        // Hotkey
        hotkeyField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(sRow("Hotkey", hotkeyField))

        // Cleanup
        cleanupStepper.minValue = 1; cleanupStepper.maxValue = 365; cleanupStepper.increment = 1
        cleanupStepper.target = self; cleanupStepper.action = #selector(cleanupChanged)
        stack.addArrangedSubview(sRow("Auto Cleanup", stepRow(cleanupLabel, cleanupStepper, "days")))

        // Max items
        maxStepper.minValue = 10; maxStepper.maxValue = 5000; maxStepper.increment = 10
        maxStepper.target = self; maxStepper.action = #selector(maxChanged)
        stack.addArrangedSubview(sRow("Max Items", stepRow(maxLabel, maxStepper, "items")))

        // Sync
        syncBox.target = self; syncBox.action = #selector(syncChanged)
        stack.addArrangedSubview(syncBox)

        // Login
        loginBox.target = self; loginBox.action = #selector(loginChanged)
        stack.addArrangedSubview(loginBox)

        // Check for Updates
        checkUpdatesBtn.bezelStyle = .rounded
        checkUpdatesBtn.font = .systemFont(ofSize: 12)
        checkUpdatesBtn.target = self; checkUpdatesBtn.action = #selector(checkUpdates)
        stack.addArrangedSubview(checkUpdatesBtn)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: settingsPage.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: settingsPage.trailingAnchor),
            stack.topAnchor.constraint(equalTo: settingsPage.topAnchor),
        ])
    }

    private func sRow(_ lbl: String, _ ctrl: NSView) -> NSView {
        let l = NSTextField(labelWithString: lbl)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let r = NSStackView(views: [l, ctrl])
        r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY
        return r
    }

    private func stepRow(_ label: NSTextField, _ stepper: NSStepper, _ suffix: String) -> NSView {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let suf = NSTextField(labelWithString: suffix)
        suf.font = .systemFont(ofSize: 11); suf.textColor = .secondaryLabelColor
        let r = NSStackView(views: [label, stepper, suf])
        r.orientation = .horizontal; r.spacing = 4; r.alignment = .centerY
        return r
    }

    // MARK: Actions
    @objc private func tapRecent()   { switchTab(.recent) }
    @objc private func tapPinned()   { switchTab(.pinned) }
    @objc private func tapSettings() { switchTab(.settings) }
    @objc private func tapClear()    { delegate?.didClear() }
    @objc private func tapQuit()     { delegate?.didQuit() }
    @objc private func rowClicked()  {
        let row = tableView.clickedRow
        guard displayed.indices.contains(row) else { return }
        delegate?.didSelect(displayed[row])
    }
    @objc private func cleanupChanged() {
        let v = Int(cleanupStepper.doubleValue); cleanupLabel.stringValue = "\(v)"
        delegate?.didSaveCleanup(v)
    }
    @objc private func maxChanged() {
        let v = Int(maxStepper.doubleValue); maxLabel.stringValue = "\(v)"
        delegate?.didSaveMaxItems(v)
    }
    @objc private func syncChanged()     { delegate?.didSaveSync(syncBox.state == .on) }
    @objc private func loginChanged()    { delegate?.didSaveLogin(loginBox.state == .on) }
    @objc private func checkUpdates()    { delegate?.didCheckForUpdates() }
    @objc func togglePin(_ sender: MBPinBtn) {
        guard let item = sender.item else { return }
        delegate?.didTogglePin(item)
    }
}

extension MenuBarDropView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(displayed.count, 1) }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.rowH }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if displayed.isEmpty {
            let v = NSTextField(labelWithString: "Nothing here yet")
            v.textColor = .tertiaryLabelColor; v.alignment = .center; v.font = .systemFont(ofSize: 12)
            return v
        }
        let cell = tableView.makeView(withIdentifier: .init("r"), owner: nil) as? MBRowCell ?? MBRowCell()
        cell.configure(item: displayed[row], target: self)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MBRowView() }
}

// MARK: - Reusable components

@MainActor final class MBRowCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let pin   = MBPinBtn()
    private var item: ClipboardItem?

    override init(frame: NSRect) { super.init(frame: frame); identifier = .init("r"); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    func configure(item: ClipboardItem, target: MenuBarDropView) {
        self.item = item
        let t = item.content.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? item.content
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        label.stringValue = trimmed.count > 55 ? String(trimmed.prefix(55)) + "…" : trimmed
        label.font = item.isPinned ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        pin.image = NSImage(systemSymbolName: item.isPinned ? "pin.fill" : "pin",
                            accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        pin.contentTintColor = item.isPinned ? .controlAccentColor : .tertiaryLabelColor
        pin.item = item; pin.target = target; pin.action = #selector(MenuBarDropView.togglePin(_:))
    }

    private func build() {
        label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        pin.isBordered = false; pin.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(pin)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -4),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 14),
            pin.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let sel = backgroundStyle == .emphasized
            label.textColor = sel ? .white : .labelColor
            pin.contentTintColor = sel ? .white.withAlphaComponent(0.8)
                : (item?.isPinned == true ? .controlAccentColor : .tertiaryLabelColor)
        }
    }
}

@MainActor final class MBPinBtn: NSButton { var item: ClipboardItem? }

@MainActor final class MBRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            subviews.compactMap { $0 as? NSTableCellView }
                .forEach { $0.backgroundStyle = isSelected ? .emphasized : .normal }
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8)
            .fill(with: NSColor.controlAccentColor.withAlphaComponent(0.85))
    }
    override func drawBackground(in dirtyRect: NSRect) {}
}

@MainActor final class MBTab: NSButton {
    var isActive = false { didSet { refresh() } }
    init(title: String, sf: String) {
        super.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        image = NSImage(systemSymbolName: sf, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        self.title = title; imagePosition = .imageLeading; isBordered = false
        wantsLayer = true; layer?.cornerRadius = 6
        font = .systemFont(ofSize: 12, weight: .medium)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : .clear
        contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
    }
}

@MainActor final class MBIcon: NSButton {
    init(sf: String, tip: String) {
        super.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: sf, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        isBordered = false; contentTintColor = .tertiaryLabelColor; toolTip = tip
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

private extension NSBezierPath {
    func fill(with color: NSColor) { color.setFill(); fill() }
}

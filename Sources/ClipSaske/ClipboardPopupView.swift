import AppKit

@MainActor
protocol ClipboardPopupViewDelegate: AnyObject {
    func popupView(_ view: ClipboardPopupView, didChoose item: ClipboardItem)
    func popupView(_ view: ClipboardPopupView, didTogglePin item: ClipboardItem)
}

// MARK: - Constants
private enum Design {
    static let rowH: CGFloat        = 52
    static let fixedRows: Int       = 5   // popup is always this tall
    static let hPad: CGFloat        = 6
    static let vPad: CGFloat        = 8
    static let rowRadius: CGFloat   = 8
    static let pinSize: CGFloat     = 14
    nonisolated(unsafe) static let textFont   = NSFont.systemFont(ofSize: 13, weight: .regular)
    nonisolated(unsafe) static let pinnedFont = NSFont.systemFont(ofSize: 13, weight: .medium)
}

@MainActor
final class ClipboardPopupView: NSView {
    weak var delegate: ClipboardPopupViewDelegate?

    private let fx          = NSVisualEffectView()
    private let scrollView  = NSScrollView()
    private let tableView   = PopupTableView()
    private var items: [ClipboardItem] = []

    // Always exactly 5 rows — items at top, glass below if fewer, scrolls if more
    var idealHeight: CGFloat {
        CGFloat(Design.fixedRows) * Design.rowH + Design.vPad * 2
    }

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(tableView)
    }

    func render(items: [ClipboardItem]) {
        let pinned = items.filter(\.isPinned)
        let recent = items.filter { !$0.isPinned }
        self.items = pinned + recent
        tableView.reloadData()
        if !self.items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Build UI

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Glass background — dark popover style
        fx.material      = .popover
        fx.blendingMode  = .behindWindow
        fx.state         = .active
        fx.wantsLayer    = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)

        // Table
        tableView.headerView                  = nil
        tableView.backgroundColor             = .clear
        tableView.intercellSpacing            = NSSize(width: 0, height: 2)
        tableView.rowHeight                   = Design.rowH
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle     = .regular
        tableView.dataSource                  = self
        tableView.delegate                    = self
        tableView.popupView                   = self
        tableView.columnAutoresizingStyle     = .uniformColumnAutoresizingStyle
        tableView.target                      = self
        tableView.action                      = #selector(rowClicked)
        let col = NSTableColumn(identifier: .init("item"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        scrollView.documentView       = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground    = false
        scrollView.borderType         = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.hPad),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.hPad),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Design.vPad),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.vPad)
        ])
    }

    // MARK: - Actions

    fileprivate func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let cur  = tableView.selectedRow
        let next = max(0, min(items.count - 1, (cur < 0 ? (delta > 0 ? -1 : items.count) : cur) + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    fileprivate func confirmSelection() {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        delegate?.popupView(self, didChoose: items[row])
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        delegate?.popupView(self, didChoose: items[row])
    }

    @objc fileprivate func togglePin(_ sender: PinButton) {
        guard let item = sender.item else { return }
        delegate?.popupView(self, didTogglePin: item)
    }
}

// MARK: - Table data source / delegate

extension ClipboardPopupView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { max(items.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Design.rowH }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !items.isEmpty }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if items.isEmpty {
            let v = NSTextField(labelWithString: "Nothing copied yet")
            v.textColor = .tertiaryLabelColor
            v.alignment = .center
            v.font = .systemFont(ofSize: 12)
            return v
        }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: ClipRow.id, owner: nil) as? ClipRow ?? ClipRow()
        cell.configure(item: item, target: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PremiumRowView()
    }
}

// MARK: - Keyboard

@MainActor
private final class PopupTableView: NSTableView {
    weak var popupView: ClipboardPopupView?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: popupView?.confirmSelection()   // Return / Enter → paste
        case 53:     window?.orderOut(nil)            // Escape → close
        case 125:    popupView?.moveSelection(1)      // ↓
        case 126:    popupView?.moveSelection(-1)     // ↑
        default:     super.keyDown(with: event)
        }
    }
}

// MARK: - Row cell

@MainActor
private final class ClipRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("clip-row")

    private let label     = NSTextField(labelWithString: "")
    private let pinButton = PinButton()
    private var currentItem: ClipboardItem?

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id; build() }
    required init?(coder: NSCoder) { super.init(coder: coder); identifier = Self.id; build() }

    func configure(item: ClipboardItem, target: ClipboardPopupView) {
        currentItem = item
        let first = item.content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? item.content
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        label.stringValue = trimmed.count > 80 ? String(trimmed.prefix(80)) + "\u{2026}" : trimmed
        label.font        = item.isPinned ? Design.pinnedFont : Design.textFont

        let cfg  = NSImage.SymbolConfiguration(pointSize: Design.pinSize * 0.75, weight: .regular)
        let name = item.isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?                .withSymbolConfiguration(cfg)
        pinButton.item   = item
        pinButton.target = target
        pinButton.action = #selector(ClipboardPopupView.togglePin(_:))
        refreshColors()
    }

    // Called by PremiumRowView when selection changes
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    private func refreshColors() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? .white : .labelColor
        guard let item = currentItem else { return }
        if selected {
            pinButton.contentTintColor = NSColor.white.withAlphaComponent(item.isPinned ? 1.0 : 0.5)
        } else {
            pinButton.contentTintColor = item.isPinned ? .controlAccentColor : .tertiaryLabelColor
        }
    }

    private func build() {
        wantsLayer = true

        label.lineBreakMode = .byTruncatingTail
        label.textColor     = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        pinButton.bezelStyle    = .inline
        pinButton.isBordered    = false
        pinButton.imageScaling  = .scaleProportionallyDown
        pinButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(pinButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),

            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: Design.pinSize),
            pinButton.heightAnchor.constraint(equalToConstant: Design.pinSize)
        ])
    }
}

@MainActor
fileprivate final class PinButton: NSButton { var item: ClipboardItem? }

// MARK: - Row view (selection + hover rendering)

@MainActor
private final class PremiumRowView: NSTableRowView {

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            // Propagate to cell so text color updates
            for sub in subviews {
                if let cell = sub as? NSTableCellView {
                    cell.backgroundStyle = isSelected ? .emphasized : .normal
                }
            }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: Design.rowRadius, yRadius: Design.rowRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}
}

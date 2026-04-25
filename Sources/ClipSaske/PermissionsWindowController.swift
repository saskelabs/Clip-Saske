import AppKit
import ApplicationServices

@MainActor
final class PermissionsWindowController: NSWindowController {
    static let shared = PermissionsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip Saske — Permissions Required"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        let view = PermissionsView()
        window?.contentView = view
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.startPolling()
    }
}

@MainActor
final class PermissionsView: NSView {
    private let accessibilityRow = PermissionRow(
        title: "Accessibility",
        detail: "Detects focused text field and inserts pasted text"
    )
    private let inputMonitoringRow = PermissionRow(
        title: "Input Monitoring",
        detail: "Listens for the global ⌥⌘V hotkey"
    )
    private let actionButton = NSButton(title: "Grant Permissions", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var pollTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let heading = NSTextField(labelWithString: "Clip Saske needs two permissions to work")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(heading)

        root.addArrangedSubview(accessibilityRow)
        root.addArrangedSubview(inputMonitoringRow)

        let sep = NSBox()
        sep.boxType = .separator
        root.addArrangedSubview(sep)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        root.addArrangedSubview(statusLabel)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(grantTapped)
        root.addArrangedSubview(actionButton)

        let note = NSTextField(wrappingLabelWithString: "After granting, toggle each permission OFF then ON if the app still doesn't respond.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        root.addArrangedSubview(note)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
            actionButton.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56)
        ])
    }

    private func refresh() {
        let axOK  = AXIsProcessTrusted()
        // Input Monitoring: IOHIDCheckAccess returns true when granted
        let imOK  = inputMonitoringGranted()

        accessibilityRow.setGranted(axOK)
        inputMonitoringRow.setGranted(imOK)

        if axOK && imOK {
            statusLabel.stringValue = "✅ All permissions granted — hotkey is active"
            statusLabel.textColor   = .systemGreen
            actionButton.title      = "Close"
            actionButton.action     = #selector(closeTapped)
            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            let missing = [axOK ? nil : "Accessibility", imOK ? nil : "Input Monitoring"]
                .compactMap { $0 }.joined(separator: " and ")
            statusLabel.stringValue = "Missing: \(missing)"
            statusLabel.textColor   = .systemOrange
            actionButton.title      = "Open System Settings"
            actionButton.action     = #selector(grantTapped)
        }
    }

    @objc private func grantTapped() {
        // Trigger the system Accessibility prompt
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        // Open both relevant panes
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }

    private func inputMonitoringGranted() -> Bool {
        // CGEventTap creation is the only reliable runtime check for Input Monitoring
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        if let tap = testTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            return true
        }
        return false
    }
}

@MainActor
private final class PermissionRow: NSView {
    private let titleLabel  = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badge       = NSTextField(labelWithString: "")

    init(title: String, detail: String) {
        super.init(frame: .zero)
        titleLabel.stringValue  = title
        titleLabel.font         = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.stringValue = detail
        detailLabel.font        = .systemFont(ofSize: 11)
        detailLabel.textColor   = .secondaryLabelColor
        badge.font              = .systemFont(ofSize: 12, weight: .semibold)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setGranted(_ granted: Bool) {
        badge.stringValue  = granted ? "✅ Granted" : "❌ Required"
        badge.textColor    = granted ? .systemGreen : .systemRed
    }

    private func build() {
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment   = .leading
        textStack.spacing     = 2
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment   = .centerY
        row.spacing     = 12
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(badge)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private init() {
        let w = NSWindow(contentRect: NSRect(x:0,y:0,width:420,height:300),
                         styleMask: [.titled,.closable], backing: .buffered, defer: false)
        w.title = "Clip Saske — Settings"
        super.init(window: w)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(settingsStore: SettingsStore, hotkeyManager: HotkeyManager) {
        window?.contentView = SettingsView(settingsStore: settingsStore, hotkeyManager: hotkeyManager)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings View
@MainActor
final class SettingsView: NSView {
    private let settingsStore: SettingsStore
    private weak var hotkeyManager: HotkeyManager?
    private let hotkeyField    = HotkeyRecorderField()
    private let cleanupStepper = NSStepper()
    private let cleanupLabel   = NSTextField(labelWithString: "")
    private let maxStepper     = NSStepper()
    private let maxLabel       = NSTextField(labelWithString: "")
    private let syncCheckbox   = NSButton(checkboxWithTitle: "Enable cloud sync", target: nil, action: nil)
    private let loginCheckbox  = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let statusLabel    = NSTextField(labelWithString: "")

    init(settingsStore: SettingsStore, hotkeyManager: HotkeyManager) {
        self.settingsStore  = settingsStore
        self.hotkeyManager  = hotkeyManager
        super.init(frame: .zero)
        build()
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        // Hotkey
        hotkeyField.onRecordingChanged = { [weak self] recording in
            self?.hotkeyManager?.isRecording = recording
        }
        hotkeyField.onShortcutRecorded = { [weak self] s in
            self?.settingsStore.set("hotkey", value: s.storageValue)
            self?.flash("Hotkey saved: \(s.displayName)")
        }
        root.addArrangedSubview(row("Hotkey", hotkeyField, "Click the field then press your shortcut"))

        // Auto Cleanup
        cleanupStepper.minValue = 1; cleanupStepper.maxValue = 365; cleanupStepper.increment = 1
        cleanupStepper.valueWraps = false
        cleanupStepper.target = self; cleanupStepper.action = #selector(cleanupChanged)
        root.addArrangedSubview(row("Auto Cleanup", stepperView(cleanupLabel, cleanupStepper, "days")))

        // Max Items
        maxStepper.minValue = 10; maxStepper.maxValue = 5000; maxStepper.increment = 10
        maxStepper.valueWraps = false
        maxStepper.target = self; maxStepper.action = #selector(maxChanged)
        root.addArrangedSubview(row("Maximum Items", stepperView(maxLabel, maxStepper, "items")))

        // Sync
        syncCheckbox.target = self; syncCheckbox.action = #selector(syncChanged)
        root.addArrangedSubview(syncCheckbox)

        // Login
        loginCheckbox.target = self; loginCheckbox.action = #selector(loginChanged)
        root.addArrangedSubview(loginCheckbox)

        // Status
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        // Permissions button
        let perm = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openPerms))
        perm.bezelStyle = .rounded
        root.addArrangedSubview(perm)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    private func load() {
        let s = settingsStore.settings
        hotkeyField.setShortcut(KeyboardShortcut.parse(s.hotkey))
        cleanupStepper.doubleValue = Double(s.autoCleanupDays)
        cleanupLabel.stringValue = "\(s.autoCleanupDays)"
        maxStepper.doubleValue = Double(s.maxItems)
        maxLabel.stringValue = "\(s.maxItems)"
        syncCheckbox.state = s.syncEnabled ? .on : .off
        loginCheckbox.state = StartupAgent.isInstalled ? .on : .off
    }

    // MARK: Actions
    @objc private func cleanupChanged() {
        let v = Int(cleanupStepper.doubleValue)
        cleanupLabel.stringValue = "\(v)"
        settingsStore.set("auto_cleanup_days", value: "\(v)")
        flash("Auto cleanup: \(v) days")
    }
    @objc private func maxChanged() {
        let v = Int(maxStepper.doubleValue)
        maxLabel.stringValue = "\(v)"
        settingsStore.set("max_items", value: "\(v)")
        flash("Max items: \(v)")
    }
    @objc private func syncChanged() {
        let on = syncCheckbox.state == .on
        settingsStore.set("sync_enabled", value: on ? "true" : "false")
        flash(on ? "Sync enabled" : "Sync disabled")
    }
    @objc private func loginChanged() {
        do {
            if loginCheckbox.state == .on {
                try StartupAgent.install()
                flash("Will start at login")
            } else {
                try StartupAgent.uninstall()
                flash("Removed from login items")
            }
        } catch {
            loginCheckbox.state = loginCheckbox.state == .on ? .off : .on
            flash("Error: \(error.localizedDescription)")
        }
    }
    @objc private func openPerms() { PermissionsWindowController.shared.show() }

    private func flash(_ msg: String) {
        statusLabel.stringValue = msg
        statusLabel.textColor = .controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusLabel.stringValue = ""
        }
    }

    // MARK: Helpers
    private func row(_ title: String, _ ctrl: NSView, _ hint: String? = nil) -> NSView {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 2
        right.addArrangedSubview(ctrl)
        if let hint {
            let h = NSTextField(labelWithString: hint)
            h.font = .systemFont(ofSize: 10)
            h.textColor = .tertiaryLabelColor
            right.addArrangedSubview(h)
        }
        let r = NSStackView(views: [lbl, right])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 12
        return r
    }

    private func stepperView(_ label: NSTextField, _ stepper: NSStepper, _ suffix: String) -> NSView {
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let suf = NSTextField(labelWithString: suffix)
        suf.font = .systemFont(ofSize: 12); suf.textColor = .secondaryLabelColor
        let v = NSStackView(views: [label, stepper, suf])
        v.orientation = .horizontal; v.spacing = 6; v.alignment = .centerY
        return v
    }
}

// MARK: - Hotkey Recorder Field
@MainActor
final class HotkeyRecorderField: NSTextField {
    var onShortcutRecorded: ((KeyboardShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?   // true = started, false = done/cancelled
    private(set) var currentShortcut: KeyboardShortcut?
    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }


    private func setup() {
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholderString = "Click to record"
        widthAnchor.constraint(equalToConstant: 180).isActive = true
    }

    func setShortcut(_ s: KeyboardShortcut) {
        currentShortcut = s
        stringValue = s.displayName
        textColor = .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { cancelRecording(); return }
        startRecording()
    }

    private func startRecording() {
        isRecording = true
        stringValue = "🔴 Press shortcut…"
        textColor = .controlAccentColor
        onRecordingChanged?(true)   // tell HotkeyManager to stop consuming events

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.handleEvent(event)
            return nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        // Escape cancels
        if event.keyCode == 53 { cancelRecording(); return }

        let nsFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !nsFlags.isEmpty else { return }

        // Ignore bare modifier-only keys
        let modOnlyCodes: Set<UInt16> = [54,55,56,57,58,59,60,61,62,63]
        guard !modOnlyCodes.contains(event.keyCode) else { return }

        var parts: [String] = []
        if nsFlags.contains(.option)  { parts.append("option") }
        if nsFlags.contains(.command) { parts.append("command") }
        if nsFlags.contains(.control) { parts.append("control") }
        if nsFlags.contains(.shift)   { parts.append("shift") }
        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty, key != " " else { return }
        parts.append(key)

        let s = KeyboardShortcut.parse(parts.joined(separator: "+"))
        currentShortcut = s
        stringValue = s.displayName
        textColor = .labelColor
        isRecording = false
        stopMonitor()
        onRecordingChanged?(false)  // tell HotkeyManager it can resume
        onShortcutRecorded?(s)
    }

    private func cancelRecording() {
        isRecording = false
        stringValue = currentShortcut?.displayName ?? ""
        textColor = .labelColor
        stopMonitor()
        onRecordingChanged?(false)
    }

    private func stopMonitor() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

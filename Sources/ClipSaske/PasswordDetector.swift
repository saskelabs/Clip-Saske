import AppKit

final class PasswordDetector {
    private let accessibilityMonitor: AccessibilityMonitor
    private let sensitivePatterns = [
        #"(?i)\bpassword\b"#,
        #"(?i)\botp\b"#,
        #"(?i)\btoken\b"#,
        #"(?i)\bsecret\b"#,
        #"(?i)\bapi[_ -]?key\b"#,
        #"(?i)\bprivate[_ -]?key\b"#,
        #"(?i)\bbearer\s+[a-z0-9._~+/=-]{16,}"#,
        #"\b\d{6}\b"#
    ]
    private let excludedApps = ["1Password", "Bitwarden", "Keychain Access", "Passwords"]

    init(accessibilityMonitor: AccessibilityMonitor) {
        self.accessibilityMonitor = accessibilityMonitor
    }

    func shouldIgnoreClipboard(content: String, sourceApp: String, pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        if pasteboardTypes.contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" }) {
            return true
        }
        if accessibilityMonitor.focusedElementKind() == .secureTextField {
            return true
        }
        if excludedApps.contains(where: { sourceApp.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return sensitivePatterns.contains { pattern in
            content.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

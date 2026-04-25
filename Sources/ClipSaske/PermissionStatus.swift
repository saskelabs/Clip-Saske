import ApplicationServices
import AppKit

enum PermissionStatus {
    static let didRequirePermissionsNotification = Notification.Name("ClipSaskeDidRequirePermissions")

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

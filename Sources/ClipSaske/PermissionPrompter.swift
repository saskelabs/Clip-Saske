import ApplicationServices
import AppKit

enum PermissionPrompter {
    @MainActor
    static func promptIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

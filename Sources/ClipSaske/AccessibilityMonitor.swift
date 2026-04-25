import ApplicationServices
import AppKit

enum FocusedElementKind {
    case textField
    case textArea
    case searchField
    case secureTextField
    case other

    var isTextInput: Bool {
        switch self {
        case .textField, .textArea, .searchField, .secureTextField:
            true
        case .other:
            false
        }
    }
}

final class AccessibilityMonitor {
    func focusedElementKind() -> FocusedElementKind {
        guard AXIsProcessTrusted() else { return .other }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return .other
        }

        let role = attribute(element, kAXRoleAttribute)
        let subrole = attribute(element, kAXSubroleAttribute)
        let description = attribute(element, kAXDescriptionAttribute)

        if role == kAXTextFieldRole as String && (subrole?.localizedCaseInsensitiveContains("secure") == true || description?.localizedCaseInsensitiveContains("secure") == true) {
            return .secureTextField
        }
        if role == kAXTextFieldRole as String {
            if subrole?.localizedCaseInsensitiveContains("search") == true || description?.localizedCaseInsensitiveContains("search") == true {
                return .searchField
            }
            return .textField
        }
        if role == kAXTextAreaRole as String {
            return .textArea
        }
        if role == kAXComboBoxRole as String {
            return .textField
        }
        return .other
    }

    func focusedElementIsTextInput() -> Bool {
        focusedElementKind().isTextInput
    }

    private func attribute(_ element: CFTypeRef, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, key as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

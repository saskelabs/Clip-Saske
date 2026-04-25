import AppKit
import Carbon.HIToolbox

struct KeyboardShortcut: Equatable {
    var keyCode: Int64
    var modifiers: CGEventFlags
    var displayName: String
    var storageValue: String

    static let defaultShortcut = KeyboardShortcut(
        keyCode: Int64(kVK_ANSI_V),
        modifiers: [.maskCommand, .maskAlternate],
        displayName: "Option + Command + V",
        storageValue: "option+command+v"
    )

    func matches(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return event.getIntegerValueField(.keyboardEventKeycode) == keyCode
            && flags.isExactMatch(for: modifiers)
    }

    static func parse(_ value: String) -> KeyboardShortcut {
        let parts = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard let key = parts.last, let keyCode = keyCodes[key] else {
            return .defaultShortcut
        }

        var modifiers = CGEventFlags()
        var display: [String] = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command":
                modifiers.insert(.maskCommand)
                display.append("⌘")
            case "opt", "option", "alt":
                modifiers.insert(.maskAlternate)
                display.append("⌥")
            case "ctrl", "control":
                modifiers.insert(.maskControl)
                display.append("⌃")
            case "shift":
                modifiers.insert(.maskShift)
                display.append("⇧")
            default:
                break
            }
        }

        guard !modifiers.isEmpty else { return .defaultShortcut }
        let keyDisplay = keyDisplays[key] ?? key.uppercased()
        return KeyboardShortcut(
            keyCode: Int64(keyCode),
            modifiers: modifiers,
            displayName: display.joined() + " " + keyDisplay,
            storageValue: parts.joined(separator: "+")
        )
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "esc": kVK_Escape,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal
    ]

    private static let keyDisplays: [String: String] = [
        "space": "Space", "return": "↩", "tab": "⇥", "esc": "⎋",
        "\\": "\\", "`": "`"
    ]
}

private extension CGEventFlags {
    func isExactMatch(for required: CGEventFlags) -> Bool {
        // We only care about Cmd, Opt, Ctrl, Shift. Ignore CapsLock, etc.
        let relevantMasks: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let currentRelevant = self.intersection(relevantMasks)
        let requiredRelevant = required.intersection(relevantMasks)
        return currentRelevant == requiredRelevant
    }
}

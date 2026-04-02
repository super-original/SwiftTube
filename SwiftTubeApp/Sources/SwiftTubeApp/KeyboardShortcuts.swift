import AppKit
import Foundation

struct KeyBinding: Codable, Hashable, Sendable {
    var keyCode: UInt16?
    var modifiers: KeyBindingModifiers = []
    var keyLabel: String = ""

    static let unbound = KeyBinding()

    var isBound: Bool {
        keyCode != nil
    }

    var displayText: String {
        guard isBound else { return "Not Bound" }

        var parts = modifiers.displayParts
        parts.append(keyLabel)
        return parts.joined(separator: " + ")
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let keyCode else { return false }
        return event.keyCode == keyCode && KeyBindingModifiers(event.modifierFlags) == modifiers
    }

    static func binding(from event: NSEvent) -> KeyBinding? {
        guard event.type == .keyDown else { return nil }
        guard !Self.isModifierOnly(event) else { return nil }
        guard let keyLabel = Self.keyLabel(for: event) else { return nil }

        return KeyBinding(
            keyCode: event.keyCode,
            modifiers: KeyBindingModifiers(event.modifierFlags),
            keyLabel: keyLabel
        )
    }

    static func legacyCharacter(_ character: String) -> KeyBinding? {
        let normalized = character.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keyCode = keyCodeMap[normalized],
              let label = displayLabelMap[normalized] else {
            return nil
        }

        return KeyBinding(keyCode: keyCode, modifiers: [], keyLabel: label)
    }
}

struct KeyBindingModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = KeyBindingModifiers(rawValue: 1 << 0)
    static let option = KeyBindingModifiers(rawValue: 1 << 1)
    static let control = KeyBindingModifiers(rawValue: 1 << 2)
    static let shift = KeyBindingModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var resolved: KeyBindingModifiers = []
        if flags.contains(.command) { resolved.insert(.command) }
        if flags.contains(.option) { resolved.insert(.option) }
        if flags.contains(.control) { resolved.insert(.control) }
        if flags.contains(.shift) { resolved.insert(.shift) }
        self = resolved
    }

    var displayParts: [String] {
        var parts: [String] = []
        if contains(.command) { parts.append("Command") }
        if contains(.option) { parts.append("Option") }
        if contains(.control) { parts.append("Control") }
        if contains(.shift) { parts.append("Shift") }
        return parts
    }
}

private extension KeyBinding {
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    static let specialKeyLabels: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        117: "Forward Delete",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
        115: "Home",
        119: "End",
        116: "Page Up",
        121: "Page Down"
    ]

    static let keyCodeMap: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50
    ]

    static let displayLabelMap: [String: String] = [
        "a": "A", "s": "S", "d": "D", "f": "F", "h": "H", "g": "G", "z": "Z", "x": "X", "c": "C", "v": "V",
        "b": "B", "q": "Q", "w": "W", "e": "E", "r": "R", "y": "Y", "t": "T", "1": "1", "2": "2",
        "3": "3", "4": "4", "6": "6", "5": "5", "=": "=", "9": "9", "7": "7", "-": "-", "8": "8",
        "0": "0", "]": "]", "o": "O", "u": "U", "[": "[", "i": "I", "p": "P", "l": "L", "j": "J",
        "'": "'", "k": "K", ";": ";", "\\": "\\", ",": ",", "/": "/", "n": "N", "m": "M", ".": ".",
        "`": "`"
    ]

    static func isModifierOnly(_ event: NSEvent) -> Bool {
        modifierKeyCodes.contains(event.keyCode)
    }

    static func keyLabel(for event: NSEvent) -> String? {
        if let special = specialKeyLabels[event.keyCode] {
            return special
        }

        guard let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else {
            return nil
        }

        let normalized = raw.lowercased()
        return displayLabelMap[normalized] ?? raw.uppercased()
    }
}

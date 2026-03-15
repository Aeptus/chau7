import Foundation

public enum TerminalKeyPressError: LocalizedError, Equatable, Sendable {
    case emptyKey
    case unsupportedModifier(String)
    case unsupportedKey(String)
    case unsupportedCombination(key: String, modifiers: [String])

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "key must not be empty"
        case let .unsupportedModifier(modifier):
            return "unsupported modifier: \(modifier)"
        case let .unsupportedKey(key):
            return "unsupported key: \(key)"
        case let .unsupportedCombination(key, modifiers):
            let suffix = modifiers.isEmpty ? "" : " with modifiers \(modifiers.joined(separator: ", "))"
            return "unsupported key combination: \(key)\(suffix)"
        }
    }
}

public enum TerminalKeyModifier: String, CaseIterable, Codable, Sendable, Hashable {
    case shift
    case control
    case option

    public static func parse(_ rawValue: String) -> TerminalKeyModifier? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "shift":
            return .shift
        case "control", "ctrl":
            return .control
        case "option", "alt", "meta":
            return .option
        default:
            return nil
        }
    }
}

public struct EncodedTerminalKeyPress: Equatable, Sendable {
    public let bytes: [UInt8]
    public let text: String?

    public init(bytes: [UInt8], text: String?) {
        self.bytes = bytes
        self.text = text
    }
}

public struct TerminalKeyPress: Equatable, Sendable {
    public let key: String
    public let modifiers: Set<TerminalKeyModifier>

    public init(key rawKey: String, modifiers rawModifiers: [String] = []) throws {
        let normalizedKey = Self.normalizeKey(rawKey)
        guard !normalizedKey.isEmpty else {
            throw TerminalKeyPressError.emptyKey
        }

        var parsedModifiers: Set<TerminalKeyModifier> = []
        for rawModifier in rawModifiers {
            guard let modifier = TerminalKeyModifier.parse(rawModifier) else {
                throw TerminalKeyPressError.unsupportedModifier(rawModifier)
            }
            parsedModifiers.insert(modifier)
        }

        self.key = normalizedKey
        self.modifiers = parsedModifiers
    }

    public func encode(applicationCursorMode: Bool = false) throws -> EncodedTerminalKeyPress {
        if let encoded = encodeSpecialKey(applicationCursorMode: applicationCursorMode) {
            return encoded
        }

        if Self.namedKeys.contains(key) {
            throw TerminalKeyPressError.unsupportedCombination(key: key, modifiers: sortedModifierNames)
        }

        guard key.count == 1, let character = key.first else {
            throw TerminalKeyPressError.unsupportedKey(key)
        }

        return try encodeCharacter(character)
    }

    public var sortedModifierNames: [String] {
        modifiers
            .map(\.rawValue)
            .sorted()
    }

    private static func normalizeKey(_ rawKey: String) -> String {
        switch rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "return":
            return "enter"
        case "esc":
            return "escape"
        case "uparrow", "arrowup":
            return "up"
        case "downarrow", "arrowdown":
            return "down"
        case "leftarrow", "arrowleft":
            return "left"
        case "rightarrow", "arrowright":
            return "right"
        case "pageup", "pgup":
            return "page_up"
        case "pagedown", "pgdown":
            return "page_down"
        case "forwarddelete", "forward_delete", "del":
            return "delete"
        default:
            return rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static let namedKeys: Set<String> = [
        "enter",
        "escape",
        "tab",
        "backspace",
        "up",
        "down",
        "left",
        "right",
        "home",
        "end",
        "page_up",
        "page_down",
        "delete",
        "insert"
    ]

    private func encodeSpecialKey(applicationCursorMode: Bool) -> EncodedTerminalKeyPress? {
        let modifierParameter = xtermModifierParameter()
        let hasModifiers = modifierParameter > 1
        let shift = modifiers.contains(.shift)
        let control = modifiers.contains(.control)

        switch key {
        case "enter":
            guard modifiers.isEmpty else { return nil }
            return EncodedTerminalKeyPress(bytes: [0x0D], text: "\r")
        case "escape":
            guard modifiers.isEmpty else { return nil }
            return EncodedTerminalKeyPress(bytes: [0x1B], text: "\u{1B}")
        case "tab":
            if shift && modifiers.count == 1 {
                let bytes = csiSequence("Z")
                return EncodedTerminalKeyPress(bytes: bytes, text: String(bytes: bytes, encoding: .utf8))
            }
            guard modifiers.isEmpty else { return nil }
            return EncodedTerminalKeyPress(bytes: [0x09], text: "\t")
        case "backspace":
            if control && modifiers.count == 1 {
                return EncodedTerminalKeyPress(bytes: [0x08], text: "\u{8}")
            }
            guard modifiers.isEmpty else { return nil }
            return EncodedTerminalKeyPress(bytes: [0x7F], text: "\u{7F}")
        case "up":
            return EncodedTerminalKeyPress(
                bytes: arrowKeySequence("A", modifierParameter: modifierParameter, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode),
                text: nil
            )
        case "down":
            return EncodedTerminalKeyPress(
                bytes: arrowKeySequence("B", modifierParameter: modifierParameter, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode),
                text: nil
            )
        case "right":
            return EncodedTerminalKeyPress(
                bytes: arrowKeySequence("C", modifierParameter: modifierParameter, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode),
                text: nil
            )
        case "left":
            return EncodedTerminalKeyPress(
                bytes: arrowKeySequence("D", modifierParameter: modifierParameter, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode),
                text: nil
            )
        case "home":
            let bytes = hasModifiers ? csiSequenceWithModifier("1", modifierParameter: modifierParameter, terminator: "H") : csiSequence("H")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        case "end":
            let bytes = hasModifiers ? csiSequenceWithModifier("1", modifierParameter: modifierParameter, terminator: "F") : csiSequence("F")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        case "page_up":
            let bytes = hasModifiers ? csiSequenceWithModifier("5", modifierParameter: modifierParameter, terminator: "~") : csiSequence("5~")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        case "page_down":
            let bytes = hasModifiers ? csiSequenceWithModifier("6", modifierParameter: modifierParameter, terminator: "~") : csiSequence("6~")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        case "delete":
            let bytes = hasModifiers ? csiSequenceWithModifier("3", modifierParameter: modifierParameter, terminator: "~") : csiSequence("3~")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        case "insert":
            let bytes = hasModifiers ? csiSequenceWithModifier("2", modifierParameter: modifierParameter, terminator: "~") : csiSequence("2~")
            return EncodedTerminalKeyPress(bytes: bytes, text: nil)
        default:
            return nil
        }
    }

    private func encodeCharacter(_ character: Character) throws -> EncodedTerminalKeyPress {
        let shift = modifiers.contains(.shift)
        let control = modifiers.contains(.control)
        let option = modifiers.contains(.option)

        if control, let controlCode = Self.controlCharacter(for: character) {
            let bytes = option ? [0x1B, controlCode] : [controlCode]
            return EncodedTerminalKeyPress(bytes: bytes, text: String(bytes: bytes, encoding: .utf8))
        }

        if option {
            let scalar = shift ? String(character).uppercased() : String(character)
            let bytes = [UInt8(0x1B)] + Array(scalar.utf8)
            return EncodedTerminalKeyPress(bytes: bytes, text: String(bytes: bytes, encoding: .utf8))
        }

        throw TerminalKeyPressError.unsupportedCombination(key: key, modifiers: sortedModifierNames)
    }

    private func xtermModifierParameter() -> Int {
        var modifierParameter = 1
        if modifiers.contains(.shift) { modifierParameter += 1 }
        if modifiers.contains(.option) { modifierParameter += 2 }
        if modifiers.contains(.control) { modifierParameter += 4 }
        return modifierParameter
    }

    private func arrowKeySequence(
        _ direction: Character,
        modifierParameter: Int,
        hasModifiers: Bool,
        applicationCursorMode: Bool
    ) -> [UInt8] {
        if hasModifiers {
            return Array("\u{1B}[1;\(modifierParameter)\(direction)".utf8)
        }
        if applicationCursorMode {
            return Array("\u{1B}O\(direction)".utf8)
        }
        return Array("\u{1B}[\(direction)".utf8)
    }

    private func csiSequence(_ content: String) -> [UInt8] {
        Array("\u{1B}[\(content)".utf8)
    }

    private func csiSequenceWithModifier(_ prefix: String, modifierParameter: Int, terminator: String) -> [UInt8] {
        Array("\u{1B}[\(prefix);\(modifierParameter)\(terminator)".utf8)
    }

    private static func controlCharacter(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }

        if ascii >= 0x61, ascii <= 0x7A {
            return ascii - 0x60
        }
        if ascii >= 0x41, ascii <= 0x5A {
            return ascii - 0x40
        }

        switch character {
        case "[", "{":
            return 0x1B
        case "\\":
            return 0x1C
        case "]", "}":
            return 0x1D
        case "^", "~":
            return 0x1E
        case "_", "?":
            return 0x1F
        case "@", " ":
            return 0x00
        case "2":
            return 0x00
        case "3":
            return 0x1B
        case "4":
            return 0x1C
        case "5":
            return 0x1D
        case "6":
            return 0x1E
        case "7":
            return 0x1F
        case "8":
            return 0x7F
        default:
            return nil
        }
    }
}

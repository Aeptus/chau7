import Foundation

/// Pure encoder for terminal key escape sequences, keyed by macOS
/// virtual key codes.
///
/// Extracted from `RustTerminalView+Input.swift` (Stage 3 of the
/// SOLID/DRY plan, `docs/SOLID-DRY-REVIEW.md`). The view translates
/// `NSEvent` into plain values (key code + `Modifiers`) at its boundary
/// and forwards here; this type owns the byte sequences, so it can be
/// tested without AppKit.
public enum TerminalKeyEncoder {

    /// Keyboard modifiers, translated from `NSEvent.ModifierFlags` at the
    /// view boundary.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
    }

    /// macOS virtual key codes for the special keys this encoder handles.
    /// Values mirror Carbon's `kVK_*` constants (HIToolbox `Events.h`);
    /// duplicated here so Chau7Core stays Foundation-only.
    enum VirtualKey {
        static let returnKey: UInt16 = 0x24 // kVK_Return
        static let tab: UInt16 = 0x30 // kVK_Tab
        static let delete: UInt16 = 0x33 // kVK_Delete (backspace)
        static let escape: UInt16 = 0x35 // kVK_Escape
        static let keypadEnter: UInt16 = 0x4C // kVK_ANSI_KeypadEnter
        static let f5: UInt16 = 0x60 // kVK_F5
        static let f6: UInt16 = 0x61 // kVK_F6
        static let f7: UInt16 = 0x62 // kVK_F7
        static let f3: UInt16 = 0x63 // kVK_F3
        static let f8: UInt16 = 0x64 // kVK_F8
        static let f9: UInt16 = 0x65 // kVK_F9
        static let f11: UInt16 = 0x67 // kVK_F11
        static let f10: UInt16 = 0x6D // kVK_F10
        static let f12: UInt16 = 0x6F // kVK_F12
        static let help: UInt16 = 0x72 // kVK_Help (Insert on some keyboards)
        static let home: UInt16 = 0x73 // kVK_Home
        static let pageUp: UInt16 = 0x74 // kVK_PageUp
        static let forwardDelete: UInt16 = 0x75 // kVK_ForwardDelete
        static let f4: UInt16 = 0x76 // kVK_F4
        static let end: UInt16 = 0x77 // kVK_End
        static let f2: UInt16 = 0x78 // kVK_F2
        static let pageDown: UInt16 = 0x79 // kVK_PageDown
        static let f1: UInt16 = 0x7A // kVK_F1
        static let leftArrow: UInt16 = 0x7B // kVK_LeftArrow
        static let rightArrow: UInt16 = 0x7C // kVK_RightArrow
        static let downArrow: UInt16 = 0x7D // kVK_DownArrow
        static let upArrow: UInt16 = 0x7E // kVK_UpArrow
    }

    /// Generates escape sequences for special keys (arrows, function
    /// keys, navigation, editing keys). Returns nil when the key should
    /// be handled via regular character input.
    public static func specialKeySequence(
        keyCode: UInt16,
        modifiers: Modifiers,
        applicationCursorMode: Bool
    ) -> [UInt8]? {
        // Calculate xterm modifier parameter
        // 1 = none, 2 = shift, 3 = alt, 4 = shift+alt, 5 = ctrl, 6 = shift+ctrl, 7 = alt+ctrl, 8 = shift+alt+ctrl
        let modParam = xtermModifierParameter(modifiers)
        let hasModifiers = modParam > 1

        switch keyCode {
        // Arrow keys
        case VirtualKey.upArrow:
            return arrowKeySequence("A", modParam: modParam, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode)
        case VirtualKey.downArrow:
            return arrowKeySequence("B", modParam: modParam, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode)
        case VirtualKey.rightArrow:
            return arrowKeySequence("C", modParam: modParam, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode)
        case VirtualKey.leftArrow:
            return arrowKeySequence("D", modParam: modParam, hasModifiers: hasModifiers, applicationCursorMode: applicationCursorMode)
        // Navigation keys
        case VirtualKey.home:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "H") : csiSequence("H")
        case VirtualKey.end:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "F") : csiSequence("F")
        case VirtualKey.pageUp:
            return hasModifiers ? csiSequenceWithMod("5", modParam: modParam, terminator: "~") : csiSequence("5~")
        case VirtualKey.pageDown:
            return hasModifiers ? csiSequenceWithMod("6", modParam: modParam, terminator: "~") : csiSequence("6~")
        // Editing keys
        case VirtualKey.forwardDelete:
            return hasModifiers ? csiSequenceWithMod("3", modParam: modParam, terminator: "~") : csiSequence("3~")
        case VirtualKey.help: // Insert key on some keyboards
            return hasModifiers ? csiSequenceWithMod("2", modParam: modParam, terminator: "~") : csiSequence("2~")
        // Function keys F1-F12
        case VirtualKey.f1:
            return functionKeySequence(1, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f2:
            return functionKeySequence(2, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f3:
            return functionKeySequence(3, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f4:
            return functionKeySequence(4, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f5:
            return functionKeySequence(5, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f6:
            return functionKeySequence(6, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f7:
            return functionKeySequence(7, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f8:
            return functionKeySequence(8, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f9:
            return functionKeySequence(9, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f10:
            return functionKeySequence(10, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f11:
            return functionKeySequence(11, modParam: modParam, hasModifiers: hasModifiers)
        case VirtualKey.f12:
            return functionKeySequence(12, modParam: modParam, hasModifiers: hasModifiers)
        // Special character keys
        case VirtualKey.escape:
            return [0x1B]
        case VirtualKey.tab:
            if modifiers.contains(.shift) {
                return csiSequence("Z") // Shift+Tab sends CSI Z (backtab)
            }
            return [0x09] // Regular tab
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            return [0x0D] // Carriage return
        case VirtualKey.delete: // Backspace key
            if modifiers.contains(.control) {
                return [0x08] // Ctrl+Backspace sends BS
            }
            return [0x7F] // Regular backspace sends DEL
        default:
            return nil
        }
    }

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    static func xtermModifierParameter(_ modifiers: Modifiers) -> Int {
        var modParam = 1
        if modifiers.contains(.shift) { modParam += 1 }
        if modifiers.contains(.option) { modParam += 2 }
        if modifiers.contains(.control) { modParam += 4 }
        return modParam
    }

    /// Generates arrow key sequences, respecting application cursor mode (DECCKM)
    static func arrowKeySequence(_ direction: Character, modParam: Int, hasModifiers: Bool, applicationCursorMode: Bool) -> [UInt8] {
        if hasModifiers {
            // With modifiers: ESC [ 1 ; <mod> <direction>
            return Array("\u{1b}[1;\(modParam)\(direction)".utf8)
        } else if applicationCursorMode {
            // Application cursor mode: ESC O <direction> (SS3 sequence)
            return Array("\u{1b}O\(direction)".utf8)
        } else {
            // Normal mode: ESC [ <direction>
            return Array("\u{1b}[\(direction)".utf8)
        }
    }

    /// Generates a simple CSI sequence: ESC [ <content>
    static func csiSequence(_ content: String) -> [UInt8] {
        Array("\u{1b}[\(content)".utf8)
    }

    /// Generates a CSI sequence with modifier: ESC [ <prefix> ; <mod> <terminator>
    static func csiSequenceWithMod(_ prefix: String, modParam: Int, terminator: String) -> [UInt8] {
        Array("\u{1b}[\(prefix);\(modParam)\(terminator)".utf8)
    }

    /// Generates function key sequences (xterm-style)
    static func functionKeySequence(_ fKey: Int, modParam: Int, hasModifiers: Bool) -> [UInt8] {
        // F1-F4 use SS3 sequences without modifiers (legacy vt100 compatibility)
        // F1-F4 with modifiers and F5-F12 use CSI sequences with numeric codes
        //
        // Without modifiers:
        //   F1: ESC O P, F2: ESC O Q, F3: ESC O R, F4: ESC O S
        //   F5: ESC [15~, F6: ESC [17~, F7: ESC [18~, F8: ESC [19~
        //   F9: ESC [20~, F10: ESC [21~, F11: ESC [23~, F12: ESC [24~
        //
        // With modifiers:
        //   F1: ESC [11;Pm~, etc.

        if !hasModifiers, fKey <= 4 {
            // F1-F4 without modifiers use SS3 sequences
            let codes: [Character] = ["P", "Q", "R", "S"]
            return Array("\u{1b}O\(codes[fKey - 1])".utf8)
        }

        // F5+ and F1-F4 with modifiers use CSI ~ sequences
        // Map function key number to xterm numeric code
        let xtermKeyCode: Int
        switch fKey {
        case 1: xtermKeyCode = 11
        case 2: xtermKeyCode = 12
        case 3: xtermKeyCode = 13
        case 4: xtermKeyCode = 14
        case 5: xtermKeyCode = 15
        case 6: xtermKeyCode = 17 // Note: 16 is skipped
        case 7: xtermKeyCode = 18
        case 8: xtermKeyCode = 19
        case 9: xtermKeyCode = 20
        case 10: xtermKeyCode = 21
        case 11: xtermKeyCode = 23 // Note: 22 is skipped
        case 12: xtermKeyCode = 24
        default: xtermKeyCode = 15 + fKey
        }

        if hasModifiers {
            return Array("\u{1b}[\(xtermKeyCode);\(modParam)~".utf8)
        } else {
            return Array("\u{1b}[\(xtermKeyCode)~".utf8)
        }
    }

    /// Converts a character to its control character equivalent (Ctrl+A = 0x01, etc.)
    public static func controlCharacter(for char: Character) -> UInt8? {
        guard let ascii = char.asciiValue else { return nil }

        // Control characters are lowercase letter's ASCII value minus 0x60
        // Or uppercase letter's ASCII value minus 0x40
        // a-z: 0x61-0x7A -> Ctrl codes 0x01-0x1A
        // A-Z: 0x41-0x5A -> Ctrl codes 0x01-0x1A (same result)
        if ascii >= 0x61, ascii <= 0x7A {
            return ascii - 0x60
        }
        if ascii >= 0x41, ascii <= 0x5A {
            return ascii - 0x40
        }

        // Special control characters
        switch char {
        case "[", "{":
            return 0x1B // Ctrl+[ is ESC
        case "\\":
            return 0x1C // Ctrl+\ is FS
        case "]", "}":
            return 0x1D // Ctrl+] is GS
        case "^", "~":
            return 0x1E // Ctrl+^ is RS
        case "_", "?":
            return 0x1F // Ctrl+_ is US
        case "@", " ":
            return 0x00 // Ctrl+@ or Ctrl+Space is NUL
        case "2":
            return 0x00 // Ctrl+2 is NUL
        case "3":
            return 0x1B // Ctrl+3 is ESC
        case "4":
            return 0x1C // Ctrl+4 is FS
        case "5":
            return 0x1D // Ctrl+5 is GS
        case "6":
            return 0x1E // Ctrl+6 is RS
        case "7":
            return 0x1F // Ctrl+7 is US
        case "8":
            return 0x7F // Ctrl+8 is DEL
        default:
            return nil
        }
    }
}

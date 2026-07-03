import Foundation

/// Mouse tracking mode bit flags reported by the Rust terminal backend.
///
/// Source of truth: `rust/chau7_terminal/src/terminal.rs`
/// (`Chau7TerminalHandle::mouse_mode()`, exposed over FFI via
/// `chau7_terminal_get_mouse_mode` in `rust/chau7_terminal/src/ffi.rs`).
/// These raw values MUST stay in sync with the Rust bitmask — the
/// SGR flag already desynced once (it was incorrectly 0x08 on the Swift
/// side while Rust reported 0x10).
public struct MouseModeFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Mode 1000: report button press/release.
    public static let click = MouseModeFlags(rawValue: 0x01)
    /// Mode 1002: also report motion while a button is down.
    public static let drag = MouseModeFlags(rawValue: 0x02)
    /// Mode 1003: report all motion.
    public static let motion = MouseModeFlags(rawValue: 0x04)
    /// Mode 1004: focus in/out reporting.
    public static let focusInOut = MouseModeFlags(rawValue: 0x08)
    /// Mode 1006: use SGR encoding.
    public static let sgrMode = MouseModeFlags(rawValue: 0x10)
    /// Mask for any of the click/drag/motion tracking modes.
    public static let anyTracking: MouseModeFlags = [.click, .drag, .motion]
}

/// Pure encoder for xterm mouse reports (SGR mode 1006 and legacy
/// X10/normal byte encoding).
///
/// Extracted from `RustTerminalView+Mouse.swift` (Stage 3 of the
/// SOLID/DRY plan, `docs/SOLID-DRY-REVIEW.md`): the view owned three
/// hand-rolled copies of the SGR/X10 encoding and repeated the
/// modifier-bit math at every site. The view still owns hit-testing and
/// PTY delivery; this type owns the bytes.
public enum MouseReportEncoder {

    /// Keyboard modifiers held during a mouse event, translated from
    /// `NSEvent.ModifierFlags` at the view boundary.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
    }

    /// An encoded mouse report. SGR reports are ASCII text (historically
    /// sent through the text path); X10 reports are raw bytes because the
    /// coordinate bytes can exceed ASCII and must not be re-encoded.
    public enum Report: Equatable, Sendable {
        case text(String)
        case bytes([UInt8])
    }

    /// X10 coordinates are clamped so `coordinate + 33` fits in a byte
    /// (223 + 32 = 255).
    static let x10CoordinateLimit = 222

    /// Applies the xterm modifier bits to a base button code:
    /// Shift +4, Meta/Option +8, Control +16.
    public static func applyModifiers(to buttonCode: UInt8, modifiers: Modifiers) -> UInt8 {
        var code = buttonCode
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        return code
    }

    /// Encodes a button press or release.
    ///
    /// - Parameters:
    ///   - buttonCode: base button code (0 = left, 1 = middle, 2 = right).
    ///   - column:/row: zero-based cell coordinates.
    ///   - isRelease: true for button-up. SGR keeps the (modified) button
    ///     code and switches the terminator to `m`; X10 discards the
    ///     button and modifiers entirely and reports button 3 (release).
    ///   - useSGR: true when mode 1006 is active.
    public static func encodeButtonEvent(
        buttonCode: UInt8,
        modifiers: Modifiers,
        column: Int,
        row: Int,
        isRelease: Bool,
        useSGR: Bool
    ) -> Report {
        let code = applyModifiers(to: buttonCode, modifiers: modifiers)
        if useSGR {
            let terminator = isRelease ? "m" : "M"
            return .text("\u{1b}[<\(code);\(column + 1);\(row + 1)\(terminator)")
        }
        let releaseButton: UInt8 = isRelease ? 3 : code
        return .bytes(x10Bytes(buttonCode: releaseButton, column: column, row: row))
    }

    /// Encodes a motion report (mode 1002/1003). Motion adds 32 to the
    /// button code; `buttonCode == nil` means "no button held" (code 3).
    public static func encodeMotionEvent(
        buttonCode: UInt8?,
        modifiers: Modifiers,
        column: Int,
        row: Int,
        useSGR: Bool
    ) -> Report {
        let base: UInt8 = 32 + (buttonCode ?? 3)
        let code = applyModifiers(to: base, modifiers: modifiers)
        if useSGR {
            return .text("\u{1b}[<\(code);\(column + 1);\(row + 1)M")
        }
        return .bytes(x10Bytes(buttonCode: code, column: column, row: row))
    }

    /// Encodes a scroll-wheel report: button 64 = scroll up, 65 = scroll
    /// down (X10 buttons 4/5 with bit 6 set). Scroll has no release event.
    public static func encodeScrollEvent(
        isUp: Bool,
        modifiers: Modifiers,
        column: Int,
        row: Int,
        useSGR: Bool
    ) -> Report {
        let base: UInt8 = isUp ? 64 : 65
        let code = applyModifiers(to: base, modifiers: modifiers)
        if useSGR {
            return .text("\u{1b}[<\(code);\(column + 1);\(row + 1)M")
        }
        return .bytes(x10Bytes(buttonCode: code, column: column, row: row))
    }

    /// Legacy X10/normal encoding: `ESC [ M` followed by button + 32 and
    /// the clamped, offset coordinates.
    private static func x10Bytes(buttonCode: UInt8, column: Int, row: Int) -> [UInt8] {
        let colByte = UInt8(min(column, x10CoordinateLimit) + 33)
        let rowByte = UInt8(min(row, x10CoordinateLimit) + 33)
        return [0x1B, 0x5B, 0x4D, buttonCode + 32, colByte, rowByte]
    }
}

import Carbon
import XCTest
@testable import Chau7Core

/// Exact-bytes tests for the pure key-sequence encoder extracted from
/// `RustTerminalView+Input.swift` (Stage 3 of the SOLID/DRY plan).
/// Expected sequences are derived from the pre-extraction view
/// implementation — these tests pin behavior, they don't redesign it.
final class TerminalKeyEncoderTests: XCTestCase {

    private func sequence(
        _ keyCode: Int,
        _ modifiers: TerminalKeyEncoder.Modifiers = [],
        applicationCursorMode: Bool = false
    ) -> [UInt8]? {
        TerminalKeyEncoder.specialKeySequence(
            keyCode: UInt16(keyCode),
            modifiers: modifiers,
            applicationCursorMode: applicationCursorMode
        )
    }

    // MARK: - Virtual Key Code Mirror

    func testVirtualKeyCodesMatchCarbonConstants() {
        // Chau7Core stays Foundation-only, so the encoder mirrors the
        // Carbon kVK_ values. This test pins the mirror against HIToolbox.
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.returnKey, UInt16(kVK_Return))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.keypadEnter, UInt16(kVK_ANSI_KeypadEnter))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.tab, UInt16(kVK_Tab))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.delete, UInt16(kVK_Delete))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.escape, UInt16(kVK_Escape))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.home, UInt16(kVK_Home))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.end, UInt16(kVK_End))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.pageUp, UInt16(kVK_PageUp))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.pageDown, UInt16(kVK_PageDown))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.forwardDelete, UInt16(kVK_ForwardDelete))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.help, UInt16(kVK_Help))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.upArrow, UInt16(kVK_UpArrow))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.downArrow, UInt16(kVK_DownArrow))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.leftArrow, UInt16(kVK_LeftArrow))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.rightArrow, UInt16(kVK_RightArrow))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f1, UInt16(kVK_F1))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f2, UInt16(kVK_F2))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f3, UInt16(kVK_F3))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f4, UInt16(kVK_F4))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f5, UInt16(kVK_F5))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f6, UInt16(kVK_F6))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f7, UInt16(kVK_F7))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f8, UInt16(kVK_F8))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f9, UInt16(kVK_F9))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f10, UInt16(kVK_F10))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f11, UInt16(kVK_F11))
        XCTAssertEqual(TerminalKeyEncoder.VirtualKey.f12, UInt16(kVK_F12))
    }

    // MARK: - Arrow Keys

    func testArrowKeysNormalMode() {
        XCTAssertEqual(sequence(kVK_UpArrow), [0x1B, 0x5B, 0x41]) // ESC [ A
        XCTAssertEqual(sequence(kVK_DownArrow), [0x1B, 0x5B, 0x42]) // ESC [ B
        XCTAssertEqual(sequence(kVK_RightArrow), [0x1B, 0x5B, 0x43]) // ESC [ C
        XCTAssertEqual(sequence(kVK_LeftArrow), [0x1B, 0x5B, 0x44]) // ESC [ D
    }

    func testArrowKeysApplicationCursorMode() {
        // DECCKM: SS3 sequences (ESC O <dir>)
        XCTAssertEqual(sequence(kVK_UpArrow, applicationCursorMode: true), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(sequence(kVK_DownArrow, applicationCursorMode: true), [0x1B, 0x4F, 0x42])
        XCTAssertEqual(sequence(kVK_RightArrow, applicationCursorMode: true), [0x1B, 0x4F, 0x43])
        XCTAssertEqual(sequence(kVK_LeftArrow, applicationCursorMode: true), [0x1B, 0x4F, 0x44])
    }

    func testArrowKeysWithModifiers() {
        XCTAssertEqual(sequence(kVK_UpArrow, .shift), Array("\u{1b}[1;2A".utf8))
        XCTAssertEqual(sequence(kVK_LeftArrow, .control), Array("\u{1b}[1;5D".utf8))
        XCTAssertEqual(sequence(kVK_DownArrow, .option), Array("\u{1b}[1;3B".utf8))
        XCTAssertEqual(sequence(kVK_RightArrow, [.shift, .option, .control]), Array("\u{1b}[1;8C".utf8))
    }

    func testModifiedArrowKeysIgnoreApplicationCursorMode() {
        XCTAssertEqual(
            sequence(kVK_UpArrow, .shift, applicationCursorMode: true),
            Array("\u{1b}[1;2A".utf8)
        )
    }

    // MARK: - Navigation Keys

    func testHomeAndEnd() {
        XCTAssertEqual(sequence(kVK_Home), Array("\u{1b}[H".utf8))
        XCTAssertEqual(sequence(kVK_End), Array("\u{1b}[F".utf8))
        XCTAssertEqual(sequence(kVK_Home, .shift), Array("\u{1b}[1;2H".utf8))
        XCTAssertEqual(sequence(kVK_End, [.shift, .control]), Array("\u{1b}[1;6F".utf8))
    }

    func testPageUpAndPageDown() {
        XCTAssertEqual(sequence(kVK_PageUp), Array("\u{1b}[5~".utf8))
        XCTAssertEqual(sequence(kVK_PageDown), Array("\u{1b}[6~".utf8))
        XCTAssertEqual(sequence(kVK_PageDown, .control), Array("\u{1b}[6;5~".utf8))
    }

    func testEditingKeys() {
        XCTAssertEqual(sequence(kVK_ForwardDelete), Array("\u{1b}[3~".utf8))
        XCTAssertEqual(sequence(kVK_ForwardDelete, .shift), Array("\u{1b}[3;2~".utf8))
        XCTAssertEqual(sequence(kVK_Help), Array("\u{1b}[2~".utf8)) // Insert
    }

    // MARK: - Function Keys

    func testFunctionKeysF1ToF4UseSS3WithoutModifiers() {
        XCTAssertEqual(sequence(kVK_F1), Array("\u{1b}OP".utf8))
        XCTAssertEqual(sequence(kVK_F2), Array("\u{1b}OQ".utf8))
        XCTAssertEqual(sequence(kVK_F3), Array("\u{1b}OR".utf8))
        XCTAssertEqual(sequence(kVK_F4), Array("\u{1b}OS".utf8))
    }

    func testFunctionKeysF5ToF12UseCSICodes() {
        XCTAssertEqual(sequence(kVK_F5), Array("\u{1b}[15~".utf8))
        XCTAssertEqual(sequence(kVK_F6), Array("\u{1b}[17~".utf8)) // 16 is skipped
        XCTAssertEqual(sequence(kVK_F7), Array("\u{1b}[18~".utf8))
        XCTAssertEqual(sequence(kVK_F8), Array("\u{1b}[19~".utf8))
        XCTAssertEqual(sequence(kVK_F9), Array("\u{1b}[20~".utf8))
        XCTAssertEqual(sequence(kVK_F10), Array("\u{1b}[21~".utf8))
        XCTAssertEqual(sequence(kVK_F11), Array("\u{1b}[23~".utf8)) // 22 is skipped
        XCTAssertEqual(sequence(kVK_F12), Array("\u{1b}[24~".utf8))
    }

    func testFunctionKeysWithModifiersUseCSIEvenForF1ToF4() {
        XCTAssertEqual(sequence(kVK_F1, .shift), Array("\u{1b}[11;2~".utf8))
        XCTAssertEqual(sequence(kVK_F4, .control), Array("\u{1b}[14;5~".utf8))
        XCTAssertEqual(sequence(kVK_F5, [.shift, .control]), Array("\u{1b}[15;6~".utf8))
    }

    // MARK: - Special Character Keys

    func testEscapeTabReturnAndBackspace() {
        XCTAssertEqual(sequence(kVK_Escape), [0x1B])
        XCTAssertEqual(sequence(kVK_Tab), [0x09])
        XCTAssertEqual(sequence(kVK_Tab, .shift), Array("\u{1b}[Z".utf8)) // backtab
        XCTAssertEqual(sequence(kVK_Return), [0x0D])
        XCTAssertEqual(sequence(kVK_ANSI_KeypadEnter), [0x0D])
        XCTAssertEqual(sequence(kVK_Delete), [0x7F]) // backspace sends DEL
        XCTAssertEqual(sequence(kVK_Delete, .control), [0x08]) // Ctrl+Backspace sends BS
    }

    func testRegularCharacterKeyReturnsNil() {
        XCTAssertNil(sequence(kVK_ANSI_A))
        XCTAssertNil(sequence(kVK_ANSI_A, .shift))
    }

    // MARK: - Control Characters

    func testControlCharactersForLetters() {
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "a"), 0x01)
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "c"), 0x03)
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "C"), 0x03) // case-insensitive
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "z"), 0x1A)
    }

    func testControlCharactersForPunctuationAndDigits() {
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "["), 0x1B) // ESC
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "\\"), 0x1C) // FS
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "]"), 0x1D) // GS
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "^"), 0x1E) // RS
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "_"), 0x1F) // US
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: " "), 0x00) // NUL
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "2"), 0x00) // NUL
        XCTAssertEqual(TerminalKeyEncoder.controlCharacter(for: "8"), 0x7F) // DEL
    }

    func testControlCharacterReturnsNilForUnmappedInput() {
        XCTAssertNil(TerminalKeyEncoder.controlCharacter(for: "9"))
        XCTAssertNil(TerminalKeyEncoder.controlCharacter(for: "é"))
    }
}

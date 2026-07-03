import XCTest
@testable import Chau7Core

/// Exact-bytes tests for the pure mouse-report encoder extracted from
/// `RustTerminalView+Mouse.swift` (Stage 3 of the SOLID/DRY plan).
/// Expected sequences are derived from the pre-extraction inline
/// implementation — these tests pin behavior, they don't redesign it.
final class MouseReportEncoderTests: XCTestCase {

    // MARK: - MouseModeFlags (Rust FFI bitmask mirror)

    func testMouseModeFlagRawValuesMatchRustBitmask() {
        // Source of truth: rust/chau7_terminal/src/terminal.rs mouse_mode()
        XCTAssertEqual(MouseModeFlags.click.rawValue, 0x01)
        XCTAssertEqual(MouseModeFlags.drag.rawValue, 0x02)
        XCTAssertEqual(MouseModeFlags.motion.rawValue, 0x04)
        XCTAssertEqual(MouseModeFlags.focusInOut.rawValue, 0x08)
        XCTAssertEqual(MouseModeFlags.sgrMode.rawValue, 0x10)
        XCTAssertEqual(MouseModeFlags.anyTracking.rawValue, 0x07)
    }

    func testMouseModeFlagsTrackingDetection() {
        XCTAssertFalse(MouseModeFlags(rawValue: 0).contains(.sgrMode))
        XCTAssertTrue(MouseModeFlags(rawValue: 0x11).contains(.sgrMode))
        XCTAssertTrue(MouseModeFlags(rawValue: 0x11).contains(.click))
        XCTAssertFalse(MouseModeFlags(rawValue: 0x18).isDisjoint(with: [.focusInOut]))
        XCTAssertTrue(MouseModeFlags(rawValue: 0x18).isDisjoint(with: .anyTracking))
    }

    // MARK: - Modifier Bits

    func testModifierBitMath() {
        XCTAssertEqual(MouseReportEncoder.applyModifiers(to: 0, modifiers: []), 0)
        XCTAssertEqual(MouseReportEncoder.applyModifiers(to: 0, modifiers: .shift), 4)
        XCTAssertEqual(MouseReportEncoder.applyModifiers(to: 0, modifiers: .option), 8)
        XCTAssertEqual(MouseReportEncoder.applyModifiers(to: 0, modifiers: .control), 16)
        XCTAssertEqual(MouseReportEncoder.applyModifiers(to: 2, modifiers: [.shift, .option, .control]), 30)
    }

    // MARK: - SGR Press / Release

    func testSGRLeftPressEncodesOneBasedCoordinates() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [], column: 5, row: 10, isRelease: false, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<0;6;11M"))
    }

    func testSGRLeftReleaseUsesLowercaseTerminator() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [], column: 5, row: 10, isRelease: true, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<0;6;11m"))
    }

    func testSGRPressAppliesModifierBits() {
        // left (0) + shift (4) + control (16) = 20
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [.shift, .control], column: 5, row: 10, isRelease: false, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<20;6;11M"))
    }

    func testSGRReleaseKeepsButtonCodeAndModifiers() {
        // Unlike X10, SGR encodes the released button (right = 2) plus
        // modifiers (option = 8) and signals release via `m`.
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 2, modifiers: .option, column: 0, row: 0, isRelease: true, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<10;1;1m"))
    }

    func testSGRDoesNotClampLargeCoordinates() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [], column: 500, row: 300, isRelease: false, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<0;501;301M"))
    }

    // MARK: - X10 Press / Release

    func testX10LeftPressBytes() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [], column: 5, row: 10, isRelease: false, useSGR: false
        )
        // ESC [ M, button 0 + 32, col 5 + 33, row 10 + 33
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 32, 38, 43]))
    }

    func testX10PressIncludesModifierBits() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: .shift, column: 0, row: 0, isRelease: false, useSGR: false
        )
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 36, 33, 33]))
    }

    func testX10ReleaseDiscardsButtonAndModifiers() {
        // The legacy protocol always reports button 3 for release.
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 2, modifiers: [.shift, .control], column: 0, row: 0, isRelease: true, useSGR: false
        )
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 35, 33, 33]))
    }

    func testX10ClampsCoordinatesTo222() {
        let report = MouseReportEncoder.encodeButtonEvent(
            buttonCode: 0, modifiers: [], column: 500, row: 300, isRelease: false, useSGR: false
        )
        // 222 + 33 = 255 (0xFF) — the largest encodable coordinate byte
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 32, 0xFF, 0xFF]))
    }

    // MARK: - Motion

    func testSGRMotionWithoutButtonUsesCode35() {
        // 32 (motion) + 3 (no button held)
        let report = MouseReportEncoder.encodeMotionEvent(
            buttonCode: nil, modifiers: [], column: 5, row: 10, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<35;6;11M"))
    }

    func testSGRMotionWithLeftButtonHeld() {
        let report = MouseReportEncoder.encodeMotionEvent(
            buttonCode: 0, modifiers: [], column: 5, row: 10, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<32;6;11M"))
    }

    func testSGRMotionAppliesModifierBits() {
        // 32 + 0 (left) + 16 (control) = 48
        let report = MouseReportEncoder.encodeMotionEvent(
            buttonCode: 0, modifiers: .control, column: 0, row: 0, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<48;1;1M"))
    }

    func testX10MotionBytesAndClamp() {
        // 32 + 3 = 35, then + 32 = 67 on the wire; coordinates clamp at 222
        let report = MouseReportEncoder.encodeMotionEvent(
            buttonCode: nil, modifiers: [], column: 400, row: 2, useSGR: false
        )
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 67, 0xFF, 35]))
    }

    // MARK: - Scroll

    func testSGRScrollUpUsesButton64() {
        let report = MouseReportEncoder.encodeScrollEvent(
            isUp: true, modifiers: [], column: 5, row: 10, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<64;6;11M"))
    }

    func testSGRScrollDownUsesButton65() {
        let report = MouseReportEncoder.encodeScrollEvent(
            isUp: false, modifiers: [], column: 5, row: 10, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<65;6;11M"))
    }

    func testSGRScrollAppliesModifierBits() {
        // 64 + 4 (shift) = 68
        let report = MouseReportEncoder.encodeScrollEvent(
            isUp: true, modifiers: .shift, column: 0, row: 0, useSGR: true
        )
        XCTAssertEqual(report, .text("\u{1b}[<68;1;1M"))
    }

    func testX10ScrollUpBytes() {
        // 64 + 32 = 96 on the wire
        let report = MouseReportEncoder.encodeScrollEvent(
            isUp: true, modifiers: [], column: 5, row: 10, useSGR: false
        )
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 96, 38, 43]))
    }

    func testX10ScrollDownWithControlBytes() {
        // 65 + 16 (control) + 32 = 113
        let report = MouseReportEncoder.encodeScrollEvent(
            isUp: false, modifiers: .control, column: 0, row: 0, useSGR: false
        )
        XCTAssertEqual(report, .bytes([0x1B, 0x5B, 0x4D, 113, 33, 33]))
    }
}

import XCTest
@testable import Chau7Core

final class TerminalKeyPressTests: XCTestCase {

    func testEncodeEnterUsesCarriageReturn() throws {
        let keyPress = try TerminalKeyPress(key: "enter")
        let encoded = try keyPress.encode()

        XCTAssertEqual(encoded.bytes, [0x0D])
        XCTAssertEqual(encoded.text, "\r")
    }

    func testEncodeShiftTabUsesBacktabSequence() throws {
        let keyPress = try TerminalKeyPress(key: "tab", modifiers: ["shift"])
        let encoded = try keyPress.encode()

        XCTAssertEqual(encoded.bytes, Array("\u{1B}[Z".utf8))
    }

    func testEncodeControlCUsesControlCharacter() throws {
        let keyPress = try TerminalKeyPress(key: "c", modifiers: ["ctrl"])
        let encoded = try keyPress.encode()

        XCTAssertEqual(encoded.bytes, [0x03])
        XCTAssertEqual(encoded.text, "\u{3}")
    }

    func testEncodeAltBPrefixesEscape() throws {
        let keyPress = try TerminalKeyPress(key: "b", modifiers: ["alt"])
        let encoded = try keyPress.encode()

        XCTAssertEqual(encoded.bytes, [0x1B, 0x62])
        XCTAssertEqual(encoded.text, "\u{1B}b")
    }

    func testEncodeUpArrowRespectsApplicationCursorMode() throws {
        let keyPress = try TerminalKeyPress(key: "up")

        let encoded = try keyPress.encode(applicationCursorMode: true)

        XCTAssertEqual(encoded.bytes, Array("\u{1B}OA".utf8))
    }

    func testEncodeControlBackspaceUsesBS() throws {
        let keyPress = try TerminalKeyPress(key: "backspace", modifiers: ["control"])
        let encoded = try keyPress.encode()

        XCTAssertEqual(encoded.bytes, [0x08])
        XCTAssertEqual(encoded.text, "\u{8}")
    }

    func testRejectUnsupportedModifier() {
        XCTAssertThrowsError(try TerminalKeyPress(key: "enter", modifiers: ["hyper"])) { error in
            XCTAssertEqual(error as? TerminalKeyPressError, .unsupportedModifier("hyper"))
        }
    }

    func testRejectUnsupportedCombination() throws {
        let keyPress = try TerminalKeyPress(key: "enter", modifiers: ["shift"])

        XCTAssertThrowsError(try keyPress.encode()) { error in
            XCTAssertEqual(
                error as? TerminalKeyPressError,
                .unsupportedCombination(key: "enter", modifiers: ["shift"])
            )
        }
    }
}

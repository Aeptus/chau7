import XCTest
@testable import Chau7Core

final class TerminalCursorInputPolicyTests: XCTestCase {
    func testLiveTUIInputRemainsClickableWhileShellCommandIsRunning() {
        XCTAssertTrue(TerminalCursorInputPolicy.permitsClick(isAtPrompt: false, hostsTUIApp: true, isOnCursorLine: true, displayOffset: 0))
    }

    func testShellPromptAllowsClickingOnlyItsOwnLogicalLine() {
        XCTAssertTrue(TerminalCursorInputPolicy.permitsClick(isAtPrompt: true, hostsTUIApp: false, isOnCursorLine: true, displayOffset: 0))
        XCTAssertFalse(TerminalCursorInputPolicy.permitsClick(isAtPrompt: true, hostsTUIApp: false, isOnCursorLine: false, displayOffset: 0))
    }

    func testTUIOutputRowsAndScrollbackDoNotMoveTheInputCursor() {
        XCTAssertFalse(TerminalCursorInputPolicy.permitsClick(isAtPrompt: true, hostsTUIApp: true, isOnCursorLine: false, displayOffset: 0))
        XCTAssertFalse(TerminalCursorInputPolicy.permitsClick(isAtPrompt: true, hostsTUIApp: true, isOnCursorLine: true, displayOffset: 5))
    }

    func testRunningNonTUICommandDoesNotReceiveCursorKeys() {
        XCTAssertFalse(TerminalCursorInputPolicy.permitsClick(isAtPrompt: false, hostsTUIApp: false, isOnCursorLine: true, displayOffset: 0))
    }

    func testWrappedInputUsesLogicalCharacterOffsets() {
        XCTAssertEqual(TerminalCursorInputPolicy.characterDelta(in: "echo hello --flag", fromUTF16: 15, toUTF16: 5), -10)
    }

    func testUnicodeCharactersDoNotCountAsMultipleArrowPresses() {
        XCTAssertEqual(TerminalCursorInputPolicy.characterDelta(in: "a😀e\u{301}z", fromUTF16: 0, toUTF16: 5), 3)
        XCTAssertEqual(TerminalCursorInputPolicy.characterDelta(in: "a😀e\u{301}z", fromUTF16: 5, toUTF16: 1), -2)
    }

    func testInvalidOrPartialGraphemeOffsetsAreRejected() {
        for offset in [-1, 2, 4, 20] {
            XCTAssertNil(TerminalCursorInputPolicy.characterDelta(in: "a😀e\u{301}z", fromUTF16: 0, toUTF16: offset))
        }
    }
}

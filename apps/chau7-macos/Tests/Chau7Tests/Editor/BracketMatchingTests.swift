import XCTest
import Foundation
@testable import Chau7

/// Bracket matching used to materialise `Array(text)` from the document on
/// every keystroke (and on every selection change!) just to do random-access
/// lookups. The new implementation walks `NSString` UTF-16 code units
/// directly. These tests cover the pure scans so the algorithmic behaviour
/// stays correct across the rewrite.
final class BracketMatchingTests: XCTestCase {

    private let open: unichar = 0x28 // (
    private let close: unichar = 0x29 // )

    func testForwardFindsImmediateMatch() {
        let text: NSString = "()"
        let match = EditorCoordinator.findMatchingBracketForward(
            in: text, from: 0, open: open, close: close
        )
        XCTAssertEqual(match, 1)
    }

    func testForwardSkipsNestedPairs() {
        let text: NSString = "( () () )"
        let match = EditorCoordinator.findMatchingBracketForward(
            in: text, from: 0, open: open, close: close
        )
        XCTAssertEqual(match, text.length - 1)
    }

    func testForwardReturnsNilWhenUnbalanced() {
        let text: NSString = "( ( no end"
        let match = EditorCoordinator.findMatchingBracketForward(
            in: text, from: 0, open: open, close: close
        )
        XCTAssertNil(match)
    }

    func testBackwardFindsImmediateMatch() {
        let text: NSString = "()"
        let match = EditorCoordinator.findMatchingBracketBackward(
            in: text, from: 1, open: open, close: close
        )
        XCTAssertEqual(match, 0)
    }

    func testBackwardSkipsNestedPairs() {
        let text: NSString = "( () () )"
        let match = EditorCoordinator.findMatchingBracketBackward(
            in: text, from: text.length - 1, open: open, close: close
        )
        XCTAssertEqual(match, 0)
    }

    func testBackwardReturnsNilWhenUnbalanced() {
        let text: NSString = "no start )"
        let match = EditorCoordinator.findMatchingBracketBackward(
            in: text, from: text.length - 1, open: open, close: close
        )
        XCTAssertNil(match)
    }

    func testForwardHandlesEmojiWithoutCrashing() {
        // Surrogate pair (🎉) sits inside the text — its individual UTF-16
        // code units must not be confused with brackets. Just make sure the
        // scan finds the right match position and doesn't crash on the pair.
        let text: NSString = "(🎉 nested () done)"
        let match = EditorCoordinator.findMatchingBracketForward(
            in: text, from: 0, open: open, close: close
        )
        XCTAssertEqual(match, text.length - 1)
    }
}

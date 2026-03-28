import XCTest
@testable import Chau7Core

final class OptionModifiedTextRoutingTests: XCTestCase {
    func testTreatsInternationalBracketShortcutAsLiteralText() {
        XCTAssertTrue(
            OptionModifiedTextRouting.shouldTreatAsLiteralText(
                characters: "[",
                charactersIgnoringModifiers: "5",
                hasOption: true,
                hasControl: false,
                hasCommand: false
            )
        )
    }

    func testTreatsInternationalBraceShortcutAsLiteralText() {
        XCTAssertTrue(
            OptionModifiedTextRouting.shouldTreatAsLiteralText(
                characters: "{",
                charactersIgnoringModifiers: "(",
                hasOption: true,
                hasControl: false,
                hasCommand: false
            )
        )
    }

    func testKeepsOptionLetterChordAsMetaShortcut() {
        XCTAssertFalse(
            OptionModifiedTextRouting.shouldTreatAsLiteralText(
                characters: "\u{222B}",
                charactersIgnoringModifiers: "b",
                hasOption: true,
                hasControl: false,
                hasCommand: false
            )
        )
    }

    func testIgnoresNonOptionChord() {
        XCTAssertFalse(
            OptionModifiedTextRouting.shouldTreatAsLiteralText(
                characters: "[",
                charactersIgnoringModifiers: "5",
                hasOption: false,
                hasControl: false,
                hasCommand: false
            )
        )
    }
}

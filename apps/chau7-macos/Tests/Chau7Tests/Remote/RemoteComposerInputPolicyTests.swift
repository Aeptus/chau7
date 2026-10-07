import XCTest
@testable import Chau7Core

final class RemoteComposerInputPolicyTests: XCTestCase {
    func testReturnSubmitsOnlyWhenHoldIsOff() {
        XCTAssertTrue(RemoteComposerInputPolicy.shouldSubmit(insertedText: "\n", isPasting: false, holdToSend: false))
        XCTAssertFalse(RemoteComposerInputPolicy.shouldSubmit(insertedText: "\n", isPasting: false, holdToSend: true))
    }

    func testPastedTextNeverSubmitsIncludingSingleNewline() {
        for text in ["\n", "echo hello\n", "first\nsecond\n", "\r\n", "😀\n"] {
            XCTAssertFalse(RemoteComposerInputPolicy.shouldSubmit(insertedText: text, isPasting: true, holdToSend: false))
        }
    }

    func testOrdinaryTypingAndMultilineInsertionsAreNotReturn() {
        for text in ["", "a", "echo hi\n", "\n\n"] {
            XCTAssertFalse(RemoteComposerInputPolicy.shouldSubmit(insertedText: text, isPasting: false, holdToSend: false))
        }
    }
}

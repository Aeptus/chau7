import UIKit
import XCTest

@MainActor
final class RemoteTerminalComposerTests: XCTestCase {
    func testKeyboardReturnSubmitsWithoutInsertingANewline() {
        let view = RemoteTerminalComposerTextView()
        view.text = "echo hello"
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.insertText("\n")
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(view.text, "echo hello")
    }

    func testPastedSingleNewlineRemainsEditableAndGuardRestores() {
        let view = RemoteTerminalComposerTextView()
        view.text = "echo hello"
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.performPaste { view.insertText("\n") }
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(view.text, "echo hello\n")
        view.insertText("\n")
        XCTAssertEqual(submissions, 1)
    }

    func testMultilinePasteAtSelectionPreservesBytesWithoutSubmitting() {
        let view = RemoteTerminalComposerTextView()
        view.text = "before after"
        view.selectedRange = NSRange(location: 7, length: 5)
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.performPaste { view.insertText("echo café\nnext\n") }
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(view.text, "before echo café\nnext\n")
    }

    func testFinalPasteDelegatePreservesSingleNewlineAndInsertionRange() throws {
        let view = RemoteTerminalComposerTextView()
        view.text = "before after"
        view.selectedRange = NSRange(location: 7, length: 5)
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        let delegate = InputDelegate()
        view.delegate = delegate
        let target = try XCTUnwrap(view.selectedTextRange)
        let inserted = view.textPasteConfigurationSupporting(view,
            performPasteOf: NSAttributedString(string: "\n"), to: target)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(view.text, "before \n")
        XCTAssertEqual(view.text(in: inserted), "\n")
        XCTAssertTrue(view.pasteDelegate === view)
        XCTAssertEqual(delegate.latestText, view.text)
    }

    private final class InputDelegate: NSObject, UITextViewDelegate {
        var latestText: String?
        func textViewDidChange(_ textView: UITextView) { latestText = textView.text }
    }

    func testHoldToSendAllowsReturnInsideTheComposer() {
        let view = RemoteTerminalComposerTextView()
        view.holdToSend = true
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.insertText("\n")
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(view.text, "\n")
    }
}

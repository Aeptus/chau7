import SwiftUI
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

    // MARK: - Focus (#364)

    func testEditingCallbacksPublishFocusToTheScreenState() {
        let focus = FocusBox()
        let composer = RemoteTerminalComposer(
            text: .constant(""),
            isFocused: Binding(get: { focus.value }, set: { focus.value = $0 }),
            holdToSend: false, onSubmit: {}
        )
        let coordinator = composer.makeCoordinator()
        let view = RemoteTerminalComposerTextView()
        coordinator.textViewDidBeginEditing(view)
        XCTAssertTrue(focus.value, "a tap that opens the keyboard must be recorded, or the next update closes it")
        coordinator.textViewDidEndEditing(view)
        XCTAssertFalse(focus.value)
    }

    private final class FocusBox: @unchecked Sendable { var value = false }

    // MARK: - Visible text (#365)

    func testDraftThatFitsDoesNotScrollAndGrowsWithItsLines() {
        let view = RemoteTerminalComposerTextView()
        let lineHeight = view.font?.lineHeight ?? 0
        let inset = view.textContainerInset.top + view.textContainerInset.bottom
        view.text = "one"
        XCTAssertEqual(view.composerHeight(fittingWidth: 240), lineHeight + inset, accuracy: 1)
        XCTAssertFalse(view.isScrollEnabled)
        view.text = "one\ntwo\nthree"
        XCTAssertEqual(view.composerHeight(fittingWidth: 240), lineHeight * 3 + inset, accuracy: 2)
        XCTAssertFalse(view.isScrollEnabled, "a scrolling view hides the first line of a draft that fits")
    }

    func testDraftTallerThanTheLimitIsCappedAndScrolls() {
        let view = RemoteTerminalComposerTextView()
        let lineHeight = view.font?.lineHeight ?? 0
        let inset = view.textContainerInset.top + view.textContainerInset.bottom
        view.text = Array(repeating: "line", count: 10).joined(separator: "\n")
        let tallest = lineHeight * CGFloat(RemoteTerminalComposerTextView.maxVisibleLines) + inset
        XCTAssertEqual(view.composerHeight(fittingWidth: 240), tallest, accuracy: 0.5)
        XCTAssertTrue(view.isScrollEnabled)
        view.text = "short again"
        _ = view.composerHeight(fittingWidth: 240)
        XCTAssertFalse(view.isScrollEnabled)
    }
}

import UIKit
import XCTest

@MainActor
final class RemoteTerminalSelectionViewTests: XCTestCase {
    func testReadOnlySnapshotSupportsNativeUnicodeSelection() throws {
        let text = "  echo 👩🏽‍💻 --flag\nnext"
        let view = RemoteTerminalSelectionTextView(text: text, fontSize: 13)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        view.selectedRange = (text as NSString).range(of: "echo 👩🏽‍💻")
        let range = try XCTUnwrap(view.selectedTextRange)
        XCTAssertEqual(view.text(in: range), "echo 👩🏽‍💻")
    }

    func testSelectionSurvivesRepeatedSnapshotAndFontUpdates() {
        let view = RemoteTerminalSelectionTextView(text: "old output", fontSize: 13)
        let selected = NSRange(location: 0, length: 3)
        view.selectedRange = selected
        view.setSnapshot("old output", fontSize: 18)
        XCTAssertEqual(view.selectedRange, selected)
        XCTAssertEqual(view.text, "old output")
    }

    func testNewSnapshotResetsTheOldSelection() {
        let view = RemoteTerminalSelectionTextView(text: "long old output", fontSize: 13)
        view.selectedRange = NSRange(location: 5, length: 3)
        view.setSnapshot("new", fontSize: 13)
        XCTAssertEqual(view.text, "new")
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
    }
}

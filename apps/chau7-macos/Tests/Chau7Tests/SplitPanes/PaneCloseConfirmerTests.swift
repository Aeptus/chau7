import XCTest
@testable import Chau7
@testable import Chau7Core

/// Direct tests for the extracted PaneCloseConfirmer. The integration path
/// is also covered by CloseDialogWiringTests via SplitPaneController; these
/// tests pin the confirmer's contract without spinning up a controller, so
/// adding a new branch to the save/discard/cancel policy gets a focused
/// failure here before bleeding through the integration suite.
@MainActor
final class PaneCloseConfirmerTests: XCTestCase {

    func testCancelDecisionReturnsAbort() {
        let dialogs = FakeDialogs()
        dialogs.nextCloseDecision = .cancel

        let editor = TextEditorModel()
        editor.updateContent("dirty\n")

        let result = PaneCloseConfirmer(dialogs: dialogs).confirmCloseDirty(editor)
        XCTAssertEqual(result, .abort)
        XCTAssertTrue(editor.isDirty, "Cancel must leave the editor untouched")
    }

    func testDontSaveDiscardsAndReturnsProceed() {
        let dialogs = FakeDialogs()
        dialogs.nextCloseDecision = .dontSave

        let editor = TextEditorModel()
        editor.updateContent("about to discard\n")
        XCTAssertTrue(editor.isDirty)

        let result = PaneCloseConfirmer(dialogs: dialogs).confirmCloseDirty(editor)
        XCTAssertEqual(result, .proceed)
        XCTAssertFalse(editor.isDirty, "Don't Save must clear the dirty flag")
    }

    func testSaveOnFileBackedEditorWritesAndProceeds() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_confirm_save_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "persisted\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let editor = TextEditorModel()
        editor.loadFile(at: tmpPath)
        waitUntilLoaded(editor, expecting: "persisted\n")
        editor.updateContent("saved version\n")

        let dialogs = FakeDialogs()
        dialogs.nextCloseDecision = .save

        let result = PaneCloseConfirmer(dialogs: dialogs).confirmCloseDirty(editor)
        XCTAssertEqual(result, .proceed)
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(try String(contentsOfFile: tmpPath, encoding: .utf8), "saved version\n")
    }

    func testSaveOnUntitledFallsBackToSaveAsPanel() {
        let dialogs = FakeDialogs()
        dialogs.nextCloseDecision = .save
        dialogs.nextSavePanelResult = nil // user cancels Save As

        let editor = TextEditorModel()
        editor.updateContent("never named\n")
        XCTAssertNil(editor.filePath)

        let result = PaneCloseConfirmer(dialogs: dialogs).confirmCloseDirty(editor)
        XCTAssertEqual(result, .abort, "Cancelling the Save As panel must abort the close")
        XCTAssertEqual(dialogs.runSaveAsCallCount, 1)
        XCTAssertTrue(editor.isDirty)
    }

    func testSaveOnUntitledRespectingChosenPath() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_confirm_saveas_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let dialogs = FakeDialogs()
        dialogs.nextCloseDecision = .save
        dialogs.nextSavePanelResult = tmpPath

        let editor = TextEditorModel()
        editor.updateContent("named via save-as\n")

        let result = PaneCloseConfirmer(dialogs: dialogs).confirmCloseDirty(editor)
        XCTAssertEqual(result, .proceed)
        XCTAssertEqual(editor.filePath, tmpPath)
        XCTAssertEqual(
            try String(contentsOfFile: tmpPath, encoding: .utf8),
            "named via save-as\n"
        )
    }

    private func waitUntilLoaded(
        _ editor: TextEditorModel,
        expecting content: String,
        timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !editor.isLoading, editor.content == content { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("editor did not load \"\(content)\" in time")
    }
}

import XCTest
@testable import Chau7
@testable import Chau7Core

/// Phase 0 plumbed `Dialogs` through `SplitPaneController` so the close
/// path is unit-driveable end-to-end. These tests cover the three branches
/// of the close dialog without spinning AppKit modal loops — the FakeDialogs
/// returns scripted decisions and the controller must follow them.
@MainActor
final class CloseDialogWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OverlayTabsModel.clearPersistedWindowState()
    }

    override func tearDown() {
        OverlayTabsModel.clearPersistedWindowState()
        super.tearDown()
    }

    func testCancelDecisionAbortsClose() {
        let appModel = AppModel()
        let dialogs = FakeDialogs()
        let controller = SplitPaneController(appModel: appModel, dialogs: dialogs)

        controller.splitWithTextEditor(direction: .horizontal)
        guard let editor = controller.root.findFirstEditor() else {
            XCTFail("Expected editor")
            return
        }
        editor.updateContent("dirty edits\n")
        XCTAssertTrue(editor.isDirty)

        guard let editorPaneID = controller.root.firstPaneID(ofType: .textEditor) else {
            XCTFail("Expected editor pane id")
            return
        }

        dialogs.nextCloseDecision = .cancel
        controller.closePane(id: editorPaneID)

        XCTAssertEqual(dialogs.confirmCloseCallCount, 1)
        XCTAssertNotNil(controller.root.findFirstEditor(), "Cancel must leave the editor in the tree")
        XCTAssertTrue(editor.isDirty, "Cancel must preserve the dirty edits")
    }

    func testDontSaveDecisionDiscardsAndCloses() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_close_dontsave_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "persisted\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let appModel = AppModel()
        let dialogs = FakeDialogs()
        let controller = SplitPaneController(appModel: appModel, dialogs: dialogs)

        controller.splitWithTextEditor(direction: .horizontal, filePath: tmpPath)
        guard let editor = controller.root.findFirstEditor() else {
            XCTFail("Expected editor")
            return
        }
        waitUntilLoaded(editor, expecting: "persisted\n")
        editor.updateContent("about to discard\n")
        XCTAssertTrue(editor.isDirty)

        guard let editorPaneID = controller.root.firstPaneID(ofType: .textEditor) else {
            XCTFail("Expected editor pane id")
            return
        }

        dialogs.nextCloseDecision = .dontSave
        controller.closePane(id: editorPaneID)

        XCTAssertEqual(dialogs.confirmCloseCallCount, 1)
        XCTAssertNil(controller.root.findFirstEditor(), "Don't Save must close the pane")
        // The on-disk file must still match the persisted version, NOT the
        // discarded dirty edits — that's the whole point of "Don't Save".
        XCTAssertEqual(
            try String(contentsOfFile: tmpPath, encoding: .utf8),
            "persisted\n"
        )
    }

    func testSaveDecisionPersistsAndCloses() throws {
        let tmpPath = NSTemporaryDirectory() + "chau7_close_save_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "persisted\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let appModel = AppModel()
        let dialogs = FakeDialogs()
        let controller = SplitPaneController(appModel: appModel, dialogs: dialogs)

        controller.splitWithTextEditor(direction: .horizontal, filePath: tmpPath)
        guard let editor = controller.root.findFirstEditor() else {
            XCTFail("Expected editor")
            return
        }
        waitUntilLoaded(editor, expecting: "persisted\n")
        editor.updateContent("saved content\n")

        guard let editorPaneID = controller.root.firstPaneID(ofType: .textEditor) else {
            XCTFail("Expected editor pane id")
            return
        }

        dialogs.nextCloseDecision = .save
        controller.closePane(id: editorPaneID)

        XCTAssertEqual(dialogs.confirmCloseCallCount, 1)
        XCTAssertNil(controller.root.findFirstEditor())
        XCTAssertEqual(
            try String(contentsOfFile: tmpPath, encoding: .utf8),
            "saved content\n"
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
        XCTFail("Editor did not load \"\(content)\" in time (got: \(editor.content))")
    }
}

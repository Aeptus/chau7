import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

// MARK: - SplitNode Tests

final class SplitNodeTests: XCTestCase {

    // We create nodes directly using the SplitNode enum without needing AppModel.

    // MARK: - Helpers

    private func makeTerminalNode(id: UUID = UUID(), appModel: AppModel) -> SplitNode {
        let session = TerminalSessionModel(appModel: appModel)
        return .terminal(id: id, session: session)
    }

    private func makeEditorNode(id: UUID = UUID()) -> SplitNode {
        let editor = TextEditorModel()
        return .textEditor(id: id, editor: editor)
    }

    // MARK: - Terminal Node

    func testTerminalNodeID() {
        let id = UUID()
        let appModel = AppModel()
        let node = makeTerminalNode(id: id, appModel: appModel)
        XCTAssertEqual(node.id, id)
    }

    func testTerminalNodeAllPaneIDs() {
        let id = UUID()
        let appModel = AppModel()
        let node = makeTerminalNode(id: id, appModel: appModel)
        XCTAssertEqual(node.allPaneIDs, [id])
    }

    func testTerminalNodeAllTerminalIDs() {
        let id = UUID()
        let appModel = AppModel()
        let node = makeTerminalNode(id: id, appModel: appModel)
        XCTAssertEqual(node.allTerminalIDs, [id])
    }

    func testTerminalNodeHasNoTextEditor() {
        let appModel = AppModel()
        let node = makeTerminalNode(appModel: appModel)
        XCTAssertFalse(node.hasTextEditor)
    }

    func testTerminalNodeAllSessions() {
        let appModel = AppModel()
        let node = makeTerminalNode(appModel: appModel)
        XCTAssertEqual(node.allSessions.count, 1)
    }

    // MARK: - TextEditor Node

    func testEditorNodeID() {
        let id = UUID()
        let node = makeEditorNode(id: id)
        XCTAssertEqual(node.id, id)
    }

    func testEditorNodeAllPaneIDs() {
        let id = UUID()
        let node = makeEditorNode(id: id)
        XCTAssertEqual(node.allPaneIDs, [id])
    }

    func testEditorNodeAllTerminalIDsIsEmpty() {
        let node = makeEditorNode()
        XCTAssertTrue(node.allTerminalIDs.isEmpty)
    }

    func testEditorNodeHasTextEditor() {
        let node = makeEditorNode()
        XCTAssertTrue(node.hasTextEditor)
    }

    func testEditorNodeAllSessionsIsEmpty() {
        let node = makeEditorNode()
        XCTAssertTrue(node.allSessions.isEmpty)
    }

    // MARK: - Split Node Construction

    func testSplitNodeID() {
        let splitID = UUID()
        let appModel = AppModel()
        let first = makeTerminalNode(appModel: appModel)
        let second = makeEditorNode()
        let node = SplitNode.split(id: splitID, direction: .horizontal, first: first, second: second, ratio: 0.5)
        XCTAssertEqual(node.id, splitID)
    }

    func testSplitNodeAllPaneIDs() {
        let termID = UUID()
        let editorID = UUID()
        let appModel = AppModel()
        let first = makeTerminalNode(id: termID, appModel: appModel)
        let second = makeEditorNode(id: editorID)
        let node = SplitNode.split(id: UUID(), direction: .horizontal, first: first, second: second, ratio: 0.5)

        let paneIDs = node.allPaneIDs
        XCTAssertEqual(paneIDs.count, 2)
        XCTAssertTrue(paneIDs.contains(termID))
        XCTAssertTrue(paneIDs.contains(editorID))
    }

    func testSplitNodeAllTerminalIDs() {
        let termID = UUID()
        let editorID = UUID()
        let appModel = AppModel()
        let first = makeTerminalNode(id: termID, appModel: appModel)
        let second = makeEditorNode(id: editorID)
        let node = SplitNode.split(id: UUID(), direction: .horizontal, first: first, second: second, ratio: 0.5)

        XCTAssertEqual(node.allTerminalIDs, [termID])
    }

    func testSplitNodeHasTextEditor() {
        let appModel = AppModel()
        let first = makeTerminalNode(appModel: appModel)
        let second = makeEditorNode()
        let node = SplitNode.split(id: UUID(), direction: .horizontal, first: first, second: second, ratio: 0.5)

        XCTAssertTrue(node.hasTextEditor)
    }

    func testSplitNodeWithTwoTerminalsHasNoTextEditor() {
        let appModel = AppModel()
        let first = makeTerminalNode(appModel: appModel)
        let second = makeTerminalNode(appModel: appModel)
        let node = SplitNode.split(id: UUID(), direction: .vertical, first: first, second: second, ratio: 0.5)

        XCTAssertFalse(node.hasTextEditor)
    }

    // MARK: - Deep Tree

    func testDeepTreeAllPaneIDs() {
        let appModel = AppModel()
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let t1 = makeTerminalNode(id: id1, appModel: appModel)
        let t2 = makeTerminalNode(id: id2, appModel: appModel)
        let e1 = makeEditorNode(id: id3)

        // tree: split(split(t1, t2), e1)
        let inner = SplitNode.split(id: UUID(), direction: .horizontal, first: t1, second: t2, ratio: 0.5)
        let root = SplitNode.split(id: UUID(), direction: .vertical, first: inner, second: e1, ratio: 0.6)

        let allIDs = root.allPaneIDs
        XCTAssertEqual(allIDs.count, 3)
        XCTAssertTrue(allIDs.contains(id1))
        XCTAssertTrue(allIDs.contains(id2))
        XCTAssertTrue(allIDs.contains(id3))
    }

    func testDeepTreeTerminalIDs() {
        let appModel = AppModel()
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let t1 = makeTerminalNode(id: id1, appModel: appModel)
        let t2 = makeTerminalNode(id: id2, appModel: appModel)
        let e1 = makeEditorNode(id: id3)

        let inner = SplitNode.split(id: UUID(), direction: .horizontal, first: t1, second: t2, ratio: 0.5)
        let root = SplitNode.split(id: UUID(), direction: .vertical, first: inner, second: e1, ratio: 0.6)

        let termIDs = root.allTerminalIDs
        XCTAssertEqual(termIDs.count, 2)
        XCTAssertTrue(termIDs.contains(id1))
        XCTAssertTrue(termIDs.contains(id2))
        XCTAssertFalse(termIDs.contains(id3))
    }

    // MARK: - findSession / findEditor

    func testFindSessionByID() {
        let appModel = AppModel()
        let id = UUID()
        let node = makeTerminalNode(id: id, appModel: appModel)
        XCTAssertNotNil(node.findSession(id: id))
    }

    func testFindSessionWrongIDReturnsNil() {
        let appModel = AppModel()
        let node = makeTerminalNode(appModel: appModel)
        XCTAssertNil(node.findSession(id: UUID()))
    }

    func testFindEditorByID() {
        let id = UUID()
        let node = makeEditorNode(id: id)
        XCTAssertNotNil(node.findEditor(id: id))
    }

    func testFindEditorWrongIDReturnsNil() {
        let node = makeEditorNode()
        XCTAssertNil(node.findEditor(id: UUID()))
    }

    func testFindSessionInSplitTree() {
        let appModel = AppModel()
        let termID = UUID()
        let term = makeTerminalNode(id: termID, appModel: appModel)
        let editor = makeEditorNode()
        let root = SplitNode.split(id: UUID(), direction: .horizontal, first: term, second: editor, ratio: 0.5)

        XCTAssertNotNil(root.findSession(id: termID))
        XCTAssertNil(root.findSession(id: UUID()))
    }

    func testFindEditorInSplitTree() {
        let appModel = AppModel()
        let editorID = UUID()
        let term = makeTerminalNode(appModel: appModel)
        let editor = makeEditorNode(id: editorID)
        let root = SplitNode.split(id: UUID(), direction: .horizontal, first: term, second: editor, ratio: 0.5)

        XCTAssertNotNil(root.findEditor(id: editorID))
        XCTAssertNil(root.findEditor(id: UUID()))
    }

    // MARK: - findFirstEditor

    func testFindFirstEditorReturnsNilForTerminalOnly() {
        let appModel = AppModel()
        let node = makeTerminalNode(appModel: appModel)
        XCTAssertNil(node.findFirstEditor())
    }

    func testFindFirstEditorReturnsEditor() {
        let editor = makeEditorNode()
        XCTAssertNotNil(editor.findFirstEditor())
    }

    func testFindFirstEditorInSplitTree() {
        let appModel = AppModel()
        let term = makeTerminalNode(appModel: appModel)
        let editor = makeEditorNode()
        let root = SplitNode.split(id: UUID(), direction: .horizontal, first: term, second: editor, ratio: 0.5)

        XCTAssertNotNil(root.findFirstEditor())
    }

    // MARK: - paneType

    func testPaneTypeForTerminal() {
        let id = UUID()
        let appModel = AppModel()
        let node = makeTerminalNode(id: id, appModel: appModel)
        XCTAssertEqual(node.paneType(for: id), .terminal)
    }

    func testPaneTypeForEditor() {
        let id = UUID()
        let node = makeEditorNode(id: id)
        XCTAssertEqual(node.paneType(for: id), .textEditor)
    }

    func testPaneTypeForUnknownIDReturnsNil() {
        let appModel = AppModel()
        let node = makeTerminalNode(appModel: appModel)
        XCTAssertNil(node.paneType(for: UUID()))
    }

    func testPaneTypeInSplitTree() {
        let appModel = AppModel()
        let termID = UUID()
        let editorID = UUID()
        let term = makeTerminalNode(id: termID, appModel: appModel)
        let editor = makeEditorNode(id: editorID)
        let root = SplitNode.split(id: UUID(), direction: .horizontal, first: term, second: editor, ratio: 0.5)

        XCTAssertEqual(root.paneType(for: termID), .terminal)
        XCTAssertEqual(root.paneType(for: editorID), .textEditor)
        XCTAssertNil(root.paneType(for: UUID()))
    }
}

// MARK: - SplitPaneController Tests

@MainActor
final class SplitPaneControllerTests: XCTestCase {

    private var appModel: AppModel!
    private var controller: SplitPaneController!

    override func setUp() {
        super.setUp()
        appModel = AppModel()
        // Enable split panes for tests
        FeatureSettings.shared.isSplitPanesEnabled = true
        controller = SplitPaneController(appModel: appModel)
    }

    override func tearDown() {
        controller = nil
        appModel = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStateHasSingleTerminal() {
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)
        XCTAssertEqual(controller.root.allTerminalIDs.count, 1)
    }

    func testInitialFocusMatchesRootTerminal() {
        let paneIDs = controller.root.allPaneIDs
        XCTAssertEqual(paneIDs.count, 1)
        XCTAssertEqual(controller.focusedPaneID, paneIDs[0])
    }

    func testInitialStateHasNoTextEditor() {
        XCTAssertFalse(controller.hasTextEditor)
    }

    func testInitialFocusedSession() {
        XCTAssertNotNil(controller.focusedSession)
    }

    func testInitialFocusedEditor() {
        XCTAssertNil(controller.focusedEditor)
    }

    // MARK: - Split with Terminal (Horizontal)

    func testSplitWithTerminalHorizontal() {
        let originalID = controller.focusedPaneID

        controller.splitWithTerminal(direction: .horizontal)

        // Should now have 2 panes
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
        XCTAssertEqual(controller.root.allTerminalIDs.count, 2)

        // Focus should move to the new pane
        XCTAssertNotEqual(controller.focusedPaneID, originalID)
    }

    // MARK: - Split with Terminal (Vertical)

    func testSplitWithTerminalVertical() {
        controller.splitWithTerminal(direction: .vertical)

        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
        XCTAssertEqual(controller.root.allTerminalIDs.count, 2)
    }

    // MARK: - Split with Text Editor

    func testSplitWithTextEditor() {
        controller.splitWithTextEditor(direction: .horizontal)

        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
        XCTAssertTrue(controller.hasTextEditor)
    }

    func testSplitWithTextEditorFocusesEditor() {
        controller.splitWithTextEditor(direction: .horizontal)

        // Focus should be on the editor pane
        XCTAssertNotNil(controller.focusedEditor)
    }

    // MARK: - Multiple Splits

    func testMultipleSplits() {
        controller.splitWithTerminal(direction: .horizontal)
        controller.splitWithTerminal(direction: .vertical)

        XCTAssertEqual(controller.root.allPaneIDs.count, 3)
        XCTAssertEqual(controller.root.allTerminalIDs.count, 3)
    }

    func testMixedSplits() {
        controller.splitWithTerminal(direction: .horizontal)
        controller.splitWithTextEditor(direction: .vertical)

        XCTAssertEqual(controller.root.allPaneIDs.count, 3)
        XCTAssertEqual(controller.root.allTerminalIDs.count, 2)
        XCTAssertTrue(controller.hasTextEditor)
    }

    // MARK: - Split Disabled

    func testSplitWithTerminalDisabledDoesNothing() {
        FeatureSettings.shared.isSplitPanesEnabled = false

        controller.splitWithTerminal(direction: .horizontal)

        // Should still have only 1 pane
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)

        FeatureSettings.shared.isSplitPanesEnabled = true
    }

    func testSplitWithTextEditorWorksEvenWhenSplitDisabled() {
        // Per the source comment: "always works regardless of isSplitPanesEnabled"
        FeatureSettings.shared.isSplitPanesEnabled = false

        controller.splitWithTextEditor(direction: .horizontal)

        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
        XCTAssertTrue(controller.hasTextEditor)

        FeatureSettings.shared.isSplitPanesEnabled = true
    }

    // MARK: - Close Pane (Unsplit)

    func testCloseOnlyPaneDoesNothing() {
        let initialID = controller.focusedPaneID

        controller.closeFocusedPane()

        // Should still have 1 pane (can't close the only pane)
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)
        XCTAssertEqual(controller.focusedPaneID, initialID)
    }

    func testCloseFocusedPaneAfterSplit() {
        let originalID = controller.focusedPaneID

        controller.splitWithTerminal(direction: .horizontal)
        let newID = controller.focusedPaneID
        XCTAssertNotEqual(originalID, newID)

        controller.closeFocusedPane()

        // Should be back to 1 pane
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)
        // Focus should move to the sibling (the original pane)
        XCTAssertEqual(controller.focusedPaneID, originalID)
    }

    func testCloseSpecificPane() {
        controller.splitWithTerminal(direction: .horizontal)
        let allIDs = controller.root.allPaneIDs
        XCTAssertEqual(allIDs.count, 2)

        // Close the first pane (not focused)
        controller.closePane(id: allIDs[0])

        XCTAssertEqual(controller.root.allPaneIDs.count, 1)
    }

    func testCloseEditorPaneUnsplitsTree() {
        controller.splitWithTextEditor(direction: .horizontal)
        XCTAssertTrue(controller.hasTextEditor)
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)

        // Close the editor pane (currently focused)
        controller.closeFocusedPane()

        XCTAssertEqual(controller.root.allPaneIDs.count, 1)
        XCTAssertFalse(controller.hasTextEditor)
    }

    // MARK: - Tree Invariant: No Empty Splits

    func testNoEmptySplitsAfterClose() {
        // Create 3 panes
        controller.splitWithTerminal(direction: .horizontal)
        controller.splitWithTerminal(direction: .vertical)
        XCTAssertEqual(controller.root.allPaneIDs.count, 3)

        // Close two panes
        controller.closeFocusedPane()
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)

        controller.closeFocusedPane()
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)

        // The tree should be a single leaf, not a degenerate split
        switch controller.root {
        case .terminal:
            break // correct
        case .textEditor:
            break // also acceptable
        case .split:
            XCTFail("Root should not be a split with only 1 pane")
        }
    }

    func testTreeNeverHasEmptySplitAfterMultipleOperations() {
        // Build up and tear down
        controller.splitWithTerminal(direction: .horizontal)
        controller.splitWithTextEditor(direction: .vertical)
        controller.splitWithTerminal(direction: .horizontal)
        XCTAssertEqual(controller.root.allPaneIDs.count, 4)

        // Close all but one
        controller.closeFocusedPane()
        controller.closeFocusedPane()
        controller.closeFocusedPane()
        XCTAssertEqual(controller.root.allPaneIDs.count, 1)

        // Verify no degenerate splits
        assertNoEmptySplits(controller.root)
    }

    private func assertNoEmptySplits(_ node: SplitNode) {
        switch node {
        case .terminal, .textEditor:
            break
        case .split(_, _, let first, let second, _):
            // A split must have children with panes
            XCTAssertFalse(first.allPaneIDs.isEmpty, "Split first child should not be empty")
            XCTAssertFalse(second.allPaneIDs.isEmpty, "Split second child should not be empty")
            assertNoEmptySplits(first)
            assertNoEmptySplits(second)
        }
    }

    // MARK: - Navigation

    func testFocusNextPaneWrapsAround() {
        controller.splitWithTerminal(direction: .horizontal)
        let allIDs = controller.root.allPaneIDs
        XCTAssertEqual(allIDs.count, 2)

        // Focus is on the second pane (newly created)
        XCTAssertEqual(controller.focusedPaneID, allIDs[1])

        controller.focusNextPane()
        XCTAssertEqual(controller.focusedPaneID, allIDs[0], "Should wrap to first pane")

        controller.focusNextPane()
        XCTAssertEqual(controller.focusedPaneID, allIDs[1], "Should wrap back to second pane")
    }

    func testFocusPreviousPaneWrapsAround() {
        controller.splitWithTerminal(direction: .horizontal)
        let allIDs = controller.root.allPaneIDs
        XCTAssertEqual(allIDs.count, 2)

        // Focus is on the second pane
        XCTAssertEqual(controller.focusedPaneID, allIDs[1])

        controller.focusPreviousPane()
        XCTAssertEqual(controller.focusedPaneID, allIDs[0])

        controller.focusPreviousPane()
        XCTAssertEqual(controller.focusedPaneID, allIDs[1], "Should wrap to last pane")
    }

    func testFocusNextWithSinglePaneDoesNothing() {
        let id = controller.focusedPaneID
        controller.focusNextPane()
        XCTAssertEqual(controller.focusedPaneID, id)
    }

    func testFocusPreviousWithSinglePaneDoesNothing() {
        let id = controller.focusedPaneID
        controller.focusPreviousPane()
        XCTAssertEqual(controller.focusedPaneID, id)
    }

    func testNavigationWithThreePanes() {
        controller.splitWithTerminal(direction: .horizontal)
        let id2 = controller.focusedPaneID

        controller.splitWithTerminal(direction: .vertical)
        let id3 = controller.focusedPaneID

        let allIDs = controller.root.allPaneIDs
        XCTAssertEqual(allIDs.count, 3)

        // Current focus is on id3 (the most recently created)
        XCTAssertEqual(controller.focusedPaneID, id3)

        // Navigate forward through all panes
        controller.focusNextPane()
        let afterFirst = controller.focusedPaneID
        controller.focusNextPane()
        let afterSecond = controller.focusedPaneID
        controller.focusNextPane()
        let afterThird = controller.focusedPaneID

        // Should cycle back to the same pane after 3 next calls
        XCTAssertEqual(afterThird, id3, "Should return to start after cycling through all panes")

        // All three should be distinct
        XCTAssertNotEqual(afterFirst, afterSecond)
    }

    // MARK: - Focus Tracking

    func testFocusedSessionAfterSplit() {
        let originalSession = controller.focusedSession
        XCTAssertNotNil(originalSession)

        controller.splitWithTerminal(direction: .horizontal)
        let newSession = controller.focusedSession
        XCTAssertNotNil(newSession)

        // The focused session should change after split
        XCTAssertFalse(originalSession === newSession, "Focus should move to the new terminal")
    }

    func testFocusedEditorAfterEditorSplit() {
        XCTAssertNil(controller.focusedEditor)

        controller.splitWithTextEditor(direction: .horizontal)

        XCTAssertNotNil(controller.focusedEditor)
        XCTAssertNil(controller.focusedSession, "Focused pane is an editor, not a terminal")
    }

    func testPrimarySession() {
        XCTAssertNotNil(controller.primarySession)

        // Primary session should be the first terminal, even after splits
        let primary = controller.primarySession

        controller.splitWithTextEditor(direction: .horizontal)
        XCTAssertTrue(controller.primarySession === primary, "Primary should remain the first terminal")
    }

    // MARK: - Ratio Adjustment

    func testAdjustRatioClamps() {
        controller.splitWithTerminal(direction: .horizontal)

        // Try to set ratio extremely high
        controller.adjustRatio(delta: 10.0)

        // The ratio should be clamped to max 0.9
        if case .split(_, _, _, _, let ratio) = controller.root {
            XCTAssertLessThanOrEqual(ratio, 0.9)
            XCTAssertGreaterThanOrEqual(ratio, 0.1)
        } else {
            XCTFail("Root should be a split node")
        }
    }

    func testAdjustRatioClampsLow() {
        controller.splitWithTerminal(direction: .horizontal)

        // Try to set ratio extremely low
        controller.adjustRatio(delta: -10.0)

        if case .split(_, _, _, _, let ratio) = controller.root {
            XCTAssertGreaterThanOrEqual(ratio, 0.1)
            XCTAssertLessThanOrEqual(ratio, 0.9)
        } else {
            XCTFail("Root should be a split node")
        }
    }

    func testUpdateRatioByID() {
        controller.splitWithTerminal(direction: .horizontal)

        guard case .split(let splitID, _, _, _, _) = controller.root else {
            XCTFail("Root should be a split")
            return
        }

        controller.updateRatio(splitID: splitID, newRatio: 0.7)

        if case .split(_, _, _, _, let ratio) = controller.root {
            XCTAssertEqual(ratio, 0.7, accuracy: 0.001)
        } else {
            XCTFail("Root should still be a split node")
        }
    }

    func testUpdateRatioClampsValues() {
        controller.splitWithTerminal(direction: .horizontal)

        guard case .split(let splitID, _, _, _, _) = controller.root else {
            XCTFail("Root should be a split")
            return
        }

        controller.updateRatio(splitID: splitID, newRatio: 1.5)
        if case .split(_, _, _, _, let ratio) = controller.root {
            XCTAssertLessThanOrEqual(ratio, 0.9)
        }

        controller.updateRatio(splitID: splitID, newRatio: -0.5)
        if case .split(_, _, _, _, let ratio) = controller.root {
            XCTAssertGreaterThanOrEqual(ratio, 0.1)
        }
    }

    // MARK: - openFileInEditor

    func testOpenFileInEditorCreatesEditorWhenNoneExists() {
        XCTAssertFalse(controller.hasTextEditor)

        controller.openFileInEditor(path: "/tmp/test.txt")

        XCTAssertTrue(controller.hasTextEditor)
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
    }

    func testOpenFileInEditorReusesExistingEditor() {
        controller.splitWithTextEditor(direction: .horizontal)
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)

        controller.openFileInEditor(path: "/tmp/another.txt")

        // Should NOT create a new pane
        XCTAssertEqual(controller.root.allPaneIDs.count, 2)
    }

    // MARK: - Init with Existing Session

    func testInitWithExistingSession() {
        let session = TerminalSessionModel(appModel: appModel)
        let ctrl = SplitPaneController(appModel: appModel, session: session)

        XCTAssertEqual(ctrl.root.allPaneIDs.count, 1)
        XCTAssertTrue(ctrl.focusedSession === session)
    }
}

// MARK: - TextEditorModel Tests

final class TextEditorModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let model = TextEditorModel()
        XCTAssertEqual(model.content, "")
        XCTAssertNil(model.filePath)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.lastError)
    }

    func testFileNameUntitled() {
        let model = TextEditorModel()
        XCTAssertEqual(model.fileName, "Untitled")
    }

    func testFileNameFromPath() {
        let model = TextEditorModel()
        model.filePath = "/Users/dev/project/main.swift"
        XCTAssertEqual(model.fileName, "main.swift")
    }

    // MARK: - updateContent

    func testUpdateContentMarksDirty() {
        let model = TextEditorModel()
        XCTAssertFalse(model.isDirty)

        model.updateContent("hello")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.content, "hello")
    }

    func testUpdateContentSameValueDoesNotDirty() {
        let model = TextEditorModel()
        model.content = "hello"
        model.isDirty = false

        model.updateContent("hello")
        XCTAssertFalse(model.isDirty, "Same content should not mark dirty")
    }

    // MARK: - appendText

    func testAppendTextToEmpty() {
        let model = TextEditorModel()
        model.appendText("hello")
        XCTAssertEqual(model.content, "hello")
        XCTAssertTrue(model.isDirty)
    }

    func testAppendTextToExisting() {
        let model = TextEditorModel()
        model.content = "first"
        model.appendText("second")
        XCTAssertEqual(model.content, "first\nsecond")
        XCTAssertTrue(model.isDirty)
    }

    func testAppendTextToContentEndingWithNewline() {
        let model = TextEditorModel()
        model.content = "first\n"
        model.appendText("second")
        XCTAssertEqual(model.content, "first\nsecond")
    }

    func testAppendTextIgnoresWhitespaceOnly() {
        let model = TextEditorModel()
        model.content = "existing"
        model.isDirty = false

        model.appendText("   \n  ")
        XCTAssertEqual(model.content, "existing")
        XCTAssertFalse(model.isDirty, "Whitespace-only append should be ignored")
    }

    // MARK: - saveAs

    func testSaveAsWritesFile() throws {
        let model = TextEditorModel()
        model.content = "test content"

        let tmpPath = NSTemporaryDirectory() + "chau7_test_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let result = model.saveAs(to: tmpPath)
        XCTAssertTrue(result)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.filePath, tmpPath)
        XCTAssertNil(model.lastError)

        let saved = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertEqual(saved, "test content")
    }

    func testSaveAsToInvalidPathFails() {
        let model = TextEditorModel()
        model.content = "test"

        let result = model.saveAs(to: "/nonexistent/directory/file.txt")
        XCTAssertFalse(result)
        XCTAssertNotNil(model.lastError)
    }

    func testSaveWithoutPathDoesNotCrash() {
        let model = TextEditorModel()
        model.content = "test"
        // save() without filePath should just log a warning
        model.save()
        // No crash = success
    }

    // MARK: - Unique IDs

    func testEachModelHasUniqueID() {
        let m1 = TextEditorModel()
        let m2 = TextEditorModel()
        XCTAssertNotEqual(m1.id, m2.id)
    }
}

// MARK: - SplitDirection / PaneType Tests

final class SplitEnumTests: XCTestCase {

    func testSplitDirectionRawValues() {
        XCTAssertEqual(SplitDirection.horizontal.rawValue, "horizontal")
        XCTAssertEqual(SplitDirection.vertical.rawValue, "vertical")
    }

    func testPaneTypeRawValues() {
        XCTAssertEqual(PaneType.terminal.rawValue, "terminal")
        XCTAssertEqual(PaneType.textEditor.rawValue, "textEditor")
    }
}
#endif

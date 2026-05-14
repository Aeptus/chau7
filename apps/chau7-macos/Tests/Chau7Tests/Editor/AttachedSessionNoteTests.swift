import XCTest
@testable import Chau7
@testable import Chau7Core

@MainActor
final class AttachedSessionNoteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OverlayTabsModel.clearPersistedWindowState()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
    }

    override func tearDown() {
        OverlayTabsModel.clearPersistedWindowState()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        super.tearDown()
    }

    func testUntitledEditorSaveUsesRepoScopedSessionNote() throws {
        let appModel = AppModel()
        let controller = SplitPaneController(appModel: appModel)
        let tabID = UUID()
        controller.ownerTabID = tabID

        let repoRoot = makeTemporaryDirectory(named: "attached-note-repo")
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        guard let session = controller.terminalSessions.first?.1 else {
            XCTFail("Expected terminal session")
            return
        }
        session.updateCurrentDirectory(repoRoot.path)
        session.handleShellRepoRootReport(repoRoot.path)

        controller.splitWithTextEditor(direction: .horizontal)
        guard let editor = controller.root.findFirstEditor() else {
            XCTFail("Expected text editor")
            return
        }

        editor.updateContent("# Note\nattached context\n")
        XCTAssertTrue(editor.saveUntitledIfPossible())

        let expectedPath = SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot.path, tabID: tabID)
        XCTAssertEqual(editor.filePath, expectedPath)
        XCTAssertTrue(editor.isAutoSaveEnabled)
        XCTAssertEqual(
            try String(contentsOfFile: expectedPath, encoding: .utf8),
            "# Note\nattached context\n"
        )
    }

    func testSameTabUsesDifferentSessionNotesPerRepo() throws {
        let appModel = AppModel()
        let controller = SplitPaneController(appModel: appModel)
        let tabID = UUID()
        controller.ownerTabID = tabID

        let repoOneRoot = makeTemporaryDirectory(named: "attached-note-repo-one")
        let repoTwoRoot = makeTemporaryDirectory(named: "attached-note-repo-two")
        defer {
            try? FileManager.default.removeItem(at: repoOneRoot)
            try? FileManager.default.removeItem(at: repoTwoRoot)
        }

        guard let session = controller.terminalSessions.first?.1 else {
            XCTFail("Expected terminal session")
            return
        }

        session.updateCurrentDirectory(repoOneRoot.path)
        session.handleShellRepoRootReport(repoOneRoot.path)
        controller.splitWithTextEditor(direction: .horizontal)
        guard let repoOneEditor = controller.root.findFirstEditor() else {
            XCTFail("Expected first text editor")
            return
        }
        repoOneEditor.updateContent("repo one\n")
        XCTAssertTrue(repoOneEditor.saveUntitledIfPossible())
        let repoOnePath = SessionNoteAttachmentLocator.filePath(repoRoot: repoOneRoot.path, tabID: tabID)
        XCTAssertEqual(repoOneEditor.filePath, repoOnePath)

        controller.toggleTextEditor()
        session.updateCurrentDirectory(repoTwoRoot.path)
        session.handleShellRepoRootReport(repoTwoRoot.path)
        controller.toggleTextEditor()
        guard let repoTwoEditor = controller.root.findFirstEditor() else {
            XCTFail("Expected second text editor")
            return
        }
        XCTAssertNil(repoTwoEditor.filePath)
        repoTwoEditor.updateContent("repo two\n")
        XCTAssertTrue(repoTwoEditor.saveUntitledIfPossible())
        let repoTwoPath = SessionNoteAttachmentLocator.filePath(repoRoot: repoTwoRoot.path, tabID: tabID)
        XCTAssertEqual(repoTwoEditor.filePath, repoTwoPath)

        controller.toggleTextEditor()
        session.updateCurrentDirectory(repoOneRoot.path)
        session.handleShellRepoRootReport(repoOneRoot.path)
        controller.toggleTextEditor()
        guard let reopenedRepoOneEditor = controller.root.findFirstEditor() else {
            XCTFail("Expected repo one editor to reopen")
            return
        }

        waitUntil {
            reopenedRepoOneEditor.filePath == repoOnePath && !reopenedRepoOneEditor.isLoading
        }
        XCTAssertEqual(reopenedRepoOneEditor.filePath, repoOnePath)
        XCTAssertEqual(reopenedRepoOneEditor.content, "repo one\n")
        XCTAssertEqual(try String(contentsOfFile: repoTwoPath, encoding: .utf8), "repo two\n")
    }

    func testToggleTextEditorReopensAttachedSessionNote() {
        let appModel = AppModel()
        let controller = SplitPaneController(appModel: appModel)
        let tabID = UUID()
        controller.ownerTabID = tabID

        let repoRoot = makeTemporaryDirectory(named: "attached-note-reopen")
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        guard let session = controller.terminalSessions.first?.1 else {
            XCTFail("Expected terminal session")
            return
        }
        session.updateCurrentDirectory(repoRoot.path)
        session.handleShellRepoRootReport(repoRoot.path)

        controller.splitWithTextEditor(direction: .horizontal)
        guard let editor = controller.root.findFirstEditor() else {
            XCTFail("Expected text editor")
            return
        }
        editor.updateContent("reopen me\n")
        XCTAssertTrue(editor.saveUntitledIfPossible())

        controller.toggleTextEditor()
        XCTAssertNil(controller.root.findFirstEditor())

        controller.toggleTextEditor()
        guard let reopenedEditor = controller.root.findFirstEditor() else {
            XCTFail("Expected reopened text editor")
            return
        }

        let expectedPath = SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot.path, tabID: tabID)
        waitUntil {
            reopenedEditor.filePath == expectedPath && !reopenedEditor.isLoading
        }
        XCTAssertEqual(reopenedEditor.filePath, expectedPath)
        XCTAssertEqual(reopenedEditor.content, "reopen me\n")
    }

    func testRestoreAutomaticallyReopensAttachedSessionNote() throws {
        let tabID = UUID()
        let paneID = UUID()
        let repoRoot = makeTemporaryDirectory(named: "attached-note-restore")
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let notePath = SessionNoteAttachmentLocator.filePath(repoRoot: repoRoot.path, tabID: tabID)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: notePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "restored note\n".write(toFile: notePath, atomically: true, encoding: .utf8)

        let splitLayout = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: repoRoot.path,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            knownRepoRoot: repoRoot.path
        )
        let savedState = SavedTabState(
            tabID: tabID.uuidString,
            selectedTabID: tabID.uuidString,
            customTitle: "Attached Note",
            color: TabColor.blue.rawValue,
            directory: repoRoot.path,
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            splitLayout: splitLayout,
            focusedPaneID: paneID.uuidString,
            paneStates: [paneState]
        )
        let data = try JSONEncoder().encode([savedState])
        UserDefaults.standard.set(data, forKey: SavedTabState.userDefaultsKey)

        let restoredModel = OverlayTabsModel(appModel: AppModel())
        guard let restoredTab = restoredModel.tabs.first else {
            XCTFail("Expected restored tab")
            return
        }
        guard let editor = restoredTab.splitController.root.findFirstEditor() else {
            XCTFail("Expected attached note editor to reopen")
            return
        }

        waitUntil {
            editor.filePath == notePath && !editor.isLoading
        }
        XCTAssertEqual(editor.filePath, notePath)
        XCTAssertEqual(editor.content, "restored note\n")
        XCTAssertEqual(restoredTab.splitController.focusedTerminalSessionID(), paneID)
    }

    private func makeTemporaryDirectory(named prefix: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        if condition() {
            return
        }
        XCTFail("Condition not met before timeout", file: file, line: line)
    }
}

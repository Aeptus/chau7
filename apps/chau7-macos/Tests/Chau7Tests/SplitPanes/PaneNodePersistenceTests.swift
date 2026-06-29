import XCTest
@testable import Chau7

/// Phase 1c pushed the per-kind serialization onto each `PaneNode` so
/// adding a new pane kind is a `savedRepresentation()` override instead of
/// editing a central switch. These tests pin each pane's encoded shape so
/// the on-disk wire format stays unchanged across the refactor.
@MainActor
final class PaneNodePersistenceTests: XCTestCase {

    func testTerminalPaneEncodesKindAndIDOnly() {
        let id = UUID()
        let appModel = AppModel()
        let pane = TerminalPane(id: id, session: TerminalSessionModel(appModel: appModel))
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .terminal)
        XCTAssertEqual(saved.id, id.uuidString)
        XCTAssertNil(saved.textEditorPath)
        XCTAssertNil(saved.previewFilePath)
        XCTAssertNil(saved.diffFilePath)
        XCTAssertNil(saved.repoDirectory)
        XCTAssertNil(saved.dashboardRepoGroupID)
    }

    func testTextEditorPaneEncodesFilePath() throws {
        let id = UUID()
        let tmpPath = NSTemporaryDirectory() + "chau7_pane_persist_\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "seeded\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let editor = TextEditorModel()
        editor.loadFile(at: tmpPath)
        waitUntilLoaded(editor, expecting: "seeded\n")

        let pane = TextEditorPane(id: id, editor: editor)
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .textEditor)
        XCTAssertEqual(saved.id, id.uuidString)
        XCTAssertEqual(saved.textEditorPath, tmpPath)
    }

    func testFilePreviewPaneEncodesPreviewPath() throws {
        let id = UUID()
        let tmpPath = NSTemporaryDirectory() + "chau7_preview_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "preview-source".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let preview = FilePreviewModel()
        preview.loadFile(at: tmpPath)
        waitUntilPreviewLoaded(preview, expecting: tmpPath)

        let pane = FilePreviewPane(id: id, preview: preview)
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .filePreview)
        XCTAssertEqual(saved.previewFilePath, tmpPath)
    }

    func testDiffViewerPaneEncodesFilePathAndDirectoryAndMode() {
        let id = UUID()
        let diff = DiffViewerModel()
        diff.filePath = "/repo/path/file.swift"
        diff.directory = "/repo/path"
        diff.diffMode = .staged

        let pane = DiffViewerPane(id: id, diff: diff)
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .diffViewer)
        XCTAssertEqual(saved.diffFilePath, "/repo/path/file.swift")
        XCTAssertEqual(saved.diffDirectory, "/repo/path")
        XCTAssertEqual(saved.diffMode, DiffMode.staged.rawValue)
    }

    func testRepositoryPaneEncodesDirectory() {
        let id = UUID()
        let repo = RepositoryPaneModel()
        repo.directory = "/repo/root"

        let pane = RepositoryPane(id: id, repo: repo)
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .repositoryPane)
        XCTAssertEqual(saved.repoDirectory, "/repo/root")
    }

    func testDashboardPaneEncodesRepoGroupID() {
        let id = UUID()
        let dashboard = AgentDashboardModel(repoGroupID: "group-42")

        let pane = DashboardPane(id: id, dashboard: dashboard)
        let saved = pane.savedRepresentation()
        XCTAssertEqual(saved.kind, .dashboard)
        XCTAssertEqual(saved.dashboardRepoGroupID, "group-42")
    }

    func testSplitTreeRoundTripPreservesLeafEncoding() throws {
        // End-to-end: each leaf type in a split tree round-trips through
        // SavedSplitNode → fromSavedNode → leaf comparable to the original.
        let appModel = AppModel()
        let tmpPath = NSTemporaryDirectory() + "chau7_roundtrip_\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try "round-trip body\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let terminalPane = TerminalPane(session: TerminalSessionModel(appModel: appModel))
        let editorModel = TextEditorModel()
        editorModel.loadFile(at: tmpPath)
        waitUntilLoaded(editorModel, expecting: "round-trip body\n")
        let editorPane = TextEditorPane(editor: editorModel)

        let tree: SplitNode = .split(
            id: UUID(),
            direction: .horizontal,
            first: .leaf(terminalPane),
            second: .leaf(editorPane),
            ratio: 0.5
        )
        let saved = tree.savedRepresentation
        let restored = SplitNode.fromSavedNode(saved, appModel: appModel, paneStates: [:])

        // Restored shape mirrors the original
        XCTAssertEqual(restored.allTerminalIDs.count, 1)
        let restoredEditors = restored.allEditors
        XCTAssertEqual(restoredEditors.count, 1)
        // fromSavedNode kicks off loadFile asynchronously; wait for it
        // to settle before asserting on the restored editor's filePath.
        if let editor = restoredEditors.first {
            waitUntilLoaded(editor, expecting: "round-trip body\n")
        }
        XCTAssertEqual(restoredEditors.first?.filePath, tmpPath)
    }

    // MARK: - Helpers

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

    private func waitUntilPreviewLoaded(
        _ preview: FilePreviewModel,
        expecting path: String,
        timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !preview.isLoading, preview.filePath == path { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("preview did not load \"\(path)\" in time")
    }
}

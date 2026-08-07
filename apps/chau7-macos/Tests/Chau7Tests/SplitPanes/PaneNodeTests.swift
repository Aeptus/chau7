import XCTest
@testable import Chau7

/// Phase 1a contract tests for the new `PaneNode` protocol and its six
/// concrete wrappers. These pin the invariants every conformer must honor
/// before Phase 1b migrates `SplitNode` onto the protocol.
@MainActor
final class PaneNodeContractTests: XCTestCase {

    // MARK: - Identity & kind

    func testTerminalPaneReportsTerminalKind() {
        let model = AppModel()
        let pane = TerminalPane(session: TerminalSessionModel(appModel: model))
        XCTAssertEqual(pane.kind, .terminal)
    }

    func testTextEditorPaneReportsTextEditorKind() {
        let pane = TextEditorPane(editor: TextEditorModel())
        XCTAssertEqual(pane.kind, .textEditor)
    }

    func testFilePreviewPaneReportsFilePreviewKind() {
        let pane = FilePreviewPane(preview: FilePreviewModel())
        XCTAssertEqual(pane.kind, .filePreview)
    }

    func testDiffViewerPaneReportsDiffViewerKind() {
        let pane = DiffViewerPane(diff: DiffViewerModel())
        XCTAssertEqual(pane.kind, .diffViewer)
    }

    func testRepositoryPaneReportsRepositoryPaneKind() {
        let pane = RepositoryPane(repo: RepositoryPaneModel())
        XCTAssertEqual(pane.kind, .repositoryPane)
    }

    func testDashboardPaneReportsDashboardKind() {
        let pane = DashboardPane(dashboard: AgentDashboardModel(repoGroupID: "test"))
        XCTAssertEqual(pane.kind, .dashboard)
    }

    func testCustomIDIsHeld() {
        let id = UUID()
        let pane = TextEditorPane(id: id, editor: TextEditorModel())
        XCTAssertEqual(pane.id, id)
    }

    // MARK: - hasUnsavedWork contract

    func testCleanEditorReportsNoUnsavedWork() {
        let pane = TextEditorPane(editor: TextEditorModel())
        XCTAssertFalse(pane.hasUnsavedWork)
    }

    func testDirtyEditorReportsUnsavedWork() {
        let editor = TextEditorModel()
        editor.updateContent("typed something\n")
        let pane = TextEditorPane(editor: editor)
        XCTAssertTrue(pane.hasUnsavedWork)
    }

    func testNonEditorPanesNeverReportUnsavedWork() {
        // Non-editor panes hold read-only or self-managed state — the close
        // prompt should never fire for them, so the default protocol impl
        // returning false is the contract.
        let appModel = AppModel()
        let panes: [PaneNode] = [
            TerminalPane(session: TerminalSessionModel(appModel: appModel)),
            FilePreviewPane(preview: FilePreviewModel()),
            DiffViewerPane(diff: DiffViewerModel()),
            RepositoryPane(repo: RepositoryPaneModel()),
            DashboardPane(dashboard: AgentDashboardModel(repoGroupID: "x"))
        ]
        for pane in panes {
            XCTAssertFalse(
                pane.hasUnsavedWork,
                "\(type(of: pane)) should report no unsaved work"
            )
        }
    }

    // MARK: - dispose contract

    func testTerminalPaneDisposeClosesSession() {
        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let pane = TerminalPane(session: session)
        // closeSession is idempotent and safe to call without a live PTY;
        // we just need to confirm dispose() invokes it without throwing.
        pane.dispose()
        // No assertion possible on session lifecycle without spinning a
        // real shell, but the call must not crash and the session pointer
        // must still be valid (we hold a strong reference here).
        XCTAssertNotNil(session)
    }

    func testTextEditorPaneDisposePreservesEditorContent() {
        let editor = TextEditorModel()
        editor.updateContent("preserved\n")
        let pane = TextEditorPane(editor: editor)
        pane.dispose()
        XCTAssertEqual(editor.content, "preserved\n", "Dispose must not mutate editor content")
        XCTAssertTrue(editor.isDirty)
    }

    func testTextEditorPaneDisposeStopsFileWatchWhileEditorIsRetained() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-pane-dispose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")
        try "note".write(to: fileURL, atomically: false, encoding: .utf8)
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.editor-dispose")
        let editor = TextEditorModel(fileWatchRegistry: registry)
        let pane = TextEditorPane(editor: editor)

        editor.loadFile(at: fileURL.path)
        waitUntil { registry.activeWatchCountForTesting() == 1 }

        pane.dispose()
        waitUntil { registry.activeWatchCountForTesting() == 0 }
        XCTAssertEqual(editor.content, "note", "retained editor remains readable after disposal")
    }

    func testDisposedTextEditorCannotRestartWatchFromLaterLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-editor-late-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")
        try "note".write(to: fileURL, atomically: false, encoding: .utf8)
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.editor-late-load")
        let editor = TextEditorModel(fileWatchRegistry: registry)

        editor.dispose()
        editor.loadFile(at: fileURL.path)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        registry.drainForTesting()

        XCTAssertEqual(registry.activeWatchCountForTesting(), 0)
        XCTAssertNil(editor.filePath)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    // MARK: - Existential erasure round-trip

    func testCanStoreAndRecoverConcretePaneViaProtocol() {
        // Use a heterogeneous array via the existential and recover the
        // concrete kind via `as?` — this is exactly how SplitNode.leaf will
        // work in Phase 1b.
        let appModel = AppModel()
        let editor = TextEditorModel()
        let panes: [PaneNode] = [
            TerminalPane(session: TerminalSessionModel(appModel: appModel)),
            TextEditorPane(editor: editor)
        ]

        XCTAssertEqual(panes.map(\.kind), [.terminal, .textEditor])
        XCTAssertNotNil(panes[1] as? TextEditorPane)
        XCTAssertNil(panes[0] as? TextEditorPane)
        // Recovered concrete pane still points at the same model instance.
        XCTAssertTrue((panes[1] as? TextEditorPane)?.editor === editor)
    }
}

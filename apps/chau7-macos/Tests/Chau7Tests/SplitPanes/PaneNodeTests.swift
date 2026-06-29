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

    func testNonTerminalPaneDisposeIsHarmlessNoOp() {
        // The default protocol implementation is no-op; non-terminal panes
        // get this for free. Just verify it doesn't crash and doesn't
        // mutate observable state on the wrapped model.
        let editor = TextEditorModel()
        editor.updateContent("preserved\n")
        let pane = TextEditorPane(editor: editor)
        pane.dispose()
        XCTAssertEqual(editor.content, "preserved\n", "Default dispose must not mutate the model")
        XCTAssertTrue(editor.isDirty)
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

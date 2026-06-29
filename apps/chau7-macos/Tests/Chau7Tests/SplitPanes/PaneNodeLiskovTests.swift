import XCTest
@testable import Chau7

/// Liskov-style tests: every `PaneNode` conformer must satisfy the protocol
/// contract regardless of which concrete type we have on the existential.
/// These tests iterate a fixture of every shipping pane kind and run the
/// same invariants on each — substituting any kind for any other and
/// expecting identical observable behavior at the protocol level.
///
/// Per-conformer specifics (e.g. TextEditorPane's `hasUnsavedWork`
/// mirroring `editor.isDirty`) live in `PaneNodeContractTests`. Per-pane
/// serialization shape lives in `PaneNodePersistenceTests`. This file
/// covers what every conformer must agree on.
@MainActor
final class PaneNodeLiskovTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds one of every shipping `PaneNode` conformer. Tests iterate
    /// this so a new pane kind only needs adding here once and every
    /// invariant in this file applies to it automatically.
    private func allPaneFixtures() -> [any PaneNode] {
        let appModel = AppModel()
        return [
            TerminalPane(session: TerminalSessionModel(appModel: appModel)),
            TextEditorPane(editor: TextEditorModel()),
            FilePreviewPane(preview: FilePreviewModel()),
            DiffViewerPane(diff: DiffViewerModel()),
            RepositoryPane(repo: RepositoryPaneModel()),
            DashboardPane(dashboard: AgentDashboardModel(repoGroupID: "test-group"))
        ]
    }

    // MARK: - Invariants

    func testEveryPaneCarriesItsOwnIDAndKind() {
        // Every pane returns the id it was constructed with, and a `kind`
        // discriminator that matches its concrete type — this is the
        // baseline LSP guarantee callers depend on.
        for pane in allPaneFixtures() {
            XCTAssertNotNil(pane.id)
            switch pane {
            case is TerminalPane:
                XCTAssertEqual(pane.kind, .terminal)
            case is TextEditorPane:
                XCTAssertEqual(pane.kind, .textEditor)
            case is FilePreviewPane:
                XCTAssertEqual(pane.kind, .filePreview)
            case is DiffViewerPane:
                XCTAssertEqual(pane.kind, .diffViewer)
            case is RepositoryPane:
                XCTAssertEqual(pane.kind, .repositoryPane)
            case is DashboardPane:
                XCTAssertEqual(pane.kind, .dashboard)
            default:
                XCTFail("Unknown pane type: \(type(of: pane))")
            }
        }
    }

    func testDisposeIsIdempotentAcrossAllConformers() {
        // The protocol contract is "dispose releases resources"; callers
        // (closeAllSessions, removeNode) may invoke it more than once on a
        // pane that was already disposed during a separate cleanup path.
        // Calling dispose() twice must never crash for any conformer.
        for pane in allPaneFixtures() {
            pane.dispose()
            pane.dispose() // second call must be safe
        }
    }

    func testSavedRepresentationKindAndIDAgreeWithLeafForAllConformers() {
        // savedRepresentation() lives on the protocol; every conformer must
        // emit the SavedSplitNodeKind that mirrors its `kind: PaneType` and
        // the same stable id its leaf reports.
        for pane in allPaneFixtures() {
            let saved = pane.savedRepresentation()
            XCTAssertEqual(
                saved.kind, savedKindMirror(of: pane.kind),
                "\(type(of: pane)) emits mismatched kind"
            )
            XCTAssertEqual(
                saved.id, pane.id.uuidString,
                "\(type(of: pane)) emits mismatched id"
            )
        }
    }

    /// PaneType (live tree discriminator) and SavedSplitNodeKind
    /// (persistence-side tag) carry the same six cases under different
    /// names; this mirrors PaneType → SavedSplitNodeKind for assertions.
    private func savedKindMirror(of kind: PaneType) -> SavedSplitNodeKind {
        switch kind {
        case .terminal: return .terminal
        case .textEditor: return .textEditor
        case .filePreview: return .filePreview
        case .diffViewer: return .diffViewer
        case .repositoryPane: return .repositoryPane
        case .dashboard: return .dashboard
        }
    }

    func testHasUnsavedWorkDefaultsFalseExceptForCleanEditor() {
        // The protocol default is `false`; only TextEditorPane overrides
        // (mirroring editor.isDirty). With every editor freshly constructed
        // and not yet dirtied, every conformer reports false.
        for pane in allPaneFixtures() {
            XCTAssertFalse(
                pane.hasUnsavedWork,
                "\(type(of: pane)) on a clean fixture must report no unsaved work"
            )
        }
    }

    func testHasUnsavedWorkFlipsOnlyForTextEditorWhenDirty() {
        // Dirty the editor's content if it is one; assert exactly the
        // expected pane flips. The protocol gives the rest the default
        // false impl and they must NOT flip.
        for pane in allPaneFixtures() {
            if let editor = pane as? TextEditorPane {
                editor.editor.updateContent("dirty body\n")
                XCTAssertTrue(
                    editor.hasUnsavedWork,
                    "Dirty TextEditorPane must report unsaved work"
                )
            } else {
                // The other conformers should be impervious — they don't
                // track any editor state, so nothing about their world
                // changed when *another* pane was mutated.
                XCTAssertFalse(
                    pane.hasUnsavedWork,
                    "\(type(of: pane)) must not report unsaved work regardless of other panes"
                )
            }
        }
    }

    func testPaneCanBeStoredAsAnyPaneNodeAndRecoveredViaCast() {
        // The Liskov substitutability check: every conformer can sit on the
        // protocol existential and survive a round-trip back to its
        // concrete type via `as?`. SplitNode.leaf(any PaneNode) and the
        // SwiftUI dispatch in `SplitNodeView.leafView(for:)` depend on
        // this — it's the foundation of the visitor-based traversal.
        for pane in allPaneFixtures() {
            let erased: any PaneNode = pane
            switch erased {
            case let recovered as TerminalPane:
                XCTAssertTrue(recovered === (pane as? TerminalPane))
            case let recovered as TextEditorPane:
                XCTAssertTrue(recovered === (pane as? TextEditorPane))
            case let recovered as FilePreviewPane:
                XCTAssertTrue(recovered === (pane as? FilePreviewPane))
            case let recovered as DiffViewerPane:
                XCTAssertTrue(recovered === (pane as? DiffViewerPane))
            case let recovered as RepositoryPane:
                XCTAssertTrue(recovered === (pane as? RepositoryPane))
            case let recovered as DashboardPane:
                XCTAssertTrue(recovered === (pane as? DashboardPane))
            default:
                XCTFail("Erased pane did not recover to a known concrete type")
            }
        }
    }
}

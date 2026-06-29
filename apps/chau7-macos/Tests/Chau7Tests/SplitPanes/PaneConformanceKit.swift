import XCTest
@testable import Chau7

/// Reusable bundle of PaneNode contract assertions. Any future pane kind
/// — including third-party panes added through the registry — can run
/// the full conformance suite with a single
/// `PaneConformanceKit.assertContract(...)` call.
///
/// PaneNodeLiskovTests still exercises the invariants on a small fixture;
/// this kit factors the same checks into reusable assertion functions
/// that the parameterized `PaneConformanceKitTests` driver can run over
/// the full cross-product (pane kind × edit state × post-dispose state).
enum PaneConformanceKit {

    // MARK: - Entry point

    /// Runs every contract invariant against `pane`. The `editorWasDirtied`
    /// argument tells the kit whether the caller dirtied a TextEditorPane's
    /// underlying editor — other pane kinds ignore it.
    static func assertContract(
        _ pane: any PaneNode,
        editorWasDirtied: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertIDAndKind(pane, file: file, line: line)
        assertSavedRepresentationMatches(pane, file: file, line: line)
        assertHasUnsavedWorkAgrees(pane, editorWasDirtied: editorWasDirtied, file: file, line: line)
        assertSurvivesExistentialRoundTrip(pane, file: file, line: line)
        assertDisposeIsIdempotent(pane, file: file, line: line)
    }

    // MARK: - Individual invariants

    static func assertIDAndKind(
        _ pane: any PaneNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(pane.id, "pane.id must be set", file: file, line: line)
        switch pane {
        case is TerminalPane:
            XCTAssertEqual(pane.kind, .terminal, file: file, line: line)
        case is TextEditorPane:
            XCTAssertEqual(pane.kind, .textEditor, file: file, line: line)
        case is FilePreviewPane:
            XCTAssertEqual(pane.kind, .filePreview, file: file, line: line)
        case is DiffViewerPane:
            XCTAssertEqual(pane.kind, .diffViewer, file: file, line: line)
        case is RepositoryPane:
            XCTAssertEqual(pane.kind, .repositoryPane, file: file, line: line)
        case is DashboardPane:
            XCTAssertEqual(pane.kind, .dashboard, file: file, line: line)
        default:
            XCTFail("Unknown pane type: \(type(of: pane))", file: file, line: line)
        }
    }

    static func assertSavedRepresentationMatches(
        _ pane: any PaneNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let saved = pane.savedRepresentation()
        XCTAssertEqual(
            saved.kind, savedKindMirror(of: pane.kind),
            "savedRepresentation emits mismatched kind for \(type(of: pane))",
            file: file, line: line
        )
        XCTAssertEqual(
            saved.id, pane.id.uuidString,
            "savedRepresentation emits mismatched id for \(type(of: pane))",
            file: file, line: line
        )
    }

    static func assertHasUnsavedWorkAgrees(
        _ pane: any PaneNode,
        editorWasDirtied: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let editorPane = pane as? TextEditorPane {
            XCTAssertEqual(
                editorPane.hasUnsavedWork, editorWasDirtied,
                "TextEditorPane.hasUnsavedWork must mirror editor.isDirty (\(editorWasDirtied))",
                file: file, line: line
            )
        } else {
            XCTAssertFalse(
                pane.hasUnsavedWork,
                "\(type(of: pane)) must report no unsaved work regardless of editor state",
                file: file, line: line
            )
        }
    }

    static func assertSurvivesExistentialRoundTrip(
        _ pane: any PaneNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let erased: any PaneNode = pane
        // Recover via the matching `as?` and assert object identity.
        switch erased {
        case let recovered as TerminalPane:
            XCTAssertTrue(recovered === (pane as? TerminalPane), file: file, line: line)
        case let recovered as TextEditorPane:
            XCTAssertTrue(recovered === (pane as? TextEditorPane), file: file, line: line)
        case let recovered as FilePreviewPane:
            XCTAssertTrue(recovered === (pane as? FilePreviewPane), file: file, line: line)
        case let recovered as DiffViewerPane:
            XCTAssertTrue(recovered === (pane as? DiffViewerPane), file: file, line: line)
        case let recovered as RepositoryPane:
            XCTAssertTrue(recovered === (pane as? RepositoryPane), file: file, line: line)
        case let recovered as DashboardPane:
            XCTAssertTrue(recovered === (pane as? DashboardPane), file: file, line: line)
        default:
            XCTFail("Erased pane did not recover to a known concrete type", file: file, line: line)
        }
    }

    static func assertDisposeIsIdempotent(
        _ pane: any PaneNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Calling dispose twice must not crash for any conformer. We can't
        // assert on internal state without inspecting concrete types, but
        // we can prove the second call survives.
        pane.dispose()
        pane.dispose()
        // If we got here, the contract held.
        XCTAssertNotNil(pane, file: file, line: line) // anchor for failure location
    }

    // MARK: - Helpers

    /// PaneType ↔ SavedSplitNodeKind mirror. Used to bridge the live tree
    /// discriminator and the persistence tag for assertions.
    static func savedKindMirror(of kind: PaneType) -> SavedSplitNodeKind {
        switch kind {
        case .terminal: return .terminal
        case .textEditor: return .textEditor
        case .filePreview: return .filePreview
        case .diffViewer: return .diffViewer
        case .repositoryPane: return .repositoryPane
        case .dashboard: return .dashboard
        }
    }
}

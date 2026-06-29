import XCTest
@testable import Chau7

/// Phase 8 registry tests. The integration path is covered through
/// PaneNodePersistenceTests' end-to-end round-trip; these tests pin the
/// registry contract directly so a missing registration or mis-typed
/// kind tag fails here with a focused message before the round-trip
/// surfaces the same symptom.
@MainActor
final class PaneFactoryRegistryTests: XCTestCase {

    private func makeContext() -> PaneFactoryContext {
        PaneFactoryContext(appModel: AppModel(), paneStates: [:])
    }

    func testRegistryHasAFactoryForEveryPaneType() {
        // Every value of PaneType must have a registered factory.
        // Adding a new pane kind without registering would fail this
        // before any decode path silently substituted a fallback terminal.
        let allCases: [PaneType] = [
            .terminal, .textEditor, .filePreview,
            .diffViewer, .repositoryPane, .dashboard
        ]
        for kind in allCases {
            XCTAssertNotNil(
                PaneFactoryRegistry.factories[kind],
                "PaneFactoryRegistry must have a factory for .\(kind)"
            )
        }
    }

    func testEachFactoryProducesPaneOfMatchingKind() {
        // Every factory must produce a PaneNode whose `kind` matches the
        // key it is registered under — LSP for the registry surface.
        let context = makeContext()
        for (kind, factory) in PaneFactoryRegistry.factories {
            let savedNode = SavedSplitNode(
                kind: savedKindMirror(of: kind),
                id: UUID().uuidString,
                direction: nil, ratio: nil, first: nil, second: nil,
                textEditorPath: nil
            )
            let pane = factory(savedNode, context)
            XCTAssertEqual(
                pane.kind, kind,
                "Factory for \(kind) produced pane with kind \(pane.kind)"
            )
        }
    }

    func testSavedSplitNodeKindMapsToPaneTypeForLeafsAndNilForSplit() {
        XCTAssertEqual(SavedSplitNodeKind.terminal.paneType, .terminal)
        XCTAssertEqual(SavedSplitNodeKind.textEditor.paneType, .textEditor)
        XCTAssertEqual(SavedSplitNodeKind.filePreview.paneType, .filePreview)
        XCTAssertEqual(SavedSplitNodeKind.diffViewer.paneType, .diffViewer)
        XCTAssertEqual(SavedSplitNodeKind.repositoryPane.paneType, .repositoryPane)
        XCTAssertEqual(SavedSplitNodeKind.dashboard.paneType, .dashboard)
        XCTAssertNil(SavedSplitNodeKind.split.paneType, ".split is not a leaf")
    }

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
}

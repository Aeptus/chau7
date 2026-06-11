import XCTest
@testable import Chau7

/// Parameterized driver for `PaneConformanceKit`. Iterates a cross-product
/// fixture (every pane kind × every reachable edit state) and runs the
/// full contract suite on each combination. Replaces the single-fixture
/// `PaneNodeLiskovTests` loop with a more exhaustive battery while
/// staying entirely within XCTest (Swift Testing is not adopted in this
/// target).
///
/// Adding a new pane kind only requires extending `PaneFixture.allCases`
/// — the kit assertions auto-apply.
@MainActor
final class PaneConformanceKitTests: XCTestCase {

    /// One row of the cross-product. Each row knows how to build its pane,
    /// optionally dirtying an underlying editor, and how to label itself
    /// in failure messages.
    private struct PaneFixture {
        let label: String
        let editorDirty: Bool
        let makePane: () -> any PaneNode

        static func allCases(appModel: AppModel) -> [PaneFixture] {
            // Editor-clean fixture vs. editor-dirty fixture must produce a
            // PaneNode whose hasUnsavedWork honors the edit state.
            let editorClean = PaneFixture(
                label: "TextEditorPane(clean)",
                editorDirty: false,
                makePane: { TextEditorPane(editor: TextEditorModel()) }
            )
            let editorDirty = PaneFixture(
                label: "TextEditorPane(dirty)",
                editorDirty: true,
                makePane: {
                    let editor = TextEditorModel()
                    editor.updateContent("dirty body\n")
                    return TextEditorPane(editor: editor)
                }
            )

            return [
                PaneFixture(
                    label: "TerminalPane",
                    editorDirty: false,
                    makePane: { TerminalPane(session: TerminalSessionModel(appModel: appModel)) }
                ),
                editorClean,
                editorDirty,
                PaneFixture(
                    label: "FilePreviewPane",
                    editorDirty: false,
                    makePane: { FilePreviewPane(preview: FilePreviewModel()) }
                ),
                PaneFixture(
                    label: "DiffViewerPane",
                    editorDirty: false,
                    makePane: { DiffViewerPane(diff: DiffViewerModel()) }
                ),
                PaneFixture(
                    label: "RepositoryPane",
                    editorDirty: false,
                    makePane: { RepositoryPane(repo: RepositoryPaneModel()) }
                ),
                PaneFixture(
                    label: "DashboardPane",
                    editorDirty: false,
                    makePane: { DashboardPane(dashboard: AgentDashboardModel(repoGroupID: "kit")) }
                )
            ]
        }
    }

    func testEveryFixtureSatisfiesTheFullContract() {
        let appModel = AppModel()
        for fixture in PaneFixture.allCases(appModel: appModel) {
            XCTContext.runActivity(named: "Contract: \(fixture.label)") { _ in
                let pane = fixture.makePane()
                PaneConformanceKit.assertContract(
                    pane,
                    editorWasDirtied: fixture.editorDirty
                )
            }
        }
    }

    func testContractHoldsAfterPersistenceRoundTrip() {
        // For each pane fixture, save → reconstruct via the registry → run
        // the contract on the reconstructed pane. The reconstructed pane
        // is always editor-clean (the load-from-disk path doesn't carry
        // dirty state), so the dirty flag becomes false in the asserted
        // contract regardless of the source fixture.
        let appModel = AppModel()
        let context = PaneFactoryContext(appModel: appModel, paneStates: [:])
        for fixture in PaneFixture.allCases(appModel: appModel) {
            XCTContext.runActivity(named: "Round-trip: \(fixture.label)") { _ in
                let source = fixture.makePane()
                let saved = source.savedRepresentation()
                guard let paneType = saved.kind.paneType,
                      let factory = PaneFactoryRegistry.factories[paneType] else {
                    XCTFail("No registry entry for \(saved.kind) (label=\(fixture.label))")
                    return
                }
                let reconstructed = factory(saved, context)
                PaneConformanceKit.assertContract(
                    reconstructed,
                    editorWasDirtied: false
                )
                // Kind must survive the round trip too.
                XCTAssertEqual(reconstructed.kind, source.kind)
            }
        }
    }
}

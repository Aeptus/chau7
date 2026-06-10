import XCTest
@testable import Chau7

/// Phase 1b collapsed the ~17 hand-rolled 7-case switches on `SplitNode`
/// into three visitor primitives: `collectLeaves`, `findLeaf`, and
/// `walkLeaves`. These tests pin the visitor contracts (tree order,
/// left-then-right traversal, no leaves visited inside a `.split` that
/// recurses correctly) directly, so the dozens of `allX`/`findFirstX`/
/// `findX(id:)` callers that ride on top stay correct as the pane set
/// evolves.
@MainActor
final class SplitNodeVisitorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAppModel() -> AppModel { AppModel() }

    private func makeTerminalLeaf(_ appModel: AppModel) -> (SplitNode, UUID) {
        let id = UUID()
        let pane = TerminalPane(id: id, session: TerminalSessionModel(appModel: appModel))
        return (.leaf(pane), id)
    }

    private func makeEditorLeaf(_ content: String = "") -> (SplitNode, UUID, TextEditorModel) {
        let id = UUID()
        let editor = TextEditorModel()
        if !content.isEmpty { editor.updateContent(content) }
        return (.leaf(TextEditorPane(id: id, editor: editor)), id, editor)
    }

    private func makeSplit(_ first: SplitNode, _ second: SplitNode) -> SplitNode {
        .split(id: UUID(), direction: .horizontal, first: first, second: second, ratio: 0.5)
    }

    // MARK: - collectLeaves

    func testCollectLeavesVisitsInLeftThenRightOrder() {
        let appModel = makeAppModel()
        let (t1, t1ID) = makeTerminalLeaf(appModel)
        let (e1, e1ID, _) = makeEditorLeaf()
        let (t2, t2ID) = makeTerminalLeaf(appModel)
        let root = makeSplit(makeSplit(t1, e1), t2)

        XCTAssertEqual(root.allPaneIDs, [t1ID, e1ID, t2ID])
    }

    func testCollectLeavesYieldsEmptyForExtractMissingType() {
        let appModel = makeAppModel()
        let (t1, _) = makeTerminalLeaf(appModel)
        let root = t1
        // Asking for editors on a terminal-only tree yields []
        XCTAssertTrue(root.allEditors.isEmpty)
    }

    func testCollectLeavesFiltersByConcreteType() {
        let appModel = makeAppModel()
        let (t1, _) = makeTerminalLeaf(appModel)
        let (e1, _, editor) = makeEditorLeaf("hello")
        let root = makeSplit(t1, e1)
        XCTAssertEqual(root.allEditors.count, 1)
        XCTAssertTrue(root.allEditors.first === editor)
    }

    // MARK: - findLeaf

    func testFindLeafReturnsNilWhenNoMatch() {
        let appModel = makeAppModel()
        let (t1, _) = makeTerminalLeaf(appModel)
        XCTAssertNil(t1.findEditor(id: UUID()))
    }

    func testFindLeafReturnsLeftmostMatchInOrder() {
        let appModel = makeAppModel()
        let (e1, _, editor1) = makeEditorLeaf("first")
        let (e2, _, _) = makeEditorLeaf("second")
        let root = makeSplit(e1, e2)
        // findFirstEditor takes the first leaf in tree order regardless
        // of id, so it must return the left subtree's editor.
        XCTAssertTrue(root.findFirstEditor() === editor1)
    }

    func testFindLeafByIDFindsExactPane() {
        let (e1, e1ID, editor) = makeEditorLeaf()
        let (e2, _, _) = makeEditorLeaf()
        let root = makeSplit(e1, e2)
        XCTAssertTrue(root.findEditor(id: e1ID) === editor)
    }

    // MARK: - walkLeaves

    func testWalkLeavesVisitsEveryLeafInOrder() {
        let appModel = makeAppModel()
        let (t1, t1ID) = makeTerminalLeaf(appModel)
        let (e1, e1ID, _) = makeEditorLeaf()
        let (t2, t2ID) = makeTerminalLeaf(appModel)
        let root = makeSplit(t1, makeSplit(e1, t2))

        var visited: [UUID] = []
        root.walkLeaves { visited.append($0.id) }

        XCTAssertEqual(visited, [t1ID, e1ID, t2ID])
    }

    // MARK: - closeAllSessions composes walkLeaves + dispose

    func testCloseAllSessionsCallsDisposeOnEveryLeaf() {
        // We can't assert on session lifecycle without spinning a real
        // PTY, but we can verify the wiring: a hand-rolled fake pane that
        // increments a counter on dispose() proves the visitor reaches
        // every leaf and triggers the protocol contract.
        let counter = DisposeCounter()
        let p1 = CountingPane(id: UUID(), counter: counter)
        let p2 = CountingPane(id: UUID(), counter: counter)
        let p3 = CountingPane(id: UUID(), counter: counter)
        let root: SplitNode = .split(
            id: UUID(),
            direction: .horizontal,
            first: .leaf(p1),
            second: .split(
                id: UUID(),
                direction: .vertical,
                first: .leaf(p2),
                second: .leaf(p3),
                ratio: 0.5
            ),
            ratio: 0.5
        )

        root.closeAllSessions()
        XCTAssertEqual(counter.count, 3)
    }
}

// MARK: - Test helpers

private final class DisposeCounter {
    var count: Int = 0
}

private final class CountingPane: PaneNode {
    let id: UUID
    let counter: DisposeCounter
    var kind: PaneType { .terminal }

    init(id: UUID, counter: DisposeCounter) {
        self.id = id
        self.counter = counter
    }

    func dispose() {
        counter.count += 1
    }
}

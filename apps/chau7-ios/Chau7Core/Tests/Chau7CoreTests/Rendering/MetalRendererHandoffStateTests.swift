import XCTest
@testable import Chau7Core

final class MetalRendererHandoffStateTests: XCTestCase {
    func testOnlyCurrentGenerationCanCommitFirstFrame() {
        var state = MetalRendererHandoffState()
        let first = state.begin()
        let second = state.begin()

        XCTAssertFalse(state.commitFirstFrame(generation: first))
        XCTAssertTrue(state.isAwaitingFirstFrame)
        XCTAssertTrue(state.commitFirstFrame(generation: second))
        XCTAssertFalse(state.isAwaitingFirstFrame)
    }

    func testDuplicateCompletionCannotCommitTwice() {
        var state = MetalRendererHandoffState()
        let generation = state.begin()

        XCTAssertTrue(state.commitFirstFrame(generation: generation))
        XCTAssertFalse(state.commitFirstFrame(generation: generation))
    }
}

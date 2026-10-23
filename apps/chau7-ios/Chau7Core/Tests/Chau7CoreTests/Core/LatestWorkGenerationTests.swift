import XCTest
import Chau7Core

final class LatestWorkGenerationTests: XCTestCase {
    func testNewSelectionRejectsQueuedWorkAndLatePublication() {
        let generation = LatestWorkGeneration()
        let original = generation.advance()
        XCTAssertTrue(generation.isCurrent(original))
        let selected = generation.advance()
        XCTAssertFalse(generation.isCurrent(original))
        XCTAssertTrue(generation.isCurrent(selected))
    }

    func testConcurrentAdvancesProduceOneCurrentGeneration() {
        let generation = LatestWorkGeneration()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in _ = generation.advance() }
        XCTAssertTrue(generation.isCurrent(100))
        XCTAssertFalse(generation.isCurrent(99))
    }
}

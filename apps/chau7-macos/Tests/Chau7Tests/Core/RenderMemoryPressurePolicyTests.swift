import XCTest
import Chau7Core

final class RenderMemoryPressurePolicyTests: XCTestCase {
    func testLigatureEvictionCountIsZeroWithinLimit() {
        XCTAssertEqual(RenderMemoryPressurePolicy.ligatureEvictionCount(currentCount: 64, limit: 64), 0)
        XCTAssertEqual(RenderMemoryPressurePolicy.ligatureEvictionCount(currentCount: 12, limit: 64), 0)
    }

    func testLigatureEvictionCountTrimsInBatches() {
        XCTAssertEqual(RenderMemoryPressurePolicy.ligatureEvictionCount(currentCount: 4_097, limit: 4_096), 256)
        XCTAssertEqual(RenderMemoryPressurePolicy.ligatureEvictionCount(currentCount: 80, limit: 64), 16)
    }

    func testRetainedInlineImageIndicesFiltersFarOffscreenRows() {
        let retained = RenderMemoryPressurePolicy.retainedInlineImageIndices(
            anchorRows: [-600, -199, 0, 50, 401, 900],
            displayOffset: 0,
            visibleRows: 80,
            rowMargin: 200,
            maxRetained: 10
        )

        XCTAssertEqual(retained, [1, 2, 3])
    }

    func testRetainedInlineImageIndicesKeepsNewestRowsWhenOverLimit() {
        let retained = RenderMemoryPressurePolicy.retainedInlineImageIndices(
            anchorRows: Array(0..<10),
            displayOffset: 0,
            visibleRows: 200,
            rowMargin: 0,
            maxRetained: 3
        )

        XCTAssertEqual(retained, [7, 8, 9])
    }
}

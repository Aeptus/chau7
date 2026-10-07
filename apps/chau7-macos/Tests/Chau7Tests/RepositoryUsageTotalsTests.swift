import XCTest
import Chau7Core

final class RepositoryUsageTotalsTests: XCTestCase {
    func testCombinesDistinctSpendAndRemovesMeasuredOverlapOnce() {
        XCTAssertEqual(RepositoryUsageTotals.combinedCost(runCost: 2, proxyCost: 3, attributedProxyCost: 0), 5)
        XCTAssertEqual(RepositoryUsageTotals.combinedCost(runCost: 2, proxyCost: 3, attributedProxyCost: 1), 4)
        XCTAssertEqual(RepositoryUsageTotals.combinedCost(runCost: 2, proxyCost: 0, attributedProxyCost: 1), 2)
        XCTAssertEqual(RepositoryUsageTotals.combinedCost(runCost: 2, proxyCost: 0.5, attributedProxyCost: 1), 2)
    }
}

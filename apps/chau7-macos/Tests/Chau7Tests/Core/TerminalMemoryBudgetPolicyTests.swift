import XCTest
@testable import Chau7Core

final class TerminalMemoryBudgetPolicyTests: XCTestCase {
    func testBudgetBoundaryIsInclusive() {
        XCTAssertFalse(TerminalMemoryBudgetPolicy.exceedsBudget(bytes: 64, budgetBytes: 64))
        XCTAssertTrue(TerminalMemoryBudgetPolicy.exceedsBudget(bytes: 65, budgetBytes: 64))
    }

    func testBudgetOverrideUsesMegabytesAndRejectsNonPositiveValues() {
        XCTAssertEqual(
            TerminalMemoryBudgetPolicy.normalizedBudgetBytes(overrideMB: 32, defaultBytes: 1),
            32 * 1_024 * 1_024
        )
        XCTAssertEqual(
            TerminalMemoryBudgetPolicy.normalizedBudgetBytes(overrideMB: 0, defaultBytes: 123),
            123
        )
    }

    func testRendererEvictionRequiresInvisibleAllocatedSurface() {
        XCTAssertTrue(TerminalMemoryBudgetPolicy.shouldEvictRenderer(isWindowInvisible: true, allocatedBytes: 1))
        XCTAssertFalse(TerminalMemoryBudgetPolicy.shouldEvictRenderer(isWindowInvisible: false, allocatedBytes: 1))
        XCTAssertFalse(TerminalMemoryBudgetPolicy.shouldEvictRenderer(isWindowInvisible: true, allocatedBytes: 0))
    }
}

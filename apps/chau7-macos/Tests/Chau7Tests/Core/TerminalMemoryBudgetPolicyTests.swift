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
            32 * 1024 * 1024
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

    func testGlobalCacheBudgetEvictsColdCachesAcrossManyTabs() {
        let megabyte = 1024 * 1024
        let sizes = Array(repeating: 8 * megabyte, count: 19)
        let evictions = TerminalMemoryBudgetPolicy.evictionIndices(
            cacheBytes: sizes, protectedIndices: [0, 10], budgetBytes: 64 * megabyte
        )
        XCTAssertEqual(evictions.count, 11)
        XCTAssertFalse(evictions.contains(0))
        XCTAssertFalse(evictions.contains(10))
        let retained = sizes.enumerated().filter { !evictions.contains($0.offset) }.reduce(0) { $0 + $1.element }
        XCTAssertEqual(retained, 64 * megabyte)
    }

    func testGlobalCacheBudgetKeepsSelectedPanesHotAndAvoidsUnnecessaryEvictions() {
        XCTAssertEqual(TerminalMemoryBudgetPolicy.evictionIndices(
            cacheBytes: [20, 20, 5], protectedIndices: [0, 1], budgetBytes: 10
        ), [2])
        XCTAssertEqual(TerminalMemoryBudgetPolicy.evictionIndices(
            cacheBytes: [10, 10, 10], protectedIndices: [0], budgetBytes: 30
        ), [])
    }

    func testGlobalCacheBudgetEvictsLargestColdCacheFirst() {
        XCTAssertEqual(TerminalMemoryBudgetPolicy.evictionIndices(
            cacheBytes: [5, 30, 10], protectedIndices: [0], budgetBytes: 15
        ), [1])
    }
}

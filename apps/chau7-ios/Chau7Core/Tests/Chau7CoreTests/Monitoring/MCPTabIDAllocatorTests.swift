import Foundation
import XCTest
import Chau7Core

final class MCPTabIDAllocatorTests: XCTestCase {
    func testAssignsStableIDsForExistingTabs() {
        var allocator = MCPTabIDAllocator()
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(allocator.assignID(for: first), "tab_1")
        XCTAssertEqual(allocator.assignID(for: second), "tab_2")
        XCTAssertEqual(allocator.assignID(for: first), "tab_1")
        XCTAssertEqual(allocator.id(for: second), "tab_2")
    }

    func testReusesLowestAvailableSlotAfterRelease() {
        var allocator = MCPTabIDAllocator()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(allocator.assignID(for: first), "tab_1")
        XCTAssertEqual(allocator.assignID(for: second), "tab_2")
        allocator.release(tabID: first)

        XCTAssertEqual(allocator.assignID(for: third), "tab_1")
        XCTAssertEqual(allocator.id(for: second), "tab_2")
    }

    func testPruneDropsClosedTabsAndKeepsLiveAliases() {
        var allocator = MCPTabIDAllocator()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        _ = allocator.assignID(for: first)
        _ = allocator.assignID(for: second)
        _ = allocator.assignID(for: third)

        allocator.prune(validTabIDs: Set([first, third]))

        XCTAssertEqual(allocator.id(for: first), "tab_1")
        XCTAssertNil(allocator.id(for: second))
        XCTAssertEqual(allocator.id(for: third), "tab_3")
    }

    func testResolvesAliasesBackToNativeTabIDs() {
        var allocator = MCPTabIDAllocator()
        let first = UUID()

        _ = allocator.assignID(for: first)

        XCTAssertEqual(allocator.nativeTabID(for: "tab_1"), first)
        XCTAssertNil(allocator.nativeTabID(for: "tab_0"))
        XCTAssertNil(allocator.nativeTabID(for: "tab_bad"))
        XCTAssertTrue(MCPTabIDAllocator.isControlPlaneID("tab_1"))
        XCTAssertFalse(MCPTabIDAllocator.isControlPlaneID(first.uuidString))
    }
}

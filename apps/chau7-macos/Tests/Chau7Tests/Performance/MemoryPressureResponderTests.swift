import XCTest
@testable import Chau7

final class MemoryPressureResponderTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testFootprintCeilingIsQuarterOfPhysicalWithinClamp() {
        XCTAssertEqual(MemoryPressureResponder.footprintCeilingBytes(physicalBytes: 32 * gib), 8 * gib)
    }

    func testFootprintCeilingFloorsAtFourGigabytes() {
        // 8GB Mac: a quarter would be 2GB — the floor keeps small machines
        // from thrashing scrollback flushes during normal use.
        XCTAssertEqual(MemoryPressureResponder.footprintCeilingBytes(physicalBytes: 8 * gib), 4 * gib)
    }

    func testFootprintCeilingCapsAtTwelveGigabytes() {
        // 128GB Mac: a quarter would be 32GB — exactly the incident-scale
        // footprint the ceiling exists to prevent.
        XCTAssertEqual(MemoryPressureResponder.footprintCeilingBytes(physicalBytes: 128 * gib), 12 * gib)
    }
}

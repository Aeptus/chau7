import XCTest
@testable import Chau7

final class FullDiskAccessGuardTests: XCTestCase {
    func testFirstAlertAlwaysAllowed() {
        XCTAssertTrue(FullDiskAccessGuard.shouldAlert(
            now: Date(), lastAlertAt: nil, minInterval: 300
        ))
    }

    func testSuppressedWithinInterval() {
        let now = Date()
        XCTAssertFalse(FullDiskAccessGuard.shouldAlert(
            now: now, lastAlertAt: now.addingTimeInterval(-10), minInterval: 300
        ))
    }

    func testAllowedAfterInterval() {
        let now = Date()
        XCTAssertTrue(FullDiskAccessGuard.shouldAlert(
            now: now, lastAlertAt: now.addingTimeInterval(-400), minInterval: 300
        ))
    }

    func testBoundaryIsInclusive() {
        let now = Date()
        XCTAssertTrue(FullDiskAccessGuard.shouldAlert(
            now: now, lastAlertAt: now.addingTimeInterval(-300), minInterval: 300
        ))
    }
}

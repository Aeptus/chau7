import XCTest
@testable import Chau7Core

final class LaunchContinuityPolicyTests: XCTestCase {
    func testMissingMarkerIsUnknown() {
        XCTAssertEqual(
            LaunchContinuityPolicy.previousOutcome(isRunningMarker: nil),
            .unknown
        )
    }

    func testClearedMarkerIsClean() {
        XCTAssertEqual(
            LaunchContinuityPolicy.previousOutcome(isRunningMarker: false),
            .clean
        )
    }

    func testUnclearedMarkerIsAbruptWithoutClaimingCrash() {
        XCTAssertEqual(
            LaunchContinuityPolicy.previousOutcome(isRunningMarker: true),
            .abrupt
        )
    }
}

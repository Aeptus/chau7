import XCTest
@testable import Chau7Core

final class FileObservationRetryPolicyTests: XCTestCase {
    func testExponentialBackoffCapsAtMaximumDelay() {
        let policy = FileObservationRetryPolicy(
            initialDelay: 0.25,
            maximumDelay: 2,
            activeRetryDuration: 60
        )

        XCTAssertEqual(policy.delay(forAttempt: 0, elapsed: 0), 0.25)
        XCTAssertEqual(policy.delay(forAttempt: 1, elapsed: 0), 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 2, elapsed: 0), 1)
        XCTAssertEqual(policy.delay(forAttempt: 3, elapsed: 0), 2)
        XCTAssertEqual(policy.delay(forAttempt: 20, elapsed: 0), 2)
    }

    func testActiveRetriesStopAtConfiguredDuration() {
        let policy = FileObservationRetryPolicy(activeRetryDuration: 60)

        XCTAssertNotNil(policy.delay(forAttempt: 20, elapsed: 59.999))
        XCTAssertNil(policy.delay(forAttempt: 0, elapsed: 60))
        XCTAssertNil(policy.delay(forAttempt: 0, elapsed: 600))
    }

    func testZeroDurationDisablesActiveRetriesForDeterministicLifecycleTests() {
        let policy = FileObservationRetryPolicy(activeRetryDuration: 0)

        XCTAssertNil(policy.delay(forAttempt: 0, elapsed: 0))
    }
}

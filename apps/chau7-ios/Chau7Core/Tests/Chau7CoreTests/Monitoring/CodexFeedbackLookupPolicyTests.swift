import Chau7Core
import XCTest

final class CodexFeedbackLookupPolicyTests: XCTestCase {
    func testInitialDiscoveryBacksOff() {
        XCTAssertEqual(CodexFeedbackLookupPolicy.retryDelay(afterAttempt: 0), 0.25)
        XCTAssertGreaterThan(CodexFeedbackLookupPolicy.retryDelay(afterAttempt: 1), 0.25)
        XCTAssertEqual(CodexFeedbackLookupPolicy.retryDelay(afterAttempt: 19), 2)
    }

    func testDiscoveryContinuesAfterFastBudgetWithoutBusyLooping() {
        for attempt in [20, 21, 100, Int.max] {
            XCTAssertEqual(CodexFeedbackLookupPolicy.retryDelay(afterAttempt: attempt), 60)
        }
        XCTAssertEqual(CodexFeedbackLookupPolicy.retryDelay(afterAttempt: -1), 0.25)
    }
}

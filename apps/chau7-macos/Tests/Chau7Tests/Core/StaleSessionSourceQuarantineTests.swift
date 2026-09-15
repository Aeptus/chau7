import XCTest
@testable import Chau7Core

final class StaleSessionSourceQuarantineTests: XCTestCase {
    private let key = StaleSessionSourceKey(
        tabID: UUID(uuidString: "A83BCE3A-599F-4DC7-9994-78D39B196B72")!,
        sessionID: " session-stale ",
        provider: "Claude"
    )

    func testFirstFailureReconcilesThenRepeatsAreSuppressedAndSummarized() {
        var quarantine = StaleSessionSourceQuarantine(reportInterval: 60)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            quarantine.recordOwnershipFailure(for: key, now: start),
            .reconcileAndReport
        )
        XCTAssertEqual(
            quarantine.recordOwnershipFailure(for: key, now: start.addingTimeInterval(1)),
            .suppress
        )
        XCTAssertEqual(
            quarantine.recordOwnershipFailure(for: key, now: start.addingTimeInterval(60)),
            .reportSummary(suppressedCount: 2)
        )
    }

    func testClearAllowsRecoveredSourceToReconcileAgain() {
        var quarantine = StaleSessionSourceQuarantine()
        _ = quarantine.recordOwnershipFailure(for: key)

        XCTAssertTrue(quarantine.contains(key))
        XCTAssertTrue(quarantine.clear(key))
        XCTAssertFalse(quarantine.contains(key))
        XCTAssertEqual(quarantine.recordOwnershipFailure(for: key), .reconcileAndReport)
    }

    func testKeysNormalizeProviderAndSessionWhitespace() {
        XCTAssertEqual(
            key,
            StaleSessionSourceKey(
                tabID: key.tabID,
                sessionID: "session-stale",
                provider: "claude"
            )
        )
    }
}

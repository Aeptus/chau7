import XCTest
@testable import Chau7Core

final class ProviderQuotaEvaluatorTests: XCTestCase {
    func testMetricsMarksUnsustainableWhenRecentBurnExceedsRemainingBudget() {
        let now = Date(timeIntervalSince1970: 1_776_157_200)
        let resetAt = now.addingTimeInterval(120 * 60)
        let snapshots = [
            ProviderQuotaSnapshot(
                provider: "codex",
                capturedAt: now.addingTimeInterval(-600),
                source: "codex_rollout",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "primary", usedPercent: 20, windowMinutes: 300, resetsAt: resetAt)
                ]
            ),
            ProviderQuotaSnapshot(
                provider: "codex",
                capturedAt: now,
                source: "codex_rollout",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "primary", usedPercent: 40, windowMinutes: 300, resetsAt: resetAt)
                ]
            )
        ]

        let metrics = ProviderQuotaEvaluator.metrics(
            for: snapshots[1],
            recentSnapshots: snapshots,
            now: now
        )

        XCTAssertEqual(metrics.count, 1)
        XCTAssertTrue(metrics[0].isUnsustainable)
        XCTAssertEqual(metrics[0].remainingMinutes ?? 0, 120, accuracy: 0.1)
    }

    func testWarningsPreferLowestRemainingThresholdReached() {
        let now = Date(timeIntervalSince1970: 1_776_157_200)
        let resetAt = now.addingTimeInterval(180 * 60)
        let snapshots = [
            ProviderQuotaSnapshot(
                provider: "claude",
                capturedAt: now.addingTimeInterval(-300),
                source: "claude_statusline",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "five_hour", usedPercent: 92, windowMinutes: 300, resetsAt: resetAt)
                ]
            ),
            ProviderQuotaSnapshot(
                provider: "claude",
                capturedAt: now,
                source: "claude_statusline",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "five_hour", usedPercent: 96, windowMinutes: 300, resetsAt: resetAt)
                ]
            )
        ]

        let warnings = ProviderQuotaEvaluator.warnings(
            for: snapshots[1],
            recentSnapshots: snapshots,
            now: now
        )

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.kind, .remaining5)
    }

    func testWarningsSuppressWhenResetIsLessThanTenMinutesAway() {
        let now = Date(timeIntervalSince1970: 1_776_157_200)
        let resetAt = now.addingTimeInterval(8 * 60)
        let snapshots = [
            ProviderQuotaSnapshot(
                provider: "codex",
                capturedAt: now.addingTimeInterval(-300),
                source: "codex_rollout",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "primary", usedPercent: 85, windowMinutes: 300, resetsAt: resetAt)
                ]
            ),
            ProviderQuotaSnapshot(
                provider: "codex",
                capturedAt: now,
                source: "codex_rollout",
                windows: [
                    ProviderQuotaWindowSnapshot(id: "primary", usedPercent: 90, windowMinutes: 300, resetsAt: resetAt)
                ]
            )
        ]

        let warnings = ProviderQuotaEvaluator.warnings(
            for: snapshots[1],
            recentSnapshots: snapshots,
            now: now
        )

        XCTAssertTrue(warnings.isEmpty)
    }
}

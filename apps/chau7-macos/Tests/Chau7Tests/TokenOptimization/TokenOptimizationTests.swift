import XCTest
@testable import Chau7
import Chau7Core

// MARK: - Core Tests (run under SPM — no app target dependency)

/// Tests for the pure-logic parts of the token optimization system:
/// decision matrix, mode/override enums, codable conformance, gain stats,
/// and rewrite map.
final class TokenOptimizationCoreTests: XCTestCase {

    // MARK: - shouldBeActive Decision Matrix

    func testOffModeAlwaysInactive() {
        XCTAssertFalse(
            shouldBeActive(mode: .off, override: .default, isAIActive: false),
            ".off + .default + no AI -> inactive"
        )
        XCTAssertFalse(
            shouldBeActive(mode: .off, override: .default, isAIActive: true),
            ".off + .default + AI -> inactive"
        )
        XCTAssertFalse(
            shouldBeActive(mode: .off, override: .forceOn, isAIActive: false),
            ".off + .forceOn -> inactive (mode .off overrides forceOn)"
        )
        XCTAssertFalse(
            shouldBeActive(mode: .off, override: .forceOff, isAIActive: true),
            ".off + .forceOff + AI -> inactive"
        )
    }

    func testForceOffOverrideAlwaysInactive() {
        for mode in [TokenOptimizationMode.allTabs, .aiOnly, .manual] {
            XCTAssertFalse(
                shouldBeActive(mode: mode, override: .forceOff, isAIActive: false),
                "\(mode) + .forceOff + no AI -> inactive"
            )
            XCTAssertFalse(
                shouldBeActive(mode: mode, override: .forceOff, isAIActive: true),
                "\(mode) + .forceOff + AI -> inactive"
            )
        }
    }

    func testForceOnOverrideAlwaysActive() {
        for mode in [TokenOptimizationMode.allTabs, .aiOnly, .manual] {
            XCTAssertTrue(
                shouldBeActive(mode: mode, override: .forceOn, isAIActive: false),
                "\(mode) + .forceOn + no AI -> active"
            )
            XCTAssertTrue(
                shouldBeActive(mode: mode, override: .forceOn, isAIActive: true),
                "\(mode) + .forceOn + AI -> active"
            )
        }
    }

    func testAllTabsModeDefaultOverrideAlwaysActive() {
        XCTAssertTrue(
            shouldBeActive(mode: .allTabs, override: .default, isAIActive: false),
            ".allTabs + .default + no AI -> active"
        )
        XCTAssertTrue(
            shouldBeActive(mode: .allTabs, override: .default, isAIActive: true),
            ".allTabs + .default + AI -> active"
        )
    }

    func testAIOnlyModeActivatesWithAI() {
        XCTAssertTrue(
            shouldBeActive(mode: .aiOnly, override: .default, isAIActive: true),
            ".aiOnly + .default + AI active -> active"
        )
    }

    func testAIOnlyModeInactiveWithoutAI() {
        XCTAssertFalse(
            shouldBeActive(mode: .aiOnly, override: .default, isAIActive: false),
            ".aiOnly + .default + no AI -> inactive"
        )
    }

    func testManualModeDefaultIsInactive() {
        XCTAssertFalse(
            shouldBeActive(mode: .manual, override: .default, isAIActive: false),
            ".manual + .default + no AI -> inactive"
        )
        XCTAssertFalse(
            shouldBeActive(mode: .manual, override: .default, isAIActive: true),
            ".manual + .default + AI -> inactive (manual requires explicit forceOn)"
        )
    }

    func testExhaustiveDecisionMatrix() {
        struct TestCase {
            let mode: TokenOptimizationMode
            let override: TabTokenOptOverride
            let isAIActive: Bool
            let expected: Bool
        }

        let cases: [TestCase] = [
            TestCase(mode: .off, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .default, isAIActive: true, expected: false),
            TestCase(mode: .off, override: .forceOn, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .forceOn, isAIActive: true, expected: false),
            TestCase(mode: .off, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .forceOff, isAIActive: true, expected: false),
            TestCase(mode: .allTabs, override: .default, isAIActive: false, expected: true),
            TestCase(mode: .allTabs, override: .default, isAIActive: true, expected: true),
            TestCase(mode: .allTabs, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .allTabs, override: .forceOn, isAIActive: true, expected: true),
            TestCase(mode: .allTabs, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .allTabs, override: .forceOff, isAIActive: true, expected: false),
            TestCase(mode: .aiOnly, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .aiOnly, override: .default, isAIActive: true, expected: true),
            TestCase(mode: .aiOnly, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .aiOnly, override: .forceOn, isAIActive: true, expected: true),
            TestCase(mode: .aiOnly, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .aiOnly, override: .forceOff, isAIActive: true, expected: false),
            TestCase(mode: .manual, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .manual, override: .default, isAIActive: true, expected: false),
            TestCase(mode: .manual, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .manual, override: .forceOn, isAIActive: true, expected: true),
            TestCase(mode: .manual, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .manual, override: .forceOff, isAIActive: true, expected: false)
        ]

        for tc in cases {
            let result = shouldBeActive(
                mode: tc.mode,
                override: tc.override,
                isAIActive: tc.isAIActive
            )
            XCTAssertEqual(
                result, tc.expected,
                "shouldBeActive(mode: \(tc.mode), override: \(tc.override), isAIActive: \(tc.isAIActive)) " +
                    "expected \(tc.expected), got \(result)"
            )
        }
    }

    // MARK: - TokenOptimizationMode Properties

    func testTokenOptimizationModeAllCases() {
        let allCases = TokenOptimizationMode.allCases
        XCTAssertEqual(
            allCases.count,
            4,
            "There should be exactly 4 optimization modes"
        )
        XCTAssertTrue(allCases.contains(.off))
        XCTAssertTrue(allCases.contains(.allTabs))
        XCTAssertTrue(allCases.contains(.aiOnly))
        XCTAssertTrue(allCases.contains(.manual))
    }

    func testTokenOptimizationModeCodable() throws {
        for mode in TokenOptimizationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(TokenOptimizationMode.self, from: data)
            XCTAssertEqual(
                decoded,
                mode,
                "Round-trip encoding should preserve mode \(mode)"
            )
        }
    }

    func testStableRuntimeStateConvergesWithMajorityNoOpsRegardlessOfActiveSessions() {
        // Convergence (most recent recalcs are no-ops) is what makes the
        // runtime stable — having an active AI session does not. The previous
        // `activeSessionCount == 0` clause meant the system was effectively
        // never-stable for users with AI tabs open, firing `.lowChangeRate`
        // on correctly-converged flag state.
        XCTAssertTrue(
            isStableCTORuntimeState(recalcCount: 12, unchangedCount: 10, activeSessionCount: 1),
            "Active sessions don't preclude convergence — flag is set and recalcs are no-ops."
        )
        XCTAssertTrue(
            isStableCTORuntimeState(recalcCount: 12, unchangedCount: 10, activeSessionCount: 0)
        )
    }

    func testStableRuntimeStateRequiresEnoughSamples() {
        // Below the 10-recalc sample threshold, the no-op ratio isn't trusted
        // yet — the system is still settling.
        XCTAssertFalse(
            isStableCTORuntimeState(recalcCount: 9, unchangedCount: 9, activeSessionCount: 0)
        )
    }

    func testStableRuntimeStateRequiresMajorityNoOps() {
        // Even with enough samples, fewer than half no-ops means the system
        // is still actively changing flag state.
        XCTAssertFalse(
            isStableCTORuntimeState(recalcCount: 20, unchangedCount: 5, activeSessionCount: 0)
        )
    }

    // MARK: - Deferred-flush Rate Denominator

    func testDeferredFlushRateUsesEligibleDenominator() {
        // 6 deferred-sets, 1 actual flush, 5 sessions cancelled before
        // their first prompt (session close / mode flip). Pre-fix this
        // reported 1/6 = 16.7% and tripped `.lowDeferredFlushRate`;
        // post-fix the cancels are subtracted from the denominator and
        // the rate is 1/(6-5) = 100%.
        let snapshot = makeSnapshot(
            deferredSetCount: 6,
            deferredFlushCount: 1,
            deferredSkipCount: 0,
            deferredCancelCount: 5
        )
        XCTAssertEqual(snapshot.deferredEligibleCount, 1)
        XCTAssertEqual(snapshot.deferredFlushRatePercent, 100, accuracy: 0.01)
        XCTAssertFalse(snapshot.assessment.issues.contains(.lowDeferredFlushRate))
    }

    func testDeferredFlushRateZeroWhenAllCancelled() {
        // All deferred-sets cancelled before flush → eligible denominator
        // is zero → percentage reports 0 (rather than a divide-by-zero
        // or misleading 100%) and the rate is suppressed from health
        // checks because the sample threshold isn't met.
        let snapshot = makeSnapshot(
            deferredSetCount: 4,
            deferredFlushCount: 0,
            deferredSkipCount: 0,
            deferredCancelCount: 4
        )
        XCTAssertEqual(snapshot.deferredEligibleCount, 0)
        XCTAssertEqual(snapshot.deferredFlushRatePercent, 0)
        XCTAssertFalse(snapshot.assessment.issues.contains(.lowDeferredFlushRate))
    }

    func testDeferredFlushRateHealthFiresOnlyAboveEligibleThreshold() {
        // 5 eligible deferred-sets with 1 flush = 20% flush rate; this
        // should still fire `.lowDeferredFlushRate` because the eligible
        // sample size crosses the threshold and the rate is below 80%.
        let snapshot = makeSnapshot(
            deferredSetCount: 6,
            deferredFlushCount: 1,
            deferredSkipCount: 4,
            deferredCancelCount: 1
        )
        XCTAssertEqual(snapshot.deferredEligibleCount, 5)
        XCTAssertEqual(snapshot.deferredFlushRatePercent, 20, accuracy: 0.01)
        XCTAssertTrue(snapshot.assessment.issues.contains(.lowDeferredFlushRate))
    }

    /// Helper — build a snapshot with the minimum fields needed for these
    /// assertions, defaulting everything else to zero/empty so the test
    /// doesn't have to track unrelated metric churn.
    private func makeSnapshot(
        deferredSetCount: Int,
        deferredFlushCount: Int,
        deferredSkipCount: Int,
        deferredCancelCount: Int,
        recalcCount: Int = 0,
        unchangedCount: Int = 0
    ) -> CTORuntimeSnapshot {
        CTORuntimeSnapshot(
            mode: TokenOptimizationMode.allTabs.rawValue,
            recalcCount: recalcCount,
            createdCount: 0,
            removedCount: 0,
            unchangedCount: unchangedCount,
            deferredSetCount: deferredSetCount,
            deferredFlushCount: deferredFlushCount,
            deferredSkipCount: deferredSkipCount,
            deferredCancelCount: deferredCancelCount,
            setupCount: 1,
            teardownCount: 0,
            modeChangeCount: 0,
            lastModeChangeAt: nil,
            lastDecisionAt: nil,
            lastDecision: nil,
            activeSessionCount: 0,
            trackedSessions: 0,
            pendingDeferredSessions: 0,
            reasonBreakdown: [:],
            deferredFlushDelayCount: 0,
            deferredFlushDelayMinMs: nil,
            deferredFlushDelayMaxMs: nil,
            deferredFlushDelayAverageMs: nil,
            deferredFlushDelayLastMs: nil,
            recentDecisions: [],
            firstSeenAt: Date(),
            uptimeSeconds: 120,
            decisionsPerMinute: 0
        )
    }

    // MARK: - Continuous Health Scoring

    /// `lowChangeRatePenalty` should be 0 at the threshold, scale linearly
    /// to the maximum at 0%, and stay 0 above the threshold. Replaces the
    /// old binary cliff that hit -30 at any value below 30%.
    func testLowChangeRatePenaltyAtBoundaries() {
        XCTAssertEqual(CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: 30), 0)
        XCTAssertEqual(CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: 100), 0)
        XCTAssertEqual(
            CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: 0),
            CTOHealthScoring.lowChangeRateMaxPenalty
        )
    }

    func testLowChangeRatePenaltyScalesProportionally() {
        // 15% change rate is halfway between 30 (threshold) and 0 (worst).
        // Penalty should be half the max (15 of 30, rounded).
        let penalty = CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: 15)
        XCTAssertEqual(penalty, 15)

        // 28% is one-fifteenth of the way past the threshold.
        let near = CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: 28)
        XCTAssertEqual(near, 2)
    }

    /// `highDeferredSkipsPenalty` should be 0 at and below the threshold,
    /// scale to max at 100%.
    func testHighDeferredSkipsPenaltyAtBoundaries() {
        XCTAssertEqual(CTOHealthScoring.highDeferredSkipsPenalty(skipRatePercent: 0), 0)
        XCTAssertEqual(CTOHealthScoring.highDeferredSkipsPenalty(skipRatePercent: 35), 0)
        XCTAssertEqual(
            CTOHealthScoring.highDeferredSkipsPenalty(skipRatePercent: 100),
            CTOHealthScoring.highDeferredSkipsMaxPenalty
        )
    }

    /// `lowDeferredFlushRatePenalty` should be 0 at and above the threshold,
    /// max at 0%.
    func testLowDeferredFlushRatePenaltyAtBoundaries() {
        XCTAssertEqual(CTOHealthScoring.lowDeferredFlushRatePenalty(flushRatePercent: 80), 0)
        XCTAssertEqual(CTOHealthScoring.lowDeferredFlushRatePenalty(flushRatePercent: 100), 0)
        XCTAssertEqual(
            CTOHealthScoring.lowDeferredFlushRatePenalty(flushRatePercent: 0),
            CTOHealthScoring.lowDeferredFlushRateMaxPenalty
        )
    }

    /// `staleDecisionsPenalty` should be 0 at and below 5 minutes, max at
    /// and beyond 30 minutes. Mid-window (e.g. 17 minutes) scales linearly.
    func testStaleDecisionsPenaltyAtBoundaries() {
        XCTAssertEqual(CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: 0), 0)
        XCTAssertEqual(CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: 300), 0)
        XCTAssertEqual(
            CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: 1800),
            CTOHealthScoring.staleDecisionsMaxPenalty
        )
        XCTAssertEqual(
            CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: 3600),
            CTOHealthScoring.staleDecisionsMaxPenalty
        )
    }

    func testStaleDecisionsPenaltyMidWindow() {
        // 1050s is halfway between the 300s threshold and 1800s worst case.
        let penalty = CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: 1050)
        XCTAssertEqual(penalty, 8) // 15 * 0.5 = 7.5, rounded to 8
    }

    // MARK: - Diagnostic State Snapshot

    /// `CTOStateSnapshot` round-trips through JSON without losing fields.
    func testStateSnapshotCodableRoundTrip() throws {
        let stats = CTOGainStats(
            commands: 12, inputTokens: 800, outputTokens: 600,
            savedTokens: 240, savingsPct: 28.5, totalTimeMs: 1200, avgTimeMs: 100
        )
        let deferred = CTODeferredSessionInfo(
            sessionID: "session-c",
            reason: "pending_first_prompt",
            since: Date(timeIntervalSince1970: 1_715_000_000)
        )
        let snapshot = CTOStateSnapshot(
            mode: TokenOptimizationMode.allTabs.rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_715_000_000),
            activeSessions: ["session-a", "session-b"],
            trackedSessions: ["session-a", "session-b", "session-c"],
            deferredSessions: [deferred],
            gainStats: stats
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CTOStateSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    func testStateSnapshotOptionalFieldsDefault() {
        let snapshot = CTOStateSnapshot(
            mode: "off",
            updatedAt: Date(),
            activeSessions: [],
            trackedSessions: [],
            deferredSessions: []
        )
        XCTAssertNil(snapshot.gainStats)
        XCTAssertNil(
            snapshot.lastStateChangeAt,
            "lastStateChangeAt should default to nil so heartbeat-first writes are explicit"
        )
        XCTAssertEqual(snapshot.toolSessions, [])
    }

    /// Each deferred entry must carry the reason it was deferred and the
    /// wall-clock instant it entered the deferred set. A round-trip
    /// pins down the field naming on-disk readers will grep for.
    func testDeferredSessionInfoRoundTrip() throws {
        let info = CTODeferredSessionInfo(
            sessionID: "abc",
            reason: "pending_first_prompt",
            since: Date(timeIntervalSince1970: 1_715_000_500)
        )
        let snapshot = CTOStateSnapshot(
            mode: TokenOptimizationMode.allTabs.rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_715_000_600),
            lastStateChangeAt: Date(timeIntervalSince1970: 1_715_000_500),
            activeSessions: [],
            trackedSessions: ["abc"],
            deferredSessions: [info]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CTOStateSnapshot.self, from: data)

        XCTAssertEqual(decoded.deferredSessions.count, 1)
        let entry = try XCTUnwrap(decoded.deferredSessions.first)
        XCTAssertEqual(entry.sessionID, "abc")
        XCTAssertEqual(entry.reason, "pending_first_prompt")
        XCTAssertEqual(entry.since, Date(timeIntervalSince1970: 1_715_000_500))
    }

    /// R5: each tool-session entry must round-trip provider +
    /// toolSessionID alongside the Chau7 session UUID, including the
    /// "provider known but session id not yet observed" case where
    /// `toolSessionID` is nil. Field naming is load-bearing — external
    /// readers grep on these names.
    func testToolSessionInfoRoundTrip() throws {
        let known = CTOToolSessionInfo(
            sessionID: "chau7-1", provider: "claude", toolSessionID: "claude-abc"
        )
        let providerOnly = CTOToolSessionInfo(
            sessionID: "chau7-2", provider: "codex", toolSessionID: nil
        )
        let snapshot = CTOStateSnapshot(
            mode: TokenOptimizationMode.allTabs.rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_715_000_700),
            activeSessions: ["chau7-1", "chau7-2"],
            trackedSessions: ["chau7-1", "chau7-2"],
            deferredSessions: [],
            toolSessions: [known, providerOnly]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CTOStateSnapshot.self, from: data)

        XCTAssertEqual(decoded.toolSessions, [known, providerOnly])
        XCTAssertEqual(decoded.toolSessions[0].provider, "claude")
        XCTAssertEqual(decoded.toolSessions[0].toolSessionID, "claude-abc")
        XCTAssertNil(decoded.toolSessions[1].toolSessionID)
    }

    /// R5 default value sanity: snapshots constructed without specifying
    /// `toolSessions` should round-trip as an empty list, not throw on
    /// missing key. Older code paths that construct snapshots inline
    /// (and don't yet know about tool identity) must keep working.
    func testToolSessionsDefaultsToEmpty() throws {
        let snapshot = CTOStateSnapshot(
            mode: "off",
            updatedAt: Date(timeIntervalSince1970: 1_715_000_800),
            activeSessions: [],
            trackedSessions: [],
            deferredSessions: []
        )
        XCTAssertEqual(snapshot.toolSessions, [])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CTOStateSnapshot.self, from: data)
        XCTAssertEqual(decoded.toolSessions, [])
    }

    /// R2 heartbeat semantics. A snapshot that carries both `updatedAt`
    /// (always set) and `lastStateChangeAt` (only set when the
    /// underlying state actually moved) must round-trip both fields so
    /// external readers can tell heartbeat-only writes from real
    /// changes.
    func testStateSnapshotRoundTripsLastStateChangeAt() throws {
        let updated = Date(timeIntervalSince1970: 1_715_000_300)
        let lastChange = Date(timeIntervalSince1970: 1_715_000_000)
        let snapshot = CTOStateSnapshot(
            mode: TokenOptimizationMode.allTabs.rawValue,
            updatedAt: updated,
            lastStateChangeAt: lastChange,
            activeSessions: ["a"],
            trackedSessions: ["a"],
            deferredSessions: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CTOStateSnapshot.self, from: data)

        XCTAssertEqual(decoded.updatedAt, updated)
        XCTAssertEqual(decoded.lastStateChangeAt, lastChange)
        XCTAssertGreaterThan(
            decoded.updatedAt,
            decoded.lastStateChangeAt!,
            "Heartbeat advances updatedAt past lastStateChangeAt"
        )
    }

    // MARK: - Assessment Transition Pure Logic

    /// First emission (no previous assessment) should report `.initial`
    /// carrying the current state — this is the "anchor" log the
    /// transition emitter logs at INFO so log timelines have a known
    /// starting point.
    func testTransitionInitialOnFirstEmission() {
        let current = makeAssessment(state: .healthy, score: 95, issues: [])
        let transition = CTOAssessmentTransition.between(previous: nil, current: current)
        switch transition {
        case .initial(let state, let score, let issues):
            XCTAssertEqual(state, .healthy)
            XCTAssertEqual(score, 95)
            XCTAssertEqual(issues, [])
        default:
            XCTFail("Expected .initial for first emission, got \(String(describing: transition))")
        }
    }

    /// No transition is emitted when the state hasn't changed, even if
    /// the score moved within the same band. Score-only movements are
    /// observable through the regular summary log.
    func testTransitionSuppressedWhenStateUnchanged() {
        let previous = makeAssessment(state: .warning, score: 70, issues: [.lowChangeRate])
        let current = makeAssessment(state: .warning, score: 65, issues: [.lowChangeRate, .highDeferredSkips])
        XCTAssertNil(CTOAssessmentTransition.between(previous: previous, current: current))
    }

    func testTransitionDegradedCarriesDelta() {
        let previous = makeAssessment(state: .healthy, score: 95, issues: [])
        let current = makeAssessment(state: .warning, score: 75, issues: [.lowChangeRate])
        let transition = CTOAssessmentTransition.between(previous: previous, current: current)
        guard case .degraded(let metadata) = transition else {
            XCTFail("Expected .degraded, got \(String(describing: transition))")
            return
        }
        XCTAssertEqual(metadata["from"], "healthy")
        XCTAssertEqual(metadata["to"], "warning")
        XCTAssertEqual(metadata["scoreFrom"], "95")
        XCTAssertEqual(metadata["scoreTo"], "75")
        XCTAssertEqual(metadata["scoreDelta"], "-20")
        XCTAssertEqual(metadata["addedIssues"], "lowChangeRate")
        XCTAssertEqual(metadata["resolvedIssues"], "")
    }

    func testTransitionRecoveredCarriesResolvedIssues() {
        let previous = makeAssessment(
            state: .critical, score: 40,
            issues: [.lowChangeRate, .lowDeferredFlushRate, .highDeferredSkips]
        )
        let current = makeAssessment(
            state: .warning, score: 70,
            issues: [.lowChangeRate]
        )
        let transition = CTOAssessmentTransition.between(previous: previous, current: current)
        guard case .recovered(let metadata) = transition else {
            XCTFail("Expected .recovered, got \(String(describing: transition))")
            return
        }
        XCTAssertEqual(metadata["scoreDelta"], "30")
        // Resolved issues are sorted; two of three previous issues resolved.
        XCTAssertEqual(metadata["resolvedIssues"], "highDeferredSkips,lowDeferredFlushRate")
        XCTAssertEqual(metadata["addedIssues"], "")
    }

    private func makeAssessment(
        state: CTORuntimeHealthState,
        score: Int,
        issues: [CTORuntimeAssessmentIssue]
    ) -> CTORuntimeAssessment {
        CTORuntimeAssessment(state: state, score: score, issues: issues, summary: state.rawValue)
    }

    // MARK: - TabTokenOptOverride Properties

    func testTabTokenOptOverrideAllCases() {
        let allCases = TabTokenOptOverride.allCases
        XCTAssertEqual(
            allCases.count,
            3,
            "There should be exactly 3 override values"
        )
        XCTAssertTrue(allCases.contains(.default))
        XCTAssertTrue(allCases.contains(.forceOn))
        XCTAssertTrue(allCases.contains(.forceOff))
    }

    func testTabTokenOptOverrideCodable() throws {
        for override in TabTokenOptOverride.allCases {
            let data = try JSONEncoder().encode(override)
            let decoded = try JSONDecoder().decode(TabTokenOptOverride.self, from: data)
            XCTAssertEqual(
                decoded,
                override,
                "Round-trip encoding should preserve override \(override)"
            )
        }
    }

    func testTabTokenOptOverrideRawValues() {
        XCTAssertEqual(TabTokenOptOverride.default.rawValue, "default")
        XCTAssertEqual(TabTokenOptOverride.forceOn.rawValue, "forceOn")
        XCTAssertEqual(TabTokenOptOverride.forceOff.rawValue, "forceOff")
    }

    // MARK: - CTO Rewrite Map

    func testRewriteMapCoversExpectedCommands() {
        let map = ctoRewriteMap
        // CTO shadows read-only inspection commands only. Interpreters,
        // runtimes, package managers, and build tools are intentionally
        // excluded (see `ctoRewriteMap` docs) — do not re-add them here
        // without revisiting that decision.
        let expectedMappings: [String: String] = [
            "cat": "read",
            "ls": "ls",
            "find": "find",
            "tree": "tree",
            "grep": "grep",
            "rg": "rg",
            "diff": "diff",
            "sed": "read"
        ]

        XCTAssertEqual(
            map.count,
            expectedMappings.count,
            "Rewrite map should have exactly \(expectedMappings.count) entries"
        )
        for (cmd, sub) in expectedMappings {
            XCTAssertEqual(
                map[cmd],
                sub,
                "\(cmd) should map to cto \(sub)"
            )
        }
    }

    func testRewriteMapAndExecOnlyAreMutuallyExclusive() {
        let rewriteKeys = Set(ctoRewriteMap.keys)
        let overlap = rewriteKeys.intersection(execOnlyCommands)
        XCTAssertTrue(
            overlap.isEmpty,
            "Rewrite map and exec-only commands should not overlap: \(overlap)"
        )
    }

    func testRewriteMapPlusExecOnlyCoversSupportedCommands() {
        let allCovered = Set(ctoRewriteMap.keys)
            .union(execOnlyCommands)
            .union(executableCommands.keys)
        let supported = Set(supportedCommands)
        XCTAssertEqual(
            allCovered,
            supported,
            "Rewrite map + exec-only + executables should exactly cover supportedCommands"
        )
    }

    func testSupportedCommandsIsDerivedFromMapAndExecOnly() {
        let commands = Set(supportedCommands)
        let expected = Set(ctoRewriteMap.keys)
            .union(execOnlyCommands)
            .union(executableCommands.keys)
        XCTAssertEqual(
            commands,
            expected,
            "supportedCommands should equal ctoRewriteMap keys ∪ execOnlyCommands ∪ executableCommands keys"
        )
    }

    func testExecOnlyCommandsAreSubset() {
        for cmd in execOnlyCommands {
            XCTAssertTrue(
                supportedCommands.contains(cmd),
                "exec-only command '\(cmd)' should also be in supportedCommands"
            )
        }
    }

    func testPipeFilterCommandsAreSubsetOfRewriteMap() {
        let rewriteKeys = Set(ctoRewriteMap.keys)
        for cmd in pipeFilterCommands {
            XCTAssertTrue(
                rewriteKeys.contains(cmd),
                "pipe-filter command '\(cmd)' should be in ctoRewriteMap"
            )
        }
    }

    /// Regression: `head`, `tail`, and `wc` were removed from the wrapper
    /// surface — their wrappers were no-op passthroughs that `exec`'d the real
    /// binary on both the inactive and active paths, adding a `bash` fork per
    /// call for zero token savings. They must not reappear in
    /// `supportedCommands` (which would make `setup()` reinstall the dead
    /// wrappers), and the exec-only set stays empty by design.
    func testExecOnlyWrappersRemovedFromSurface() {
        XCTAssertTrue(
            execOnlyCommands.isEmpty,
            "exec-only wrapper surface should be empty: \(execOnlyCommands)"
        )
        for cmd in ["head", "tail", "wc"] {
            XCTAssertFalse(
                supportedCommands.contains(cmd),
                "\(cmd) must not have a wrapper — no optimizer route, no savings"
            )
            XCTAssertNil(ctoRewriteMap[cmd], "\(cmd) must not be optimizer-routed")
        }
    }

    // MARK: - Executable Command Taxonomy

    /// Tier 1 executables are wrapped and gated to idempotent subcommands.
    func testExecutableCommandsTier1Gating() throws {
        let expectedAllowlists: [String: Set<String>] = [
            "git": ["status", "diff", "log", "show"],
            "cargo": ["build", "test", "check", "clippy", "nextest"],
            "swift": ["build", "test"],
            "go": ["build", "test", "vet"]
        ]
        for (cmd, expected) in expectedAllowlists {
            let policy = try XCTUnwrap(executableCommands[cmd])
            guard case let .subcommandAllowlist(subs) = policy.gate else {
                return XCTFail("\(cmd) should gate by subcommand allowlist")
            }
            XCTAssertEqual(subs, expected, "\(cmd) allowlist")
        }
        // Mutating subcommands must never be in any allowlist.
        for mutation in ["commit", "push", "publish", "install", "reset", "clean"] {
            for (cmd, subs) in expectedAllowlists {
                XCTAssertFalse(subs.contains(mutation), "\(cmd) \(mutation) must not be optimized")
            }
        }
        // curl gates by HTTP method, not subcommand.
        let curl = try XCTUnwrap(executableCommands["curl"])
        XCTAssertEqual(curl.gate, .curlSafeMethodsOnly)
    }

    /// The curl wrapper routes only non-mutating requests to the optimizer.
    func testCurlMethodGateContract() {
        let wrapper = CTOManager.shared.generateExecutableWrapperScript(
            for: "curl",
            policy: CTOExecPolicy(gate: .curlSafeMethodsOnly)
        )
        // Detects mutating flags and skips the optimizer for them.
        XCTAssertTrue(wrapper.contains("-X|--request"), "must detect explicit method")
        XCTAssertTrue(wrapper.contains("-d|--data"), "must detect body data")
        XCTAssertTrue(wrapper.contains("_cto_safe"), "must gate on request safety")
        XCTAssertTrue(wrapper.contains("for _dir in $PATH"), "must resolve curl at runtime")
    }

    /// Executable wrappers and read-only rewrites are disjoint surfaces, and
    /// every executable is in supportedCommands so it gets a wrapper.
    func testExecutableCommandsDisjointAndSupported() {
        let execKeys = Set(executableCommands.keys)
        XCTAssertTrue(
            execKeys.isDisjoint(with: Set(ctoRewriteMap.keys)),
            "executable and read-only surfaces must not overlap"
        )
        XCTAssertTrue(
            execKeys.isDisjoint(with: execOnlyCommands),
            "executable and exec-only surfaces must not overlap"
        )
        for cmd in execKeys {
            XCTAssertTrue(supportedCommands.contains(cmd), "\(cmd) must be installed as a wrapper")
        }
    }

    /// Tier 2 interpreters stay off the wrapper surface (regression guard for
    /// the class of commands that broke before).
    func testDeferredInterpretersNotWrapped() {
        for cmd in ["python", "python3", "node", "npm", "npx", "pip", "pytest"] {
            XCTAssertTrue(deferredExecutableCommands.contains(cmd))
            XCTAssertNil(executableCommands[cmd], "\(cmd) must not be wrapped yet")
            XCTAssertFalse(supportedCommands.contains(cmd), "\(cmd) must not be installed")
        }
        XCTAssertTrue(
            deferredExecutableCommands.isDisjoint(with: Set(executableCommands.keys)),
            "a command cannot be both wrapped and deferred"
        )
    }

    // MARK: - Real Binary Resolution

    /// The interpreter-mismatch bug (Finding 2): resolution must honor PATH
    /// order, so a Homebrew entry ahead of `/usr/bin` wins. Regressing this to
    /// the app's PATH ordering would resolve `/usr/bin/python3` instead.
    func testResolveRealBinaryHonorsPathOrder() {
        let present: Set = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        let resolved = ctoResolveRealBinary(
            command: "python3",
            pathEntries: ["/opt/homebrew/bin", "/usr/bin"],
            wrapperDirectory: "/home/.chau7/cto_bin",
            isExecutable: { present.contains($0) }
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/python3")
    }

    /// The recursion guard: the wrapper directory is skipped so a command never
    /// resolves back to its own wrapper (which would re-invoke chau7-optim).
    func testResolveRealBinarySkipsWrapperDirectory() {
        let wrapperDir = "/home/.chau7/cto_bin"
        let present: Set = ["\(wrapperDir)/grep", "/usr/bin/grep"]
        let resolved = ctoResolveRealBinary(
            command: "grep",
            pathEntries: [wrapperDir, "/usr/bin"],
            wrapperDirectory: wrapperDir,
            isExecutable: { present.contains($0) }
        )
        XCTAssertEqual(resolved, "/usr/bin/grep", "must skip the wrapper dir and resolve the real binary")
    }

    /// The install-guard input (Finding 1): when no entry outside the wrapper
    /// dir holds the command, resolution returns nil — the signal to NOT
    /// install a wrapper, so a bare name is never shadowed into an exit 127.
    func testResolveRealBinaryReturnsNilWhenAbsent() {
        let wrapperDir = "/home/.chau7/cto_bin"
        let present: Set = ["\(wrapperDir)/python"] // only the wrapper itself exists
        let resolved = ctoResolveRealBinary(
            command: "python",
            pathEntries: [wrapperDir, "/usr/bin", "/bin"],
            wrapperDirectory: wrapperDir,
            isExecutable: { present.contains($0) }
        )
        XCTAssertNil(resolved, "no real binary → nil → wrapper must not be installed")
    }

    /// Junction: `CTOManager.resolveRealBinary` reads from its PATH provider and
    /// applies the pure resolution logic. Injected deps keep this off the real
    /// filesystem and `~/.chau7`.
    func testCTOManagerResolveReadsFromProvidedPath() {
        let resolved = CTOManager.shared.resolveRealBinary(
            for: "python3",
            pathProvider: { "/opt/homebrew/bin:/usr/bin" },
            isExecutable: { ["/opt/homebrew/bin/python3", "/usr/bin/python3"].contains($0) }
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/python3")
    }

    /// Junction regression guard (Finding 2): the default PATH source must be
    /// the login-shell launch PATH (`ShellLaunchEnvironment.preferredPATH()`),
    /// NOT the GUI app's `ProcessInfo` PATH. The recording probe captures which
    /// directories are scanned; reverting the source would change them and fail
    /// here. No filesystem access — the probe always returns false.
    func testCTOManagerResolveDefaultsToShellLaunchPath() {
        var scannedDirs: [String] = []
        _ = CTOManager.shared.resolveRealBinary(
            for: "chau7-nonexistent-probe-cmd",
            isExecutable: { candidate in
                scannedDirs.append((candidate as NSString).deletingLastPathComponent)
                return false
            }
        )
        let expected = ShellLaunchEnvironment.preferredPATH()
            .split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && $0 != CTOManager.shared.wrapperBinDir.path }
        XCTAssertEqual(
            scannedDirs, expected,
            "resolveRealBinary must scan the login-shell PATH (preferredPATH), not the app's PATH"
        )
    }

    // MARK: - CTOGainStats Decoding

    func testGainStatsDecodingRoundTrip() throws {
        let stats = CTOGainStats(
            commands: 42,
            inputTokens: 10000,
            outputTokens: 3000,
            savedTokens: 7000,
            savingsPct: 70.0,
            totalTimeMs: 1500,
            avgTimeMs: 36
        )

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(CTOGainStats.self, from: data)
        XCTAssertEqual(
            decoded,
            stats,
            "CTOGainStats should round-trip through JSON encoding"
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["total_commands"], "Encoded key should be 'total_commands'")
        XCTAssertNotNil(json["total_input"], "Encoded key should be 'total_input'")
        XCTAssertNotNil(json["total_output"], "Encoded key should be 'total_output'")
        XCTAssertNotNil(json["total_saved"], "Encoded key should be 'total_saved'")
    }

    func testGainStatsDecodingFromOptimizerJSON() throws {
        let json = """
        {
            "total_commands": 100,
            "total_input": 50000,
            "total_output": 15000,
            "total_saved": 35000,
            "avg_savings_pct": 70.0,
            "total_time_ms": 5000,
            "avg_time_ms": 50
        }
        """.data(using: .utf8)!

        let stats = try JSONDecoder().decode(CTOGainStats.self, from: json)
        XCTAssertEqual(stats.commands, 100)
        XCTAssertEqual(stats.inputTokens, 50000)
        XCTAssertEqual(stats.outputTokens, 15000)
        XCTAssertEqual(stats.savedTokens, 35000)
        XCTAssertEqual(stats.savingsPct, 70.0, accuracy: 0.001)
        XCTAssertEqual(stats.totalTimeMs, 5000)
        XCTAssertEqual(stats.avgTimeMs, 50)
    }
}

// MARK: - Integration Tests (app target only)

/// Tests requiring the app target: PATH injection, optimizer paths, runtime monitor, notifications.
final class TokenOptimizationIntegrationTests: XCTestCase {

    /// The live Chau7 app instance heartbeats the real ~/.chau7/cto_state.json
    /// while the suite runs — point the state file at a private temp URL so
    /// reads/writes/teardown-removes here never race it (or delete it).
    override func setUp() {
        super.setUp()
        CTOStateFile.stateURLOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-tests-cto-state-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let url = CTOStateFile.stateURLOverrideForTesting {
            try? FileManager.default.removeItem(at: url)
        }
        CTOStateFile.stateURLOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - CTOManager PATH Injection

    func testPrependedPATHAddsWrapperDir() {
        let manager = CTOManager.shared
        let originalPATH = "/usr/bin:/usr/local/bin"
        let result = manager.prependedPATH(original: originalPATH)
        let expected = manager.wrapperBinDir.path + ":" + originalPATH
        XCTAssertEqual(
            result,
            expected,
            "prependedPATH should prepend the wrapper bin directory"
        )
    }

    func testPrependedPATHDoesNotDuplicate() {
        let manager = CTOManager.shared
        let pathWithWrapper = manager.wrapperBinDir.path + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithWrapper)
        XCTAssertEqual(
            result,
            pathWithWrapper,
            "prependedPATH should not add a duplicate entry"
        )
    }

    func testPrependedPATHAvoidsFalsePositive() {
        let manager = CTOManager.shared
        let similar = manager.wrapperBinDir.path + "_old"
        let pathWithSimilar = similar + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithSimilar)
        let expected = manager.wrapperBinDir.path + ":" + pathWithSimilar
        XCTAssertEqual(
            result,
            expected,
            "prependedPATH should not be fooled by a similarly-named directory"
        )
    }

    // MARK: - Optimizer Path

    func testOptimizerPathIsInBinDir() {
        let manager = CTOManager.shared
        XCTAssertEqual(
            manager.optimizerPath,
            manager.binDir.appendingPathComponent("chau7-optim"),
            "optimizerPath should point to chau7-optim in the bin directory"
        )
    }

    func testOptimizerPathEndsWithExpectedBinaryName() {
        let manager = CTOManager.shared
        XCTAssertTrue(
            manager.optimizerPath.lastPathComponent == "chau7-optim",
            "Optimizer binary should be named chau7-optim"
        )
    }

    func testMarkdownRendererPathIsInBinDir() {
        let manager = CTOManager.shared
        XCTAssertEqual(
            manager.markdownRendererPath,
            manager.binDir.appendingPathComponent("chau7-md"),
            "markdownRendererPath should point to chau7-md in the bin directory"
        )
    }

    // MARK: - CTO Notification Names

    func testNotificationNames() {
        let modeChanged = Notification.Name.tokenOptimizationModeChanged
        let flagRecalculated = Notification.Name.ctoFlagRecalculated

        XCTAssertNotEqual(
            modeChanged,
            flagRecalculated,
            "The two CTO notification names should be distinct"
        )
        XCTAssertEqual(modeChanged.rawValue, "com.chau7.tokenOptimizationModeChanged")
        XCTAssertEqual(flagRecalculated.rawValue, "com.chau7.ctoFlagRecalculated")
    }

    // MARK: - CTO Runtime Monitor

    func testCTORuntimeMonitorTracksDecisions() {
        CTORuntimeMonitor.shared.reset()

        CTORuntimeMonitor.shared.recordModeChanged(from: .off, to: .allTabs)
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: "session-1",
            mode: .allTabs,
            override: .default,
            isAIActive: false,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .allTabsDefault
        )
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: "session-1",
            mode: .allTabs,
            override: .default,
            isAIActive: false,
            previousState: true,
            nextState: false,
            changed: true,
            reason: .off
        )
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: "session-2",
            mode: .manual,
            override: .forceOff,
            isAIActive: false,
            previousState: false,
            nextState: false,
            changed: false,
            reason: .unchanged
        )
        CTORuntimeMonitor.shared.recordDeferredSet(sessionID: "session-2")
        CTORuntimeMonitor.shared.recordDeferredSkip(
            sessionID: "session-2",
            reason: "mode-change",
            mode: .manual,
            override: .forceOff,
            isAIActive: false
        )
        CTORuntimeMonitor.shared.recordDeferredFlush(
            sessionID: "session-2",
            delayToActivateMs: 120,
            mode: .aiOnly,
            override: .default,
            isAIActive: true,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .aiOnlyWithAI
        )

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.mode, TokenOptimizationMode.allTabs.rawValue)
        XCTAssertEqual(snapshot.recalcCount, 4)
        XCTAssertEqual(snapshot.createdCount, 2)
        XCTAssertEqual(snapshot.removedCount, 1)
        XCTAssertEqual(snapshot.unchangedCount, 1)
        XCTAssertEqual(snapshot.deferredSetCount, 1)
        XCTAssertEqual(snapshot.deferredSkipCount, 1)
        XCTAssertEqual(snapshot.deferredFlushCount, 1)
        XCTAssertEqual(snapshot.deferredFlushDelayCount, 1)
        XCTAssertEqual(snapshot.deferredFlushDelayMinMs, 120)
        XCTAssertEqual(snapshot.deferredFlushDelayMaxMs, 120)
        XCTAssertEqual(snapshot.deferredFlushDelayLastMs, 120)
        XCTAssertEqual(snapshot.reasonBreakdown[CTODecisionReason.allTabsDefault.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[CTODecisionReason.off.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[CTODecisionReason.aiOnlyWithAI.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[CTODecisionReason.unchanged.rawValue], 1)
        XCTAssertEqual(snapshot.trackedSessions, 2)
        XCTAssertNotNil(snapshot.lastDecision)
    }

    func testLogHealthSnapshotIsSideEffectFree() {
        CTORuntimeMonitor.shared.reset()

        // Prime some decisions so the snapshot has non-zero counters and
        // the assessment is computable.
        CTORuntimeMonitor.shared.recordModeChanged(from: .off, to: .allTabs)
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: "health-log-session",
            mode: .allTabs,
            override: .default,
            isAIActive: false,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .allTabsDefault
        )

        // Capture state BEFORE: emitSummary has never run so there's no
        // recorded assessment; calling logHealthSnapshot() must not
        // create one (else the next emitSummary would compute a bogus
        // transition against this synthetic baseline).
        let beforeAssessment = CTORuntimeMonitor.shared.lastEmittedAssessmentForTesting
        let beforeSnapshot = CTORuntimeMonitor.shared.snapshot()

        CTORuntimeMonitor.shared.logHealthSnapshot()

        let afterAssessment = CTORuntimeMonitor.shared.lastEmittedAssessmentForTesting
        let afterSnapshot = CTORuntimeMonitor.shared.snapshot()

        XCTAssertEqual(
            beforeAssessment,
            afterAssessment,
            "logHealthSnapshot must not mutate the assessment-transition memo"
        )
        XCTAssertEqual(
            beforeSnapshot.recalcCount,
            afterSnapshot.recalcCount,
            "logHealthSnapshot must not advance recalc bookkeeping"
        )
        XCTAssertEqual(
            beforeSnapshot.activeSessionCount,
            afterSnapshot.activeSessionCount,
            "logHealthSnapshot must not change active-session bookkeeping"
        )
    }

    func testCTORuntimeAssessmentSignals() {
        CTORuntimeMonitor.shared.reset()
        // reset() leaves the monitor's mode at .off; with tracked sessions
        // that adds a modeOffWithTrackedSessions penalty (-20) on top of the
        // lowChangeRate penalty (-30) and tips the state to .critical. This
        // test targets the lowChangeRate signal alone, so record a real mode.
        CTORuntimeMonitor.shared.recordModeChanged(from: .off, to: .manual)

        for index in 0 ..< 4 {
            CTORuntimeMonitor.shared.recordDecision(
                sessionID: "session-assess-\(index)",
                mode: .manual,
                override: .default,
                isAIActive: false,
                previousState: false,
                nextState: false,
                changed: false,
                reason: .unchanged
            )
        }

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.decisionsChangeRatePercent, 0, accuracy: 0.001)
        XCTAssertTrue(snapshot.assessment.issues.contains(.lowChangeRate))
        XCTAssertEqual(snapshot.assessment.state, .warning)
        XCTAssertEqual(snapshot.deferredSkipRatePercent, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.deferredFlushRatePercent, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.activeSessionRatioPercent, 0, accuracy: 0.001)
    }

    func testCTORuntimeDecisionIntervalStats() {
        CTORuntimeMonitor.shared.reset()

        for index in 0 ..< 4 {
            CTORuntimeMonitor.shared.recordDecision(
                sessionID: "session-interval-\(index)",
                mode: .manual,
                override: .default,
                isAIActive: false,
                previousState: false,
                nextState: false,
                changed: false,
                reason: .unchanged
            )
        }

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertNotNil(snapshot.decisionIntervalAverageSeconds)
        XCTAssertNotNil(snapshot.decisionIntervalMinSeconds)
        XCTAssertNotNil(snapshot.decisionIntervalMaxSeconds)
        if let min = snapshot.decisionIntervalMinSeconds {
            XCTAssertGreaterThanOrEqual(min, 0)
        }
        if let max = snapshot.decisionIntervalMaxSeconds {
            XCTAssertGreaterThanOrEqual(max, 0)
        }
        if let avg = snapshot.decisionIntervalAverageSeconds,
           let min = snapshot.decisionIntervalMinSeconds,
           let max = snapshot.decisionIntervalMaxSeconds {
            XCTAssertLessThanOrEqual(min, avg)
            XCTAssertLessThanOrEqual(avg, max)
        }
    }

    func testCTORuntimeMonitorResets() {
        CTORuntimeMonitor.shared.reset()
        CTORuntimeMonitor.shared.recordManagerSetup()
        CTORuntimeMonitor.shared.recordManagerTeardown()
        CTORuntimeMonitor.shared.recordModeChanged(from: .off, to: .aiOnly)
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: "session-reset",
            mode: .aiOnly,
            override: .default,
            isAIActive: true,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .aiOnlyWithAI
        )

        var snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertGreaterThan(snapshot.setupCount, 0)
        XCTAssertGreaterThan(snapshot.teardownCount, 0)
        XCTAssertGreaterThan(snapshot.recalcCount, 0)

        CTORuntimeMonitor.shared.reset()
        snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.setupCount, 0)
        XCTAssertEqual(snapshot.teardownCount, 0)
        XCTAssertEqual(snapshot.recalcCount, 0)
        XCTAssertEqual(snapshot.createdCount, 0)
        XCTAssertEqual(snapshot.removedCount, 0)
        XCTAssertEqual(snapshot.mode, TokenOptimizationMode.off.rawValue)
        XCTAssertNil(snapshot.lastDecision)
        XCTAssertNil(snapshot.lastDecisionAt)
    }

    func testCTORuntimeSetupCapturesCurrentMode() {
        CTORuntimeMonitor.shared.reset()

        CTORuntimeMonitor.shared.recordManagerSetup(mode: .allTabs)

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.mode, TokenOptimizationMode.allTabs.rawValue)
        XCTAssertFalse(snapshot.assessment.issues.contains(.modeOffWithTrackedSessions))
    }

    // MARK: - Diagnostic State File

    /// `writeDiagnosticStateSnapshot()` should materialize the current
    /// monitor state to `~/.chau7/cto_state.json` and the file should
    /// round-trip back through `CTOStateSnapshot`'s decoder. This is the
    /// integration glue between `CTORuntimeMonitor` and `CTOStateFile`.
    func testWriteDiagnosticStateSnapshotMaterializesFile() throws {
        CTORuntimeMonitor.shared.reset()
        CTORuntimeMonitor.shared.recordManagerSetup(mode: .allTabs)
        let sessionID = UUID().uuidString
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: sessionID,
            mode: .allTabs,
            override: .default,
            isAIActive: true,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .allTabsDefault
        )

        // `changed: true` above triggers `writeDiagnosticStateSnapshot`
        // automatically — assert the file exists and is parseable.
        let url = URL(fileURLWithPath: CTOStateFile.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "cto_state.json should exist after a changed decision"
        )

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CTOStateSnapshot.self, from: data)
        XCTAssertEqual(snapshot.mode, TokenOptimizationMode.allTabs.rawValue)
        XCTAssertTrue(snapshot.activeSessions.contains(sessionID))

        // teardown should remove the file
        CTORuntimeMonitor.shared.recordManagerTeardown()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "teardown should drop the diagnostic mirror"
        )
    }

    /// R2 heartbeat behavior at the monitor level. A heartbeat write
    /// must bump `updatedAt` (so external readers see freshness) but
    /// must NOT advance `lastStateChangeAt` (so they can still tell
    /// "quiet" from "broken"). Conversely, a state-change write advances
    /// both timestamps.
    func testHeartbeatWritePreservesLastStateChangeAt() throws {
        CTORuntimeMonitor.shared.reset()
        CTORuntimeMonitor.shared.recordManagerSetup(mode: .allTabs)
        let sessionID = UUID().uuidString
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: sessionID,
            mode: .allTabs,
            override: .default,
            isAIActive: true,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .allTabsDefault
        )

        let url = URL(fileURLWithPath: CTOStateFile.path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let afterChange = try decoder.decode(
            CTOStateSnapshot.self, from: Data(contentsOf: url)
        )
        let changeStamp = try XCTUnwrap(
            afterChange.lastStateChangeAt,
            "Change-driven write must set lastStateChangeAt"
        )
        XCTAssertEqual(
            afterChange.updatedAt.timeIntervalSinceReferenceDate,
            changeStamp.timeIntervalSinceReferenceDate,
            accuracy: 0.001,
            "Change-driven write uses the same instant for both stamps"
        )

        // The snapshot encodes dates as ISO8601 *without* fractional
        // seconds, so timestamps round-trip at whole-second resolution.
        // Sleep past the next second boundary so the heartbeat's
        // `updatedAt` is observably newer than the change after decoding.
        Thread.sleep(forTimeInterval: 1.1)
        CTORuntimeMonitor.shared.writeDiagnosticStateSnapshot(isHeartbeat: true)

        let afterHeartbeat = try decoder.decode(
            CTOStateSnapshot.self, from: Data(contentsOf: url)
        )
        XCTAssertEqual(
            afterHeartbeat.lastStateChangeAt,
            changeStamp,
            "Heartbeat must preserve lastStateChangeAt from the prior change"
        )
        XCTAssertGreaterThan(
            afterHeartbeat.updatedAt,
            changeStamp,
            "Heartbeat must advance updatedAt past the previous change time"
        )

        CTORuntimeMonitor.shared.recordManagerTeardown()
    }

    // MARK: - Decision Trigger Taxonomy

    /// Recording a decision with a trigger should accumulate per-trigger
    /// counts in the snapshot's `triggerBreakdown`. The trigger is
    /// independent from the resolution `reason` — the same `unchanged`
    /// reason can be produced by different triggers (an AI-state poll
    /// re-resolving to the same flag vs. a mode change re-resolving the
    /// same way), and the snapshot must let callers distinguish them.
    func testTriggerBreakdownAccumulates() {
        CTORuntimeMonitor.shared.reset()

        // Three different triggers, all resolving to `allTabsDefault`.
        for trigger: CTODecisionTrigger in [.aiStateChanged, .modeChanged, .overrideChanged] {
            CTORuntimeMonitor.shared.recordDecision(
                sessionID: UUID().uuidString,
                mode: .allTabs,
                override: .default,
                isAIActive: true,
                previousState: true,
                nextState: true,
                changed: false,
                reason: .allTabsDefault,
                trigger: trigger
            )
        }

        // A fourth without a trigger — for source-compat we still record
        // the decision, just not the trigger.
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: UUID().uuidString,
            mode: .allTabs,
            override: .default,
            isAIActive: true,
            previousState: true,
            nextState: true,
            changed: false,
            reason: .allTabsDefault
        )

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.recalcCount, 4, "all four recalcs should land in recalcCount")
        XCTAssertEqual(snapshot.triggerBreakdown.values.reduce(0, +), 3, "trigger-less call should not inflate breakdown")
        XCTAssertEqual(snapshot.triggerBreakdown[CTODecisionTrigger.aiStateChanged.rawValue], 1)
        XCTAssertEqual(snapshot.triggerBreakdown[CTODecisionTrigger.modeChanged.rawValue], 1)
        XCTAssertEqual(snapshot.triggerBreakdown[CTODecisionTrigger.overrideChanged.rawValue], 1)
    }

    // MARK: - Gain Stats

    /// `recordGainStats` should make the supplied summary visible through
    /// the next `snapshot()` call, along with its sample timestamp.
    /// Passing nil resets both fields so a stale-but-positive figure
    /// doesn't outlive its source.
    func testRecordGainStatsPlumbsThroughSnapshot() {
        CTORuntimeMonitor.shared.reset()

        let sample = CTOGainStats(
            commands: 47,
            inputTokens: 12300,
            outputTokens: 8900,
            savedTokens: 4200,
            savingsPct: 18.7,
            totalTimeMs: 5120,
            avgTimeMs: 108
        )
        let sampledAt = Date()
        CTORuntimeMonitor.shared.recordGainStats(sample, at: sampledAt)

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.gainStats, sample)
        XCTAssertEqual(snapshot.gainStatsLastSampledAt, sampledAt)
    }

    func testRecordGainStatsNilClearsPreviousSample() {
        CTORuntimeMonitor.shared.reset()
        CTORuntimeMonitor.shared.recordGainStats(
            CTOGainStats(
                commands: 1, inputTokens: 1, outputTokens: 1,
                savedTokens: 1, savingsPct: 1, totalTimeMs: 1, avgTimeMs: 1
            )
        )
        XCTAssertNotNil(CTORuntimeMonitor.shared.snapshot().gainStats)

        // Nil sample (e.g. helper returned no data) — clear the field
        // instead of preserving the stale positive number.
        CTORuntimeMonitor.shared.recordGainStats(nil)
        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertNil(snapshot.gainStats)
        XCTAssertNil(snapshot.gainStatsLastSampledAt)
    }

    func testResetClearsGainStats() {
        CTORuntimeMonitor.shared.recordGainStats(
            CTOGainStats(
                commands: 5, inputTokens: 100, outputTokens: 50,
                savedTokens: 25, savingsPct: 16.6, totalTimeMs: 500, avgTimeMs: 100
            )
        )
        CTORuntimeMonitor.shared.reset()
        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertNil(snapshot.gainStats)
        XCTAssertNil(snapshot.gainStatsLastSampledAt)
    }

    // MARK: - Windowed Gain Aggregation

    /// The recent-window aggregate must carry real timing, not the `0` the
    /// first cut hardcoded — otherwise the settings panel and the debug
    /// console's windowed view both report a bogus "0ms". Timing is summed and
    /// the average is weighted by command count across the window, so a busy
    /// day dominates a one-command day.
    func testAggregateDailyStatsSumsWindowedTiming() {
        let daily = [
            CTOManager.DailyGainEntry(
                date: "2026-07-13", commands: 100, inputTokens: 10000,
                outputTokens: 4000, savedTokens: 6000, savingsPct: 60,
                totalTimeMs: 2000, avgTimeMs: 20
            ),
            CTOManager.DailyGainEntry(
                date: "2026-07-14", commands: 300, inputTokens: 30000,
                outputTokens: 9000, savedTokens: 21000, savingsPct: 70,
                totalTimeMs: 3000, avgTimeMs: 10
            )
        ]
        let cutoff = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 13)
        )!
        let agg = CTOManager.aggregateDailyStats(daily, since: cutoff)

        XCTAssertEqual(agg.commands, 400)
        XCTAssertEqual(agg.savedTokens, 27000)
        XCTAssertEqual(agg.totalTimeMs, 5000)
        // 5000ms / 400 cmds = 12.5 → 13, NOT the naive mean of per-day
        // averages ((20 + 10) / 2 = 15).
        XCTAssertEqual(agg.avgTimeMs, 13)
    }

    /// Days before the cutoff are excluded from every rollup — timing included,
    /// so a retired multi-second-per-command day can't leak into the window.
    func testAggregateDailyStatsExcludesBeforeCutoff() {
        let daily = [
            CTOManager.DailyGainEntry(
                date: "2026-07-01", commands: 999, inputTokens: 1, outputTokens: 1,
                savedTokens: 1, savingsPct: 1, totalTimeMs: 999_000, avgTimeMs: 1000
            ),
            CTOManager.DailyGainEntry(
                date: "2026-07-14", commands: 10, inputTokens: 1000, outputTokens: 400,
                savedTokens: 600, savingsPct: 60, totalTimeMs: 100, avgTimeMs: 10
            )
        ]
        let cutoff = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 10)
        )!
        let agg = CTOManager.aggregateDailyStats(daily, since: cutoff)

        XCTAssertEqual(agg.commands, 10, "the pre-cutoff day must be dropped")
        XCTAssertEqual(agg.totalTimeMs, 100)
        XCTAssertEqual(agg.avgTimeMs, 10)
    }

    /// Empty window → zeroed stats, and `avgTimeMs` must not divide by zero.
    func testAggregateDailyStatsEmptyWindowIsZero() {
        let daily = [
            CTOManager.DailyGainEntry(
                date: "2026-07-01", commands: 5, inputTokens: 100, outputTokens: 50,
                savedTokens: 50, savingsPct: 50, totalTimeMs: 500, avgTimeMs: 100
            )
        ]
        let cutoff = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 14)
        )!
        let agg = CTOManager.aggregateDailyStats(daily, since: cutoff)

        XCTAssertEqual(agg.commands, 0)
        XCTAssertEqual(agg.totalTimeMs, 0)
        XCTAssertEqual(agg.avgTimeMs, 0)
    }

    /// The daily decoder reads per-day timing when present and tolerates its
    /// absence (older optimizer builds) by defaulting to 0 — a missing field
    /// must not fail the whole decode, which would also drop `.summary` and
    /// blank the settings panel.
    func testDailyGainEntryDecodesTimingAndToleratesMissing() throws {
        let withTiming = """
        {"date":"2026-07-14","commands":144,"input_tokens":76686,
         "output_tokens":43595,"saved_tokens":33148,"savings_pct":43.2,
         "total_time_ms":1355,"avg_time_ms":9}
        """.data(using: .utf8)!
        let present = try JSONDecoder().decode(CTOManager.DailyGainEntry.self, from: withTiming)
        XCTAssertEqual(present.totalTimeMs, 1355)
        XCTAssertEqual(present.avgTimeMs, 9)

        let withoutTiming = """
        {"date":"2026-07-14","commands":144,"input_tokens":76686,
         "output_tokens":43595,"saved_tokens":33148,"savings_pct":43.2}
        """.data(using: .utf8)!
        let missing = try JSONDecoder().decode(CTOManager.DailyGainEntry.self, from: withoutTiming)
        XCTAssertEqual(missing.totalTimeMs, 0, "missing timing defaults to 0")
        XCTAssertEqual(missing.avgTimeMs, 0)
        XCTAssertEqual(missing.commands, 144, "other fields still decode")
    }

    // MARK: - Per-Session Activity (optimizer-independent)

    private func logEntry(
        _ session: String, _ cmd: String, _ rc: Int, _ outcome: String, at epoch: TimeInterval
    ) -> CTOManager.CommandLogEntry {
        CTOManager.CommandLogEntry(
            timestamp: Date(timeIntervalSince1970: epoch),
            sessionID: session, command: cmd, exitCode: rc, outcome: outcome
        )
    }

    /// Groups by session, tallies outcomes, and derives first/last activity —
    /// the data that replaces the fork's `--session-id` query post-migration.
    func testAggregateSessionActivityGroupsAndCounts() throws {
        let entries = [
            logEntry("S1", "ls", 0, "optimized", at: 100),
            logEntry("S1", "grep", 1, "optimized", at: 200),
            logEntry("S1", "cat", 0, "skipped", at: 150),
            logEntry("S2", "find", 0, "fallthrough", at: 300)
        ]
        let acts = CTOManager.aggregateSessionActivity(entries)
        XCTAssertEqual(acts.count, 2)
        // Sorted most-recently-active first: S2 (300) before S1 (200).
        XCTAssertEqual(acts.first?.sessionID, "S2")

        let s1 = try XCTUnwrap(acts.first { $0.sessionID == "S1" })
        XCTAssertEqual(s1.totalCommands, 3)
        XCTAssertEqual(s1.optimizedCount, 2)
        XCTAssertEqual(s1.skippedCount, 1)
        XCTAssertEqual(s1.firstSeen, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(s1.lastActive, Date(timeIntervalSince1970: 200))
        // Optimized rate excludes the intentional skip: 2 / (3 - 1) = 100%.
        XCTAssertEqual(try XCTUnwrap(s1.optimizedRatePercent), 100, accuracy: 0.001)

        let s2 = try XCTUnwrap(acts.first { $0.sessionID == "S2" })
        XCTAssertEqual(s2.fallthroughCount, 1)
        XCTAssertEqual(try XCTUnwrap(s2.optimizedRatePercent), 0, accuracy: 0.001)
    }

    /// A session that only ever skipped has no meaningful sample → nil rate,
    /// never a divide-by-zero.
    func testSessionActivityAllSkipsHasNilRate() {
        let entries = [
            logEntry("S", "cat", 0, "skipped", at: 10),
            logEntry("S", "cat", 0, "skipped", at: 20)
        ]
        let activity = CTOManager.aggregateSessionActivity(entries).first
        XCTAssertNil(activity?.optimizedRatePercent)
        XCTAssertEqual(activity?.skippedCount, 2)
    }

    /// Unknown outcome strings bucket into errorCount rather than being dropped.
    func testSessionActivityUnknownOutcomeIsError() throws {
        let entries = [logEntry("S", "ls", 137, "weird", at: 5)]
        let activity = try XCTUnwrap(CTOManager.aggregateSessionActivity(entries).first)
        XCTAssertEqual(activity.errorCount, 1)
        XCTAssertEqual(activity.optimizedCount, 0)
    }

    func testAggregateSessionActivityEmpty() {
        XCTAssertTrue(CTOManager.aggregateSessionActivity([]).isEmpty)
    }

    // MARK: - Executable Wrapper Safety

    private var gitWrapperScript: String {
        CTOManager.shared.generateExecutableWrapperScript(
            for: "git",
            policy: CTOExecPolicy(gate: .subcommandAllowlist(["status", "diff", "log", "show"]))
        )
    }

    /// The generated executable wrapper embeds each hardening guarantee.
    func testExecutableWrapperContract() {
        let w = gitWrapperScript
        XCTAssertTrue(w.contains("for _dir in $PATH"), "must resolve the real binary at runtime")
        XCTAssertFalse(w.contains("/usr/bin/git"), "must NOT bake an absolute path")
        XCTAssertTrue(w.contains("CHAU7_CTO_OPTIM_ACTIVE"), "must check the recursion sentinel")
        XCTAssertTrue(w.contains("[ -t 0 ]"), "must bypass the optimizer for interactive callers")
        // Gate lists exactly the read subcommands (sorted), no mutations.
        XCTAssertTrue(w.contains("diff|log|show|status)"), "must gate on the read allowlist")
        XCTAssertFalse(w.contains("commit"), "mutations must not appear in the gate")
        XCTAssertTrue(w.contains("exec \"$_CTO_REAL\" \"$@\""), "must exec the real binary")
    }

    /// The load-bearing safety test: drive the generated `git` wrapper with a
    /// fake `git` (invocation counter) and fake optimizer, and assert the real
    /// command runs **exactly once** for a mutation, routes to the optimizer for
    /// an idempotent read, and honors the recursion sentinel + inactive fast path.
    func testExecutableWrapperSingleExecutionAndRouting() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ctoexec-\(UUID().uuidString)")
        let binDir = home.appendingPathComponent("bin")
        let chau7Bin = home.appendingPathComponent(".chau7/bin")
        let ctoActive = home.appendingPathComponent(".chau7/cto_active")
        for dir in [binDir, chau7Bin, ctoActive, home.appendingPathComponent(".chau7/cto_bin")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }

        let gitCounter = home.appendingPathComponent("git.count").path
        let optimCounter = home.appendingPathComponent("optim.count").path
        func writeExecutable(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try writeExecutable(binDir.appendingPathComponent("git"), "#!/bin/bash\necho 1 >> \(gitCounter)\nexit 0\n")
        try writeExecutable(chau7Bin.appendingPathComponent("chau7-optim"), "#!/bin/bash\necho 1 >> \(optimCounter)\nexit 0\n")
        let wrapperFile = home.appendingPathComponent("git-wrapper.sh")
        try gitWrapperScript.write(to: wrapperFile, atomically: true, encoding: .utf8)

        let session = "TESTSESSION"
        let flag = ctoActive.appendingPathComponent(session)
        func count(_ path: String) -> Int {
            (try? String(contentsOfFile: path, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
        }
        func run(_ args: [String], active: Bool, optimActive: Bool = false) throws {
            try? fm.removeItem(atPath: gitCounter)
            try? fm.removeItem(atPath: optimCounter)
            if active { fm.createFile(atPath: flag.path, contents: nil) } else { try? fm.removeItem(at: flag) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [wrapperFile.path] + args
            var env = ["HOME": home.path, "PATH": "\(binDir.path):/usr/bin:/bin"]
            if active { env["CHAU7_CTO_SESSION"] = session }
            if optimActive { env["CHAU7_CTO_OPTIM_ACTIVE"] = "1" }
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice // non-interactive (not a TTY)
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
        }

        // 1. Mutation while active → passthrough: real git runs once, optimizer untouched.
        try run(["commit", "-m", "x"], active: true)
        XCTAssertEqual(count(gitCounter), 1, "a mutation must exec the real git exactly once")
        XCTAssertEqual(count(optimCounter), 0, "the optimizer must never see a mutation")

        // 2. Idempotent read while active, non-interactive → routes to the optimizer.
        try run(["status"], active: true)
        XCTAssertEqual(count(optimCounter), 1, "a read routes to the optimizer")
        XCTAssertEqual(count(gitCounter), 0, "wrapper must not also run real git once the optimizer handled it")

        // 3. Recursion sentinel set → even an allowlisted read execs real git directly.
        try run(["status"], active: true, optimActive: true)
        XCTAssertEqual(count(gitCounter), 1, "sentinel must bypass the optimizer")
        XCTAssertEqual(count(optimCounter), 0)

        // 4. CTO inactive → fast path execs real git once.
        try run(["status"], active: false)
        XCTAssertEqual(count(gitCounter), 1)
        XCTAssertEqual(count(optimCounter), 0)
    }

    /// Machine-readable git output must bypass CTO entirely. The optimizer's
    /// human-oriented rendering cannot preserve porcelain/format/NUL contracts
    /// consumed by scripts, so the wrapper must forward those bytes unchanged.
    func testGitMachineReadableOutputPassesThroughUnchanged() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ctogit-machine-\(UUID().uuidString)")
        let binDir = home.appendingPathComponent("bin")
        let chau7Bin = home.appendingPathComponent(".chau7/bin")
        let ctoActive = home.appendingPathComponent(".chau7/cto_active")
        for dir in [binDir, chau7Bin, ctoActive, home.appendingPathComponent(".chau7/cto_bin")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }

        let expected = Data([0x4D, 0x41, 0x43, 0x48, 0x49, 0x4E, 0x45, 0x00, 0x4F, 0x55, 0x54, 0x50, 0x55, 0x54])
        let git = binDir.appendingPathComponent("git")
        try "#!/bin/bash\nprintf 'MACHINE\\0OUTPUT'\n".write(to: git, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        let optimizer = chau7Bin.appendingPathComponent("chau7-optim")
        try "#!/bin/bash\nprintf 'CORRUPTED\\n'\n".write(to: optimizer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: optimizer.path)

        let wrapperFile = home.appendingPathComponent("git-wrapper.sh")
        try gitWrapperScript.write(to: wrapperFile, atomically: true, encoding: .utf8)
        let session = "MACHINE_READABLE_SESSION"
        fm.createFile(atPath: ctoActive.appendingPathComponent(session).path, contents: nil)

        for args in [["status", "--porcelain"], ["log", "--format=%H"], ["status", "-z"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [wrapperFile.path] + args
            process.environment = [
                "HOME": home.path,
                "PATH": "\(binDir.path):/usr/bin:/bin",
                "CHAU7_CTO_SESSION": session
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
            XCTAssertEqual(
                output.fileHandleForReading.readDataToEndOfFile(),
                expected,
                "git \(args.joined(separator: " ")) must preserve machine-readable bytes"
            )
        }
    }

    /// curl's method gate must keep mutating requests away from the optimizer
    /// (no double-POST), while routing plain GETs through it.
    func testCurlMethodGateSingleExecution() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ctocurl-\(UUID().uuidString)")
        let binDir = home.appendingPathComponent("bin")
        let chau7Bin = home.appendingPathComponent(".chau7/bin")
        let ctoActive = home.appendingPathComponent(".chau7/cto_active")
        for dir in [binDir, chau7Bin, ctoActive, home.appendingPathComponent(".chau7/cto_bin")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }

        let curlCounter = home.appendingPathComponent("curl.count").path
        let optimCounter = home.appendingPathComponent("optim.count").path
        func writeExecutable(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try writeExecutable(binDir.appendingPathComponent("curl"), "#!/bin/bash\necho 1 >> \(curlCounter)\nexit 0\n")
        try writeExecutable(chau7Bin.appendingPathComponent("chau7-optim"), "#!/bin/bash\necho 1 >> \(optimCounter)\nexit 0\n")
        let wrapperFile = home.appendingPathComponent("curl-wrapper.sh")
        try CTOManager.shared.generateExecutableWrapperScript(
            for: "curl", policy: CTOExecPolicy(gate: .curlSafeMethodsOnly)
        ).write(to: wrapperFile, atomically: true, encoding: .utf8)

        let session = "CURLSESSION"
        fm.createFile(atPath: ctoActive.appendingPathComponent(session).path, contents: nil)
        func count(_ path: String) -> Int {
            (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").count ?? 0
        }
        func run(_ args: [String]) throws {
            try? fm.removeItem(atPath: curlCounter)
            try? fm.removeItem(atPath: optimCounter)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [wrapperFile.path] + args
            proc.environment = [
                "HOME": home.path, "PATH": "\(binDir.path):/usr/bin:/bin",
                "CHAU7_CTO_SESSION": session
            ]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
        }

        // POST → passthrough: real curl once, optimizer never sees it.
        try run(["-X", "POST", "http://example.test/api"])
        XCTAssertEqual(count(curlCounter), 1, "a POST must exec real curl exactly once")
        XCTAssertEqual(count(optimCounter), 0, "the optimizer must never see a mutating request")

        // Body data (implicit POST) → also passthrough.
        try run(["-d", "x=1", "http://example.test/api"])
        XCTAssertEqual(count(optimCounter), 0, "--data must not reach the optimizer")

        // Plain GET → routes to the optimizer.
        try run(["http://example.test/status.json"])
        XCTAssertEqual(count(optimCounter), 1, "a GET routes to the optimizer")
    }

    // MARK: - Flag Sweep

    /// `CTOFlagManager.removeAllFlags()` should erase every file under the
    /// flag directory and return the count, so the startup sweep in
    /// `CTOManager.setup()` can purge state left over from a crashed previous
    /// run. We seed two flags with test-scoped UUIDs and verify both are
    /// gone afterwards.
    func testRemoveAllFlagsErasesSeededFiles() {
        CTOFlagManager.ensureFlagDirectory()
        // Snapshot any pre-existing flags from a prior test/run so we can
        // measure only the ones this test creates.
        let baseline = CTOFlagManager.removeAllFlags()
        if baseline > 0 {
            // Re-seed cleared baseline state isn't possible without the
            // session IDs; leave the dir empty and continue.
        }

        let seededIDs = (0 ..< 2).map { _ in UUID().uuidString }
        for id in seededIDs {
            XCTAssertTrue(
                CTOFlagManager.createFlag(sessionID: id),
                "seed flag should have been created"
            )
            XCTAssertTrue(
                CTOFlagManager.isFlagActive(sessionID: id),
                "seed flag should be active right after createFlag"
            )
        }

        let removed = CTOFlagManager.removeAllFlags()
        XCTAssertEqual(removed, 2, "exactly the two seeded flags should be removed")
        for id in seededIDs {
            XCTAssertFalse(
                CTOFlagManager.isFlagActive(sessionID: id),
                "seeded flag must be gone after removeAllFlags()"
            )
        }
    }
}

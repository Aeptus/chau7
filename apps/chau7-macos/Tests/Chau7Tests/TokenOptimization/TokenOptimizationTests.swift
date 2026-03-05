import XCTest
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
            TestCase(mode: .manual, override: .forceOff, isAIActive: true, expected: false),
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
        XCTAssertEqual(allCases.count, 4,
                       "There should be exactly 4 optimization modes")
        XCTAssertTrue(allCases.contains(.off))
        XCTAssertTrue(allCases.contains(.allTabs))
        XCTAssertTrue(allCases.contains(.aiOnly))
        XCTAssertTrue(allCases.contains(.manual))
    }

    func testTokenOptimizationModeCodable() throws {
        for mode in TokenOptimizationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(TokenOptimizationMode.self, from: data)
            XCTAssertEqual(decoded, mode,
                           "Round-trip encoding should preserve mode \(mode)")
        }
    }

    // MARK: - TabTokenOptOverride Properties

    func testTabTokenOptOverrideAllCases() {
        let allCases = TabTokenOptOverride.allCases
        XCTAssertEqual(allCases.count, 3,
                       "There should be exactly 3 override values")
        XCTAssertTrue(allCases.contains(.default))
        XCTAssertTrue(allCases.contains(.forceOn))
        XCTAssertTrue(allCases.contains(.forceOff))
    }

    func testTabTokenOptOverrideCodable() throws {
        for override in TabTokenOptOverride.allCases {
            let data = try JSONEncoder().encode(override)
            let decoded = try JSONDecoder().decode(TabTokenOptOverride.self, from: data)
            XCTAssertEqual(decoded, override,
                           "Round-trip encoding should preserve override \(override)")
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
        let expectedMappings: [String: String] = [
            "cat": "read",
            "ls": "ls",
            "find": "find",
            "tree": "tree",
            "grep": "grep",
            "rg": "rg",
            "git": "git",
            "diff": "diff",
            "cargo": "cargo",
            "curl": "curl",
            "docker": "docker",
            "kubectl": "kubectl",
            "gh": "gh",
            "pnpm": "pnpm",
            "wget": "wget",
            "npm": "npm",
            "npx": "npx",
            "vitest": "vitest",
            "prisma": "prisma",
            "tsc": "tsc",
            "next": "next",
            "lint": "lint",
            "prettier": "prettier",
            "format": "format",
            "playwright": "playwright",
            "ruff": "ruff",
            "pytest": "pytest",
            "pip": "pip",
            "go": "go",
            "golangci-lint": "golangci-lint",
        ]

        XCTAssertEqual(map.count, expectedMappings.count,
                       "Rewrite map should have exactly \(expectedMappings.count) entries")
        for (cmd, sub) in expectedMappings {
            XCTAssertEqual(map[cmd], sub,
                           "\(cmd) should map to cto \(sub)")
        }
    }

    func testRewriteMapAndExecOnlyAreMutuallyExclusive() {
        let rewriteKeys = Set(ctoRewriteMap.keys)
        let overlap = rewriteKeys.intersection(execOnlyCommands)
        XCTAssertTrue(overlap.isEmpty,
                      "Rewrite map and exec-only commands should not overlap: \(overlap)")
    }

    func testRewriteMapPlusExecOnlyCoversSupportedCommands() {
        let rewriteKeys = Set(ctoRewriteMap.keys)
        let allCovered = rewriteKeys.union(execOnlyCommands)
        let supported = Set(supportedCommands)
        XCTAssertEqual(allCovered, supported,
                       "Rewrite map + exec-only should exactly cover supportedCommands")
    }

    func testSupportedCommandsIsDerivedFromMapAndExecOnly() {
        let commands = Set(supportedCommands)
        let expected = Set(ctoRewriteMap.keys).union(execOnlyCommands)
        XCTAssertEqual(commands, expected,
                       "supportedCommands should equal ctoRewriteMap keys ∪ execOnlyCommands")
    }

    func testExecOnlyCommandsAreSubset() {
        for cmd in execOnlyCommands {
            XCTAssertTrue(supportedCommands.contains(cmd),
                          "exec-only command '\(cmd)' should also be in supportedCommands")
        }
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
        XCTAssertEqual(decoded, stats,
                       "CTOGainStats should round-trip through JSON encoding")

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

#if !SWIFT_PACKAGE
@testable import Chau7

/// Tests requiring the app target: PATH injection, optimizer paths, runtime monitor, notifications.
final class TokenOptimizationIntegrationTests: XCTestCase {

    // MARK: - CTOManager PATH Injection

    func testPrependedPATHAddsWrapperDir() {
        let manager = CTOManager.shared
        let originalPATH = "/usr/bin:/usr/local/bin"
        let result = manager.prependedPATH(original: originalPATH)
        let expected = manager.wrapperBinDir.path + ":" + originalPATH
        XCTAssertEqual(result, expected,
                       "prependedPATH should prepend the wrapper bin directory")
    }

    func testPrependedPATHDoesNotDuplicate() {
        let manager = CTOManager.shared
        let pathWithWrapper = manager.wrapperBinDir.path + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithWrapper)
        XCTAssertEqual(result, pathWithWrapper,
                       "prependedPATH should not add a duplicate entry")
    }

    func testPrependedPATHAvoidsFalsePositive() {
        let manager = CTOManager.shared
        let similar = manager.wrapperBinDir.path + "_old"
        let pathWithSimilar = similar + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithSimilar)
        let expected = manager.wrapperBinDir.path + ":" + pathWithSimilar
        XCTAssertEqual(result, expected,
                       "prependedPATH should not be fooled by a similarly-named directory")
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

        XCTAssertNotEqual(modeChanged, flagRecalculated,
                          "The two CTO notification names should be distinct")
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

    func testCTORuntimeAssessmentSignals() {
        CTORuntimeMonitor.shared.reset()

        for index in 0..<4 {
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

        for index in 0..<4 {
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
            usleep(15_000)
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
}
#endif

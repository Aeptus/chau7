import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

/// Tests for the Token Optimization (RTK) decision logic, flag manager,
/// RTKManager PATH injection, rewrite map, and gain stats decoding.
///
/// These tests exercise the pure-logic parts of the RTK system without
/// requiring a running terminal or shell process.
final class TokenOptimizationTests: XCTestCase {

    // MARK: - RTKFlagManager.shouldBeActive Decision Matrix

    // --- Mode: .off ---

    func testOffModeAlwaysInactive() {
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .off, override: .default, isAIActive: false),
            ".off + .default + no AI -> inactive"
        )
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .off, override: .default, isAIActive: true),
            ".off + .default + AI -> inactive"
        )
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .off, override: .forceOn, isAIActive: false),
            ".off + .forceOn -> inactive (mode .off overrides forceOn)"
        )
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .off, override: .forceOff, isAIActive: true),
            ".off + .forceOff + AI -> inactive"
        )
    }

    // --- Override: .forceOff (all non-.off modes) ---

    func testForceOffOverrideAlwaysInactive() {
        for mode in [TokenOptimizationMode.allTabs, .aiOnly, .manual] {
            XCTAssertFalse(
                RTKFlagManager.shouldBeActive(mode: mode, override: .forceOff, isAIActive: false),
                "\(mode) + .forceOff + no AI -> inactive"
            )
            XCTAssertFalse(
                RTKFlagManager.shouldBeActive(mode: mode, override: .forceOff, isAIActive: true),
                "\(mode) + .forceOff + AI -> inactive"
            )
        }
    }

    // --- Override: .forceOn (all non-.off modes) ---

    func testForceOnOverrideAlwaysActive() {
        for mode in [TokenOptimizationMode.allTabs, .aiOnly, .manual] {
            XCTAssertTrue(
                RTKFlagManager.shouldBeActive(mode: mode, override: .forceOn, isAIActive: false),
                "\(mode) + .forceOn + no AI -> active"
            )
            XCTAssertTrue(
                RTKFlagManager.shouldBeActive(mode: mode, override: .forceOn, isAIActive: true),
                "\(mode) + .forceOn + AI -> active"
            )
        }
    }

    // --- Mode: .allTabs + .default ---

    func testAllTabsModeDefaultOverrideAlwaysActive() {
        XCTAssertTrue(
            RTKFlagManager.shouldBeActive(mode: .allTabs, override: .default, isAIActive: false),
            ".allTabs + .default + no AI -> active"
        )
        XCTAssertTrue(
            RTKFlagManager.shouldBeActive(mode: .allTabs, override: .default, isAIActive: true),
            ".allTabs + .default + AI -> active"
        )
    }

    // --- Mode: .aiOnly + .default ---

    func testAIOnlyModeActivatesWithAI() {
        XCTAssertTrue(
            RTKFlagManager.shouldBeActive(mode: .aiOnly, override: .default, isAIActive: true),
            ".aiOnly + .default + AI active -> active"
        )
    }

    func testAIOnlyModeInactiveWithoutAI() {
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .aiOnly, override: .default, isAIActive: false),
            ".aiOnly + .default + no AI -> inactive"
        )
    }

    // --- Mode: .manual + .default ---

    func testManualModeDefaultIsInactive() {
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .manual, override: .default, isAIActive: false),
            ".manual + .default + no AI -> inactive"
        )
        XCTAssertFalse(
            RTKFlagManager.shouldBeActive(mode: .manual, override: .default, isAIActive: true),
            ".manual + .default + AI -> inactive (manual requires explicit forceOn)"
        )
    }

    // MARK: - TokenOptimizationMode Properties

    func testTokenOptimizationModeDisplayNames() {
        XCTAssertFalse(TokenOptimizationMode.off.displayName.isEmpty,
                       "Every mode should have a non-empty display name")
        XCTAssertFalse(TokenOptimizationMode.allTabs.displayName.isEmpty)
        XCTAssertFalse(TokenOptimizationMode.aiOnly.displayName.isEmpty)
        XCTAssertFalse(TokenOptimizationMode.manual.displayName.isEmpty)
    }

    func testTokenOptimizationModeDescriptions() {
        XCTAssertFalse(TokenOptimizationMode.off.description.isEmpty,
                       "Every mode should have a non-empty description")
        XCTAssertFalse(TokenOptimizationMode.allTabs.description.isEmpty)
        XCTAssertFalse(TokenOptimizationMode.aiOnly.description.isEmpty)
        XCTAssertFalse(TokenOptimizationMode.manual.description.isEmpty)
    }

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

    // MARK: - RTKManager PATH Injection

    func testPrependedPATHAddsWrapperDir() {
        let manager = RTKManager.shared
        let originalPATH = "/usr/bin:/usr/local/bin"
        let result = manager.prependedPATH(original: originalPATH)
        let expected = manager.wrapperBinDir.path + ":" + originalPATH
        XCTAssertEqual(result, expected,
                       "prependedPATH should prepend the wrapper bin directory")
    }

    func testPrependedPATHDoesNotDuplicate() {
        let manager = RTKManager.shared
        let pathWithWrapper = manager.wrapperBinDir.path + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithWrapper)
        XCTAssertEqual(result, pathWithWrapper,
                       "prependedPATH should not add a duplicate entry")
    }

    func testPrependedPATHAvoidsFalsePositive() {
        let manager = RTKManager.shared
        let similar = manager.wrapperBinDir.path + "_old"
        let pathWithSimilar = similar + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithSimilar)
        let expected = manager.wrapperBinDir.path + ":" + pathWithSimilar
        XCTAssertEqual(result, expected,
                       "prependedPATH should not be fooled by a similarly-named directory")
    }

    // MARK: - RTKManager Supported Commands

    func testSupportedCommandsIsDerivedFromMapAndExecOnly() {
        let commands = Set(RTKManager.supportedCommands)
        let expected = Set(RTKManager.rtkRewriteMap.keys).union(RTKManager.execOnlyCommands)
        XCTAssertEqual(commands, expected,
                       "supportedCommands should equal rtkRewriteMap keys ∪ execOnlyCommands")
    }

    func testExecOnlyCommandsAreSubset() {
        let execOnly = RTKManager.execOnlyCommands
        for cmd in execOnly {
            XCTAssertTrue(RTKManager.supportedCommands.contains(cmd),
                          "exec-only command '\(cmd)' should also be in supportedCommands")
        }
    }

    // MARK: - RTK Rewrite Map

    func testRewriteMapCoversExpectedCommands() {
        let map = RTKManager.rtkRewriteMap
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
                           "\(cmd) should map to rtk \(sub)")
        }
    }

    func testRewriteMapAndExecOnlyAreMutuallyExclusive() {
        let rewriteKeys = Set(RTKManager.rtkRewriteMap.keys)
        let execOnly = RTKManager.execOnlyCommands
        let overlap = rewriteKeys.intersection(execOnly)
        XCTAssertTrue(overlap.isEmpty,
                      "Rewrite map and exec-only commands should not overlap: \(overlap)")
    }

    func testRewriteMapPlusExecOnlyCoversSupportedCommands() {
        let rewriteKeys = Set(RTKManager.rtkRewriteMap.keys)
        let execOnly = RTKManager.execOnlyCommands
        let allCovered = rewriteKeys.union(execOnly)
        let supported = Set(RTKManager.supportedCommands)
        XCTAssertEqual(allCovered, supported,
                       "Rewrite map + exec-only should exactly cover supportedCommands")
    }

    // MARK: - RTKGainStats Decoding

    func testGainStatsDecodingRoundTrip() throws {
        let stats = RTKManager.RTKGainStats(
            commands: 42,
            inputTokens: 10000,
            outputTokens: 3000,
            savedTokens: 7000,
            savingsPct: 70.0,
            totalTimeMs: 1500,
            avgTimeMs: 36
        )

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(RTKManager.RTKGainStats.self, from: data)
        XCTAssertEqual(decoded, stats,
                       "RTKGainStats should round-trip through JSON encoding")

        // Verify the encoded keys match chau7-optim gain format
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["total_commands"], "Encoded key should be 'total_commands'")
        XCTAssertNotNil(json["total_input"], "Encoded key should be 'total_input'")
        XCTAssertNotNil(json["total_output"], "Encoded key should be 'total_output'")
        XCTAssertNotNil(json["total_saved"], "Encoded key should be 'total_saved'")
    }

    func testGainStatsDecodingFromOptimizerJSON() throws {
        // Matches the actual output format of `chau7-optim gain --format json`
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

        let stats = try JSONDecoder().decode(RTKManager.RTKGainStats.self, from: json)
        XCTAssertEqual(stats.commands, 100)
        XCTAssertEqual(stats.inputTokens, 50000)
        XCTAssertEqual(stats.outputTokens, 15000)
        XCTAssertEqual(stats.savedTokens, 35000)
        XCTAssertEqual(stats.savingsPct, 70.0, accuracy: 0.001)
        XCTAssertEqual(stats.totalTimeMs, 5000)
        XCTAssertEqual(stats.avgTimeMs, 50)
    }

    // MARK: - Complete Decision Matrix (exhaustive)

    func testExhaustiveDecisionMatrix() {
        struct TestCase {
            let mode: TokenOptimizationMode
            let override: TabTokenOptOverride
            let isAIActive: Bool
            let expected: Bool
        }

        let cases: [TestCase] = [
            // .off mode: always false regardless of override or AI
            TestCase(mode: .off, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .default, isAIActive: true, expected: false),
            TestCase(mode: .off, override: .forceOn, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .forceOn, isAIActive: true, expected: false),
            TestCase(mode: .off, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .off, override: .forceOff, isAIActive: true, expected: false),
            // .allTabs + .default: always true
            TestCase(mode: .allTabs, override: .default, isAIActive: false, expected: true),
            TestCase(mode: .allTabs, override: .default, isAIActive: true, expected: true),
            // .allTabs + .forceOn: true
            TestCase(mode: .allTabs, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .allTabs, override: .forceOn, isAIActive: true, expected: true),
            // .allTabs + .forceOff: false
            TestCase(mode: .allTabs, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .allTabs, override: .forceOff, isAIActive: true, expected: false),
            // .aiOnly + .default: depends on AI
            TestCase(mode: .aiOnly, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .aiOnly, override: .default, isAIActive: true, expected: true),
            // .aiOnly + .forceOn: true
            TestCase(mode: .aiOnly, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .aiOnly, override: .forceOn, isAIActive: true, expected: true),
            // .aiOnly + .forceOff: false
            TestCase(mode: .aiOnly, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .aiOnly, override: .forceOff, isAIActive: true, expected: false),
            // .manual + .default: always false
            TestCase(mode: .manual, override: .default, isAIActive: false, expected: false),
            TestCase(mode: .manual, override: .default, isAIActive: true, expected: false),
            // .manual + .forceOn: true
            TestCase(mode: .manual, override: .forceOn, isAIActive: false, expected: true),
            TestCase(mode: .manual, override: .forceOn, isAIActive: true, expected: true),
            // .manual + .forceOff: false
            TestCase(mode: .manual, override: .forceOff, isAIActive: false, expected: false),
            TestCase(mode: .manual, override: .forceOff, isAIActive: true, expected: false),
        ]

        for tc in cases {
            let result = RTKFlagManager.shouldBeActive(
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

    // MARK: - Optimizer Path

    func testOptimizerPathIsInBinDir() {
        let manager = RTKManager.shared
        XCTAssertEqual(
            manager.optimizerPath,
            manager.binDir.appendingPathComponent("chau7-optim"),
            "optimizerPath should point to chau7-optim in the bin directory"
        )
    }

    func testOptimizerPathEndsWithExpectedBinaryName() {
        let manager = RTKManager.shared
        XCTAssertTrue(
            manager.optimizerPath.lastPathComponent == "chau7-optim",
            "Optimizer binary should be named chau7-optim"
        )
    }

    func testMarkdownRendererPathIsInBinDir() {
        let manager = RTKManager.shared
        XCTAssertEqual(
            manager.markdownRendererPath,
            manager.binDir.appendingPathComponent("chau7-md"),
            "markdownRendererPath should point to chau7-md in the bin directory"
        )
    }

    // MARK: - RTK Notification Names

    func testNotificationNames() {
        let modeChanged = Notification.Name.tokenOptimizationModeChanged
        let flagRecalculated = Notification.Name.rtkFlagRecalculated

        XCTAssertNotEqual(modeChanged, flagRecalculated,
                          "The two RTK notification names should be distinct")
        XCTAssertEqual(modeChanged.rawValue, "com.chau7.tokenOptimizationModeChanged")
        XCTAssertEqual(flagRecalculated.rawValue, "com.chau7.rtkFlagRecalculated")
    }

    // MARK: - RTK Runtime Monitor

    func testRTKRuntimeMonitorTracksDecisions() {
        RTKRuntimeMonitor.shared.reset()

        RTKRuntimeMonitor.shared.recordModeChanged(from: .off, to: .allTabs)
        RTKRuntimeMonitor.shared.recordDecision(
            sessionID: "session-1",
            mode: .allTabs,
            override: .default,
            isAIActive: false,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .allTabsDefault
        )
        RTKRuntimeMonitor.shared.recordDecision(
            sessionID: "session-1",
            mode: .allTabs,
            override: .default,
            isAIActive: false,
            previousState: true,
            nextState: false,
            changed: true,
            reason: .off
        )
        RTKRuntimeMonitor.shared.recordDecision(
            sessionID: "session-2",
            mode: .manual,
            override: .forceOff,
            isAIActive: false,
            previousState: false,
            nextState: false,
            changed: false,
            reason: .unchanged
        )
        RTKRuntimeMonitor.shared.recordDeferredSet(sessionID: "session-2")
        RTKRuntimeMonitor.shared.recordDeferredSkip(
            sessionID: "session-2",
            reason: "mode-change",
            mode: .manual,
            override: .forceOff,
            isAIActive: false
        )
        RTKRuntimeMonitor.shared.recordDeferredFlush(
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

        let snapshot = RTKRuntimeMonitor.shared.snapshot()
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
        XCTAssertEqual(snapshot.reasonBreakdown[RTKDecisionReason.allTabsDefault.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[RTKDecisionReason.off.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[RTKDecisionReason.aiOnlyWithAI.rawValue], 1)
        XCTAssertEqual(snapshot.reasonBreakdown[RTKDecisionReason.unchanged.rawValue], 1)
        XCTAssertEqual(snapshot.trackedSessions, 2)
        XCTAssertNotNil(snapshot.lastDecision)
    }

    func testRTKRuntimeAssessmentSignals() {
        RTKRuntimeMonitor.shared.reset()

        for index in 0..<4 {
            RTKRuntimeMonitor.shared.recordDecision(
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

        let snapshot = RTKRuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.decisionsChangeRatePercent, 0, accuracy: 0.001)
        XCTAssertTrue(snapshot.assessment.issues.contains(.lowChangeRate))
        XCTAssertEqual(snapshot.assessment.state, .warning)
        XCTAssertEqual(snapshot.deferredSkipRatePercent, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.deferredFlushRatePercent, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.activeSessionRatioPercent, 0, accuracy: 0.001)
    }

    func testRTKRuntimeDecisionIntervalStats() {
        RTKRuntimeMonitor.shared.reset()

        for index in 0..<4 {
            RTKRuntimeMonitor.shared.recordDecision(
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

        let snapshot = RTKRuntimeMonitor.shared.snapshot()
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

    func testRTKRuntimeMonitorResets() {
        RTKRuntimeMonitor.shared.reset()
        RTKRuntimeMonitor.shared.recordManagerSetup()
        RTKRuntimeMonitor.shared.recordManagerTeardown()
        RTKRuntimeMonitor.shared.recordModeChanged(from: .off, to: .aiOnly)
        RTKRuntimeMonitor.shared.recordDecision(
            sessionID: "session-reset",
            mode: .aiOnly,
            override: .default,
            isAIActive: true,
            previousState: false,
            nextState: true,
            changed: true,
            reason: .aiOnlyWithAI
        )

        var snapshot = RTKRuntimeMonitor.shared.snapshot()
        XCTAssertGreaterThan(snapshot.setupCount, 0)
        XCTAssertGreaterThan(snapshot.teardownCount, 0)
        XCTAssertGreaterThan(snapshot.recalcCount, 0)

        RTKRuntimeMonitor.shared.reset()
        snapshot = RTKRuntimeMonitor.shared.snapshot()
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

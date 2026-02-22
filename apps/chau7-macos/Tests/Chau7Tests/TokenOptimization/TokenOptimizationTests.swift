import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

/// Tests for the Token Optimization (RTK) decision logic, flag manager,
/// RTKManager PATH injection, and statistics tracking.
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
        // Create a PATH that contains a similar but not identical directory
        let similar = manager.wrapperBinDir.path + "_old"
        let pathWithSimilar = similar + ":/usr/bin"
        let result = manager.prependedPATH(original: pathWithSimilar)
        let expected = manager.wrapperBinDir.path + ":" + pathWithSimilar
        XCTAssertEqual(result, expected,
                       "prependedPATH should not be fooled by a similarly-named directory")
    }

    // MARK: - RTKManager Supported Commands

    func testSupportedCommandsList() {
        let commands = RTKManager.supportedCommands
        XCTAssertFalse(commands.isEmpty, "There should be at least one supported command")
        XCTAssertTrue(commands.contains("cat"), "cat should be a supported command")
        XCTAssertTrue(commands.contains("ls"), "ls should be a supported command")
        XCTAssertTrue(commands.contains("find"), "find should be a supported command")
    }

    // MARK: - RTKManager Statistics

    func testStatisticsInitialValues() {
        let manager = RTKManager.shared
        manager.resetStats()

        XCTAssertEqual(manager.totalOriginalBytes, 0)
        XCTAssertEqual(manager.totalOptimizedBytes, 0)
        XCTAssertEqual(manager.savingsPercent, 0.0, accuracy: 0.001)
    }

    func testRecordStatsAccumulates() {
        let manager = RTKManager.shared
        manager.resetStats()

        manager.recordStats(originalBytes: 1000, optimizedBytes: 400)
        manager.recordStats(originalBytes: 2000, optimizedBytes: 800)

        XCTAssertEqual(manager.totalOriginalBytes, 3000)
        XCTAssertEqual(manager.totalOptimizedBytes, 1200)
    }

    func testSavingsPercentCalculation() {
        let manager = RTKManager.shared
        manager.resetStats()

        manager.recordStats(originalBytes: 1000, optimizedBytes: 300)
        // Savings = (1000 - 300) / 1000 = 70%
        XCTAssertEqual(manager.savingsPercent, 70.0, accuracy: 0.001)
    }

    func testSavingsPercentZeroWhenNoData() {
        let manager = RTKManager.shared
        manager.resetStats()
        XCTAssertEqual(manager.savingsPercent, 0.0, accuracy: 0.001,
                       "Savings should be 0% when no data has been recorded")
    }

    func testResetStatsClearsAll() {
        let manager = RTKManager.shared
        manager.recordStats(originalBytes: 5000, optimizedBytes: 1000)
        XCTAssertGreaterThan(manager.totalOriginalBytes, 0)

        manager.resetStats()

        XCTAssertEqual(manager.totalOriginalBytes, 0)
        XCTAssertEqual(manager.totalOptimizedBytes, 0)
        XCTAssertEqual(manager.savingsPercent, 0.0, accuracy: 0.001)
    }

    // MARK: - Complete Decision Matrix (exhaustive)

    func testExhaustiveDecisionMatrix() {
        // Exhaustively test every combination of (mode, override, isAIActive)
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

    // MARK: - RTK Notification Names

    func testNotificationNames() {
        // Verify the notification names are defined and distinct
        let modeChanged = Notification.Name.tokenOptimizationModeChanged
        let flagRecalculated = Notification.Name.rtkFlagRecalculated

        XCTAssertNotEqual(modeChanged, flagRecalculated,
                          "The two RTK notification names should be distinct")
        XCTAssertEqual(modeChanged.rawValue, "com.chau7.tokenOptimizationModeChanged")
        XCTAssertEqual(flagRecalculated.rawValue, "com.chau7.rtkFlagRecalculated")
    }
}
#endif

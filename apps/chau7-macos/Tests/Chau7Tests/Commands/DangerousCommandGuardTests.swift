import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
@testable import Chau7Core

/// Tests for DangerousCommandGuard check logic.
///
/// Uses the test initializer to inject patterns directly,
/// avoiding dependency on UserDefaults or FeatureSettings.shared.
@MainActor
final class DangerousCommandGuardTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a guard configured for testing with the given state.
    private func makeGuard(
        enabled: Bool = true,
        allowList: Set<String> = [],
        blockList: Set<String> = [],
        patterns: [String] = ["rm -rf", "dd if=", "mkfs"]
    ) -> DangerousCommandGuard {
        DangerousCommandGuard(
            enabled: enabled,
            allowList: allowList,
            blockList: blockList,
            testPatterns: patterns
        )
    }

    // MARK: - Safe Commands

    func testSafeCommand() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: "ls -la"), .safe)
    }

    func testSafeCommandGitStatus() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: "git status"), .safe)
    }

    func testSafeCommandEcho() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: "echo hello"), .safe)
    }

    // MARK: - Risky Commands

    func testRiskyCommandRmRf() {
        let guard_ = makeGuard()
        let result = guard_.check(commandLine: "rm -rf /tmp/stuff")
        switch result {
        case .needsConfirmation(let command, let pattern):
            XCTAssertEqual(command, "rm -rf /tmp/stuff")
            XCTAssertEqual(pattern, "rm -rf")
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    func testRiskyCommandDd() {
        let guard_ = makeGuard()
        let result = guard_.check(commandLine: "dd if=/dev/zero of=/dev/sda")
        switch result {
        case .needsConfirmation(let command, let pattern):
            XCTAssertEqual(command, "dd if=/dev/zero of=/dev/sda")
            XCTAssertEqual(pattern, "dd if=")
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    func testRiskyCommandMkfs() {
        let guard_ = makeGuard()
        let result = guard_.check(commandLine: "mkfs.ext4 /dev/sda1")
        switch result {
        case .needsConfirmation(let command, _):
            XCTAssertEqual(command, "mkfs.ext4 /dev/sda1")
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    // MARK: - Allow List

    func testAllowListedCommand() {
        let guard_ = makeGuard(allowList: ["rm -rf /tmp/cache"])
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /tmp/cache"), .allowed)
    }

    func testAllowListDoesNotAffectOtherRiskyCommands() {
        let guard_ = makeGuard(allowList: ["rm -rf /tmp/cache"])
        let result = guard_.check(commandLine: "rm -rf /home")
        switch result {
        case .needsConfirmation:
            break // expected
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    // MARK: - Block List

    func testBlockListedCommand() {
        let guard_ = makeGuard(blockList: ["rm -rf /"])
        XCTAssertEqual(
            guard_.check(commandLine: "rm -rf /"),
            .blocked(reason: "blocked by dangerous command guard block list")
        )
    }

    func testBlockListTakesPrecedenceOverAllowList() {
        let guard_ = makeGuard(
            allowList: ["rm -rf /"],
            blockList: ["rm -rf /"]
        )
        XCTAssertEqual(
            guard_.check(commandLine: "rm -rf /"),
            .blocked(reason: "blocked by dangerous command guard block list")
        )
    }

    func testBlockListDoesNotAffectSafeCommands() {
        let guard_ = makeGuard(blockList: ["rm -rf /"])
        XCTAssertEqual(guard_.check(commandLine: "ls -la"), .safe)
    }

    // MARK: - Empty / Whitespace

    func testEmptyCommandIsSafe() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: ""), .safe)
    }

    func testWhitespaceOnlyCommandIsSafe() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: "   "), .safe)
    }

    func testNewlineOnlyCommandIsSafe() {
        let guard_ = makeGuard()
        XCTAssertEqual(guard_.check(commandLine: "\n\t  "), .safe)
    }

    // MARK: - Disabled Guard

    func testDisabledGuardReturnsSafeForRiskyCommand() {
        let guard_ = makeGuard(enabled: false)
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /"), .safe)
    }

    func testDisabledGuardReturnsSafeForBlockedCommand() {
        let guard_ = makeGuard(enabled: false, blockList: ["rm -rf /"])
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /"), .safe)
    }

    func testDisabledGuardReturnsSafeForAllowedCommand() {
        let guard_ = makeGuard(enabled: false, allowList: ["rm -rf /tmp"])
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /tmp"), .safe)
    }

    // MARK: - Case Insensitivity (via CommandRiskDetection)

    func testCaseInsensitiveMatching() {
        let guard_ = makeGuard()
        let result = guard_.check(commandLine: "RM -RF /tmp")
        switch result {
        case .needsConfirmation:
            break // expected: CommandRiskDetection normalizes to lowercase
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    // MARK: - Whitespace Trimming

    func testLeadingTrailingWhitespaceTrimmingForCheck() {
        let guard_ = makeGuard()
        let result = guard_.check(commandLine: "  rm -rf /tmp  ")
        switch result {
        case .needsConfirmation(let command, _):
            XCTAssertEqual(command, "rm -rf /tmp")
        default:
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    // MARK: - No Patterns

    func testEmptyPatternsAlwaysSafe() {
        let guard_ = makeGuard(patterns: [])
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /"), .safe)
    }

    // MARK: - List Management

    func testAddToAllowList() {
        let guard_ = makeGuard()
        guard_.addToAllowList("rm -rf /tmp/safe")
        XCTAssertTrue(guard_.allowList.contains("rm -rf /tmp/safe"))
        XCTAssertEqual(guard_.check(commandLine: "rm -rf /tmp/safe"), .allowed)
    }

    func testRemoveFromAllowList() {
        let guard_ = makeGuard(allowList: ["rm -rf /tmp/safe"])
        guard_.removeFromAllowList("rm -rf /tmp/safe")
        XCTAssertFalse(guard_.allowList.contains("rm -rf /tmp/safe"))
    }

    func testAddToBlockList() {
        let guard_ = makeGuard()
        guard_.addToBlockList("danger-cmd")
        XCTAssertTrue(guard_.blockList.contains("danger-cmd"))
        XCTAssertEqual(
            guard_.check(commandLine: "danger-cmd"),
            .blocked(reason: "blocked by dangerous command guard block list")
        )
    }

    func testRemoveFromBlockList() {
        let guard_ = makeGuard(blockList: ["danger-cmd"])
        guard_.removeFromBlockList("danger-cmd")
        XCTAssertFalse(guard_.blockList.contains("danger-cmd"))
    }

    func testClearAllowList() {
        let guard_ = makeGuard(allowList: ["a", "b", "c"])
        guard_.clearAllowList()
        XCTAssertTrue(guard_.allowList.isEmpty)
    }

    func testClearBlockList() {
        let guard_ = makeGuard(blockList: ["x", "y", "z"])
        guard_.clearBlockList()
        XCTAssertTrue(guard_.blockList.isEmpty)
    }

    func testAddEmptyToAllowListIsIgnored() {
        let guard_ = makeGuard()
        guard_.addToAllowList("  ")
        XCTAssertTrue(guard_.allowList.isEmpty)
    }

    func testAddEmptyToBlockListIsIgnored() {
        let guard_ = makeGuard()
        guard_.addToBlockList("  ")
        XCTAssertTrue(guard_.blockList.isEmpty)
    }

    func testSelfProtectionBlocksProtectedKillByPID() {
        let guard_ = makeGuard(patterns: [])
        XCTAssertEqual(
            guard_.check(
                commandLine: "kill 4242",
                selfProtectionContext: SelfProtectiveCommandContext(
                    protectedPIDs: [4242],
                    protectedProcessNames: ["chau7"]
                )
            ),
            .blocked(reason: "would terminate a protected Chau7-managed process")
        )
    }

    func testSelfProtectionAllowsUnrelatedKillByPID() {
        let guard_ = makeGuard(patterns: [])
        XCTAssertEqual(
            guard_.check(
                commandLine: "kill 4242",
                selfProtectionContext: SelfProtectiveCommandContext(
                    protectedPIDs: [9999],
                    protectedProcessNames: ["chau7"]
                )
            ),
            .safe
        )
    }
}
#endif

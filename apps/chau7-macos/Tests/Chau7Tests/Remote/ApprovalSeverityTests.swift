import XCTest
import Chau7Core

final class ApprovalSeverityTests: XCTestCase {

    // MARK: - Standard

    func testOrdinaryCommandIsStandard() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "npm install", flaggedCommand: "npm install"),
            .standard
        )
    }

    func testForceRemoveOfSingleFileIsNotDestructive() {
        // -f without -r is a routine forced delete, not a recursive wipe.
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "rm -f build.log", flaggedCommand: "rm -f build.log"),
            .standard
        )
    }

    func testPushWithoutForceIsStandard() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git push origin main", flaggedCommand: "git push origin main"),
            .standard
        )
    }

    func testWordBoundaryAvoidsFalsePositive() {
        // "add" contains "dd" as a substring but not as a token.
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git add -A", flaggedCommand: "git add -A"),
            .standard
        )
    }

    // MARK: - Protected

    func testRewrittenFlagIsProtected() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "kill 4242", flaggedCommand: "kill <chau7-pid>"),
            .protected
        )
    }

    func testProtectChau7ReasonIsProtected() {
        XCTAssertEqual(
            ApprovalSeverity.classify(
                command: "osascript -e quit",
                flaggedCommand: "osascript -e quit",
                reason: "Protect Chau7: would ask macOS to quit Chau7"
            ),
            .protected
        )
    }

    // MARK: - Destructive

    func testForcePushIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git push --force origin main", flaggedCommand: "git push --force origin main"),
            .destructive
        )
    }

    func testShortForcePushIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git push -f", flaggedCommand: "git push -f"),
            .destructive
        )
    }

    func testHardResetIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git reset --hard HEAD~2", flaggedCommand: "git reset --hard HEAD~2"),
            .destructive
        )
    }

    func testRecursiveForceRemoveIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "rm -rf ~/Projects/old", flaggedCommand: "rm -rf ~/Projects/old"),
            .destructive
        )
    }

    func testSplitRecursiveForceRemoveIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "rm -r -f node_modules", flaggedCommand: "rm -r -f node_modules"),
            .destructive
        )
    }

    func testDiskWriteIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(
                command: "sudo dd if=/dev/zero of=/dev/disk2 bs=1m",
                flaggedCommand: "sudo dd if=/dev/zero of=/dev/disk2 bs=1m"
            ),
            .destructive
        )
    }

    func testMkfsIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "mkfs.ext4 /dev/sdb1", flaggedCommand: "mkfs.ext4 /dev/sdb1"),
            .destructive
        )
    }

    func testSQLDropIsDestructiveCaseInsensitive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(
                command: "psql -c 'DROP TABLE users'",
                flaggedCommand: "psql -c 'DROP TABLE users'"
            ),
            .destructive
        )
    }

    func testForcedCleanIsDestructive() {
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "git clean -fdx", flaggedCommand: "git clean -fdx"),
            .destructive
        )
    }

    // MARK: - Precedence

    func testDestructiveWinsOverProtected() {
        // Command benign, but the flagged substitution is destructive → destructive.
        XCTAssertEqual(
            ApprovalSeverity.classify(command: "deploy.sh", flaggedCommand: "git push --force"),
            .destructive
        )
    }

    // MARK: - Round trip

    func testRawValueRoundTripForWire() {
        for severity in ApprovalSeverity.allCases {
            XCTAssertEqual(ApprovalSeverity(rawValue: severity.rawValue), severity)
        }
    }
}

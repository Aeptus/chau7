import XCTest
@testable import Chau7

final class TerminalSessionModelTerminationTests: XCTestCase {
    typealias Descendant = TerminalSessionModel.DescendantProcess

    func testAllDescendantsInShellGroupYieldsNoExtraPGIDs() {
        let shell: pid_t = 100
        let descendants: [Descendant] = [
            Descendant(pid: 101, parentPID: 100, command: "bash"),
            Descendant(pid: 102, parentPID: 101, command: "ls")
        ]
        // Plain shell case: every child shares the shell's pgid.
        let pgids = TerminalSessionModel.distinctDescendantPGIDsToSignal(
            shellPID: shell,
            descendants: descendants,
            selfPGID: 9999,
            pgidFor: { _ in shell }
        )
        XCTAssertEqual(pgids, [])
    }

    func testDistinctChildPGIDIsReportedOnce() {
        // Codex case: an inner descendant becomes its own session leader and
        // spawns its tree under that new pgid.
        let shell: pid_t = 200
        let codexLeader: pid_t = 250
        let descendants: [Descendant] = [
            Descendant(pid: 201, parentPID: 200, command: "node codex"),
            Descendant(pid: codexLeader, parentPID: 201, command: "codex-darwin-arm64"),
            Descendant(pid: 251, parentPID: codexLeader, command: "aetower-mcp"),
            Descendant(pid: 252, parentPID: codexLeader, command: "mcp-review")
        ]
        let pgidFor: (pid_t) -> pid_t = { pid in
            pid >= codexLeader ? codexLeader : shell
        }
        let pgids = TerminalSessionModel.distinctDescendantPGIDsToSignal(
            shellPID: shell,
            descendants: descendants,
            selfPGID: 9999,
            pgidFor: pgidFor
        )
        XCTAssertEqual(pgids, [codexLeader])
    }

    func testPGIDsOutsideSubtreeAreIgnored() {
        // If getpgid reports a pgid whose leader is NOT in our descendant set,
        // we must not signal it — that could be an unrelated process group.
        let shell: pid_t = 300
        let descendants: [Descendant] = [
            Descendant(pid: 301, parentPID: 300, command: "node")
        ]
        let pgids = TerminalSessionModel.distinctDescendantPGIDsToSignal(
            shellPID: shell,
            descendants: descendants,
            selfPGID: 9999,
            pgidFor: { _ in 7777 } // pgid leader 7777 is not in our tree
        )
        XCTAssertEqual(pgids, [])
    }

    func testSystemPGIDsAreFiltered() {
        let shell: pid_t = 400
        let descendants: [Descendant] = [
            Descendant(pid: 401, parentPID: 400, command: "node"),
            Descendant(pid: 1, parentPID: 0, command: "launchd"),
            Descendant(pid: 0, parentPID: 0, command: "kernel")
        ]
        let pgids = TerminalSessionModel.distinctDescendantPGIDsToSignal(
            shellPID: shell,
            descendants: descendants,
            selfPGID: 9999,
            pgidFor: { pid in pid } // each pid is its own leader
        )
        // Only pid 401 is a valid descendant leader; pid 1 and 0 are filtered.
        XCTAssertEqual(pgids, [401])
    }

    func testCallerOwnPGIDIsFiltered() {
        // Defensive: never signal the pgid of the calling process even if
        // somehow it shows up as a descendant's leader.
        let shell: pid_t = 500
        let descendants: [Descendant] = [
            Descendant(pid: 501, parentPID: 500, command: "x")
        ]
        let pgids = TerminalSessionModel.distinctDescendantPGIDsToSignal(
            shellPID: shell,
            descendants: descendants,
            selfPGID: 501,
            pgidFor: { _ in 501 }
        )
        XCTAssertEqual(pgids, [])
    }
}

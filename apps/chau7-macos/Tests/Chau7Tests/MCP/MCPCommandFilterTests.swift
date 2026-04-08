#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7

final class MCPCommandFilterTests: XCTestCase {
    func testExtractBaseCommandsSplitsBackgroundOperator() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("echo ok & rm -rf /"),
            ["echo", "rm"]
        )
    }

    func testExtractBaseCommandsSplitsNewlines() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("echo ok\nrm -rf /"),
            ["echo", "rm"]
        )
    }

    func testExtractBaseCommandsDoesNotSplitQuotedSeparatorLiterals() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("printf '&'\nprintf done"),
            ["printf", "printf"]
        )
    }

    func testExtractBaseCommandsTreatsTabsAsWhitespace() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("env\tFOO=bar\t/bin/rm -f /tmp/test"),
            ["rm"]
        )
    }

    func testBlocksProtectedKillByShellPID() {
        let result = MCPCommandFilter.check(
            "kill 51199",
            context: MCPTabContext(
                directory: "/Users/christophehenner/Downloads/Repositories/Chau7",
                processes: ["zsh", "codex", "chau7-mcp-bridge"],
                shellPID: 51199
            )
        )

        switch result.verdict {
        case .blocked(let command, let reason):
            XCTAssertEqual(command, "kill 51199")
            XCTAssertEqual(reason, "would terminate a protected Chau7-managed process")
        default:
            XCTFail("Expected self-protection block, got \(result.verdict)")
        }
    }

    func testAllowsUnrelatedKillCommand() {
        let result = MCPCommandFilter.check(
            "kill 12345",
            context: MCPTabContext(
                directory: "/tmp",
                processes: ["zsh", "node"],
                shellPID: 51199
            )
        )

        switch result.verdict {
        case .allowed, .needsApproval:
            break
        case .blocked:
            XCTFail("Expected unrelated kill to remain available")
        }
    }
}
#endif

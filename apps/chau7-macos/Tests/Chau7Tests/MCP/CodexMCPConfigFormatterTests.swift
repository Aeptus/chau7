import XCTest
@testable import Chau7

final class CodexMCPConfigFormatterTests: XCTestCase {
    func testRewritesLegacyShellCommandAndMultilineArgs() {
        let input = """
        [mcp_servers.chau7]
        command = "sh"
        args = [
            "-c",
            "$HOME/.chau7/bin/chau7-mcp-bridge",
        ]

        [mcp_servers.chau7.tools.tab_close]
        approval_mode = "approve"
        """

        let updated = CodexMCPConfigFormatter.upsertChau7Server(
            in: input,
            command: "/Users/me/.chau7/bin/chau7-mcp-bridge"
        )

        XCTAssertTrue(updated.contains("""
        [mcp_servers.chau7]
        command = "/Users/me/.chau7/bin/chau7-mcp-bridge"
        args = []

        [mcp_servers.chau7.tools.tab_close]
        """))
        XCTAssertFalse(updated.contains("command = \"sh\""))
        XCTAssertFalse(updated.contains("\"-c\""))
        XCTAssertFalse(updated.contains("$HOME/.chau7/bin/chau7-mcp-bridge"))
    }

    func testAddsMissingFieldsBeforeNextSection() throws {
        let input = """
        [model_providers.openai]
        name = "OpenAI"

        [mcp_servers.chau7]

        [features]
        web_search = true
        """

        let updated = CodexMCPConfigFormatter.upsertChau7Server(
            in: input,
            command: "/Applications/Chau7.app/Contents/MacOS/chau7-mcp-bridge"
        )

        let commandIndex = try XCTUnwrap(updated.range(of: "command = \"/Applications/Chau7.app/Contents/MacOS/chau7-mcp-bridge\""))
        let argsIndex = try XCTUnwrap(updated.range(of: "args = []"))
        let featuresIndex = try XCTUnwrap(updated.range(of: "[features]"))
        XCTAssertLessThan(commandIndex.lowerBound, argsIndex.lowerBound)
        XCTAssertLessThan(argsIndex.lowerBound, featuresIndex.lowerBound)
    }

    func testInsertsNewSectionBeforeFeatures() {
        let input = """
        model = "gpt-5.3-codex"

        [features]
        web_search = true
        """

        let updated = CodexMCPConfigFormatter.upsertChau7Server(
            in: input,
            command: "/Users/me/Bridge \"Quoted\"/chau7-mcp-bridge"
        )

        XCTAssertTrue(updated.contains("""
        [mcp_servers.chau7]
        command = "/Users/me/Bridge \\"Quoted\\"/chau7-mcp-bridge"
        args = []

        [features]
        """))
    }

    func testCommentedHeaderDoesNotPreventInsertion() {
        let input = """
        # [mcp_servers.chau7]

        [features]
        web_search = true
        """

        let updated = CodexMCPConfigFormatter.upsertChau7Server(
            in: input,
            command: "/Users/me/.chau7/bin/chau7-mcp-bridge"
        )

        XCTAssertTrue(updated.contains("""
        # [mcp_servers.chau7]

        [mcp_servers.chau7]
        command = "/Users/me/.chau7/bin/chau7-mcp-bridge"
        args = []

        [features]
        """))
    }
}

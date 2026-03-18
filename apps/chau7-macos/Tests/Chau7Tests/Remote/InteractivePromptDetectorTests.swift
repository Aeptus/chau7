import XCTest
@testable import Chau7Core

final class InteractivePromptDetectorTests: XCTestCase {
    func testDetectsClaudeProceedPrompt() throws {
        let transcript = """
        ⏺ Bash(run dangerous command)

        Bash command

        run dangerous command

        Do you want to proceed?
        ❯ 1. Yes
          2. No

        Esc to cancel · Tab to amend · ctrl+e to explain
        """

        let prompt = try XCTUnwrap(InteractivePromptDetector.detect(in: transcript, toolName: "Claude"))
        XCTAssertEqual(prompt.prompt, "Do you want to proceed?")
        XCTAssertEqual(prompt.options.map(\.id), ["1", "2"])
        XCTAssertEqual(prompt.options.map(\.label), ["Yes", "No"])
        XCTAssertEqual(prompt.options.map(\.response), ["1\n", "2\n"])
        XCTAssertTrue(prompt.options[1].isDestructive)
    }

    func testDetectsCodexOptionPrompt() throws {
        let transcript = """
        Command contains $() command substitution

        Do you want to continue?
        1. Continue
        2. Cancel
        """

        let prompt = try XCTUnwrap(InteractivePromptDetector.detect(in: transcript, toolName: "Codex"))
        XCTAssertEqual(prompt.prompt, "Do you want to continue?")
        XCTAssertEqual(prompt.options.map(\.label), ["Continue", "Cancel"])
    }

    func testDetectsCodexPromptWithoutQuestionMark() throws {
        let transcript = """
        Security review is required before execution

        Select an option
        1. Approve
        2. Reject
        """

        let prompt = try XCTUnwrap(InteractivePromptDetector.detect(in: transcript, toolName: "Codex CLI"))
        XCTAssertEqual(prompt.prompt, "Select an option")
        XCTAssertEqual(prompt.options.map(\.label), ["Approve", "Reject"])
    }

    func testIgnoresNonSupportedTool() {
        let transcript = """
        Do you want to proceed?
        1. Yes
        2. No
        """

        XCTAssertNil(InteractivePromptDetector.detect(in: transcript, toolName: "Gemini"))
    }
}

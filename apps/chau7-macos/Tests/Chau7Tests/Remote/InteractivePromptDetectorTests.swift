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
        XCTAssertEqual(prompt.options.map(\.response), ["1\r", "2\r"])
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

    // MARK: - Gating edge cases

    func testToolMatchingIsCaseInsensitive() {
        XCTAssertNotNil(InteractivePromptDetector.detect(in: basicPrompt, toolName: "CLAUDE"))
    }

    func testEmptyTextReturnsNil() {
        XCTAssertNil(InteractivePromptDetector.detect(in: "", toolName: "claude"))
    }

    func testTextWithoutPromptKeywordReturnsNil() {
        let text = "Just some output\n1. apple\n2. banana"
        XCTAssertNil(InteractivePromptDetector.detect(in: text, toolName: "claude"))
    }

    func testPromptWithFewerThanTwoOptionsReturnsNil() {
        let text = "Do you want to continue?\n1. Yes only"
        XCTAssertNil(InteractivePromptDetector.detect(in: text, toolName: "claude"))
    }

    // MARK: - Normalization / formatting

    func testNormalizesCRLFLineEndings() {
        let crlf = basicPrompt.replacingOccurrences(of: "\n", with: "\r\n")
        let result = InteractivePromptDetector.detect(in: crlf, toolName: "claude")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.options.count, 2)
    }

    func testUsesMostRecentPromptWhenMultiplePresent() {
        let text = """
        Do you want to delete?
        1. Yes
        2. No

        Do you want to continue?
        1. Accept
        2. Reject
        """
        let result = InteractivePromptDetector.detect(in: text, toolName: "claude")
        XCTAssertEqual(result?.options.map(\.label), ["Accept", "Reject"])
    }

    // MARK: - Destructive classification

    func testDestructiveWordsMarkedDestructive() {
        let text = """
        Do you want to proceed?
        1. Yes
        2. No, cancel
        3. Show details
        """
        let result = InteractivePromptDetector.detect(in: text, toolName: "claude")
        let byID = Dictionary(uniqueKeysWithValues: (result?.options ?? []).map { ($0.id, $0) })
        XCTAssertEqual(byID["1"]?.isDestructive, false)
        XCTAssertEqual(byID["2"]?.isDestructive, true)
        XCTAssertEqual(byID["3"]?.isDestructive, false)
    }

    // MARK: - Detail parsing

    func testDetailCapturedFromPrecedingLines() {
        let text = """
        You are about to force-push main.
        This will overwrite upstream.
        Do you want to proceed?
        1. Yes
        2. No
        """
        let result = InteractivePromptDetector.detect(in: text, toolName: "claude")
        XCTAssertEqual(result?.detail, "You are about to force-push main.\nThis will overwrite upstream.")
    }

    func testMetaLinesExcludedFromDetail() {
        let text = """
        Danger: irreversible action.
        Esc to cancel
        Do you want to proceed?
        1. Yes
        2. No
        """
        let result = InteractivePromptDetector.detect(in: text, toolName: "claude")
        XCTAssertEqual(result?.detail, "Danger: irreversible action.")
    }

    func testDetailIsNilWhenOnlyMetaLinesPrecede() {
        let text = """
        Esc to cancel
        Do you want to proceed?
        1. Yes
        2. No
        """
        let result = InteractivePromptDetector.detect(in: text, toolName: "claude")
        XCTAssertNil(result?.detail)
    }

    // MARK: - Signature

    func testSignatureStableAcrossCalls() {
        let first = InteractivePromptDetector.detect(in: basicPrompt, toolName: "claude")
        let second = InteractivePromptDetector.detect(in: basicPrompt, toolName: "claude")
        XCTAssertEqual(first?.signature, second?.signature)
    }

    func testSignatureChangesWhenOptionLabelsDiffer() {
        let a = InteractivePromptDetector.detect(in: basicPrompt, toolName: "claude")
        let variant = """
        Do you want to continue?
        1. Yes please
        2. Absolutely not
        """
        let b = InteractivePromptDetector.detect(in: variant, toolName: "claude")
        XCTAssertNotEqual(a?.signature, b?.signature)
    }

    // MARK: - Transcript truncation window

    func testDetectHonorsSuffix80LineWindow() {
        // `detect` only scans the last 80 normalized lines. Prompts older
        // than that in a scrollback-heavy terminal don't fire permission
        // notifications — lock in the window so a future refactor doesn't
        // silently widen it (would spike CPU) or narrow it (would lose
        // real prompts buried under long installer output).
        var visible: [String] = []
        for index in 0 ..< 70 {
            visible.append("recent output \(index)")
        }
        visible.append("Do you want to continue?")
        visible.append("  1. Yes")
        visible.append("  2. No")
        XCTAssertNotNil(
            InteractivePromptDetector.detect(in: visible.joined(separator: "\n"), toolName: "claude"),
            "prompt within the 80-line window should be detected"
        )

        var hidden: [String] = []
        hidden.append("Do you want to continue?")
        hidden.append("  1. Yes")
        hidden.append("  2. No")
        for index in 0 ..< 100 {
            hidden.append("noise \(index)")
        }
        XCTAssertNil(
            InteractivePromptDetector.detect(in: hidden.joined(separator: "\n"), toolName: "claude"),
            "prompt beyond the 80-line window should be invisible to detect"
        )
    }

    private let basicPrompt = """
    Do you want to continue?
    1. Yes
    2. No
    """
}

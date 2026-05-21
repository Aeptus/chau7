import XCTest
@testable import Chau7Core

final class ClaudeCodeHookConfigurationTests: XCTestCase {
    func testHelperScriptShortCircuitsWhenChau7TabIDIsMissing() {
        let script = ClaudeCodeHookConfiguration.helperScript(eventsFilePath: "~/.chau7/claude-events.jsonl")

        XCTAssertTrue(
            script.contains("os.environ.get(\"CHAU7_TAB_ID\""),
            "Hook must read CHAU7_TAB_ID from env so externally-spawned claudes don't contribute"
        )
        XCTAssertTrue(
            script.contains("if not tab_id:"),
            "Hook must short-circuit when CHAU7_TAB_ID is empty"
        )
    }

    func testHelperScriptIncludesTabIDInEmittedEvent() {
        let script = ClaudeCodeHookConfiguration.helperScript(eventsFilePath: "~/.chau7/claude-events.jsonl")

        XCTAssertTrue(
            script.contains("\"tabID\": tab_id"),
            "Emitted event must stamp the originating tab so downstream layers can verify ownership"
        )
    }

    func testHelperScriptDropsForeignToolTranscriptPaths() {
        // Codex's claude-plugins-official plugins fire Claude-style hooks
        // with a Codex session_id and a transcript_path under ~/.codex/.
        // The hook must reject those — otherwise Codex's UUIDs leak into
        // Chau7's Claude session table.
        let script = ClaudeCodeHookConfiguration.helperScript(eventsFilePath: "~/.chau7/claude-events.jsonl")
        XCTAssertTrue(
            script.contains("transcript_path = payload.get(\"transcript_path\")"),
            "Hook must inspect the transcript_path field"
        )
        XCTAssertTrue(
            script.contains("\"/.claude/\" not in expanded"),
            "Hook must reject events whose transcript path is not under Claude's projects dir"
        )
    }

    func testHelperScriptStillIncludesAllHookMappings() {
        let script = ClaudeCodeHookConfiguration.helperScript(eventsFilePath: "~/.chau7/claude-events.jsonl")
        for (hookName, eventType) in ClaudeCodeHookConfiguration.hookEvents {
            XCTAssertTrue(
                script.contains("\"\(hookName)\": \"\(eventType)\""),
                "Hook mapping for \(hookName) → \(eventType) must be present"
            )
        }
    }
}

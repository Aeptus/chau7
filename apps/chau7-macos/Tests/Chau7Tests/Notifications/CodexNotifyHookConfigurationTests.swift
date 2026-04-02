import XCTest
@testable import Chau7Core

final class CodexNotifyHookConfigurationTests: XCTestCase {
    func testUpsertNotifyInsertsBeforeFirstSection() {
        let content = """
        model = "gpt-5"
        approval_policy = "never"

        [features]
        """

        let updated = CodexNotifyHookConfiguration.upsertNotify(
            in: content,
            helperPath: "/tmp/chau7-codex-notify"
        )

        XCTAssertTrue(updated.contains("notify = [\"/tmp/chau7-codex-notify\"]\n[features]"))
    }

    func testUpsertNotifyReplacesExistingNotifyLine() {
        let content = """
        model = "gpt-5"
        notify = ["old-helper"]

        [features]
        raw_agent_reasoning = true
        """

        let updated = CodexNotifyHookConfiguration.upsertNotify(
            in: content,
            helperPath: "/tmp/chau7-codex-notify"
        )

        XCTAssertFalse(updated.contains("old-helper"))
        XCTAssertTrue(updated.contains("notify = [\"/tmp/chau7-codex-notify\"]"))
    }

    func testHelperScriptIncludesAuthoritativeCodexMappings() {
        let script = CodexNotifyHookConfiguration.helperScript(
            defaultEventsLogPath: "/tmp/.ai-events.log"
        )

        XCTAssertTrue(script.contains("agent-turn-complete"))
        XCTAssertTrue(script.contains("approval-requested"))
        XCTAssertTrue(script.contains("user-input-requested"))
        XCTAssertTrue(script.contains("\"source\": \"codex\""))
        XCTAssertTrue(script.contains("\"reliability\": \"authoritative\""))
    }
}

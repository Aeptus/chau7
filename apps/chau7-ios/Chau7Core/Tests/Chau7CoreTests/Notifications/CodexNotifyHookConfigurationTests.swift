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

    func testUpsertNotifyPreservesExistingNotifyEntries() {
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

        XCTAssertTrue(updated.contains("old-helper"))
        XCTAssertTrue(updated.contains("notify = [\"old-helper\", \"/tmp/chau7-codex-notify\"]"))
    }

    func testNotifyIncludesHelperDetectsInstalledHook() {
        let content = """
        model = "gpt-5"
        notify = ["old-helper", "/tmp/chau7-codex-notify"]
        """

        XCTAssertTrue(
            CodexNotifyHookConfiguration.notifyIncludesHelper(
                in: content,
                helperPath: "/tmp/chau7-codex-notify"
            )
        )
        XCTAssertFalse(
            CodexNotifyHookConfiguration.notifyIncludesHelper(
                in: content,
                helperPath: "/tmp/missing-helper"
            )
        )
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

    // MARK: - upsertTuiNotificationSettings

    func testUpsertTuiSettingsCreatesNewSectionWhenAbsent() {
        let content = """
        model = "gpt-5"
        approval_policy = "never"
        """

        let updated = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: content)

        XCTAssertTrue(updated.contains("[tui]"))
        XCTAssertTrue(updated.contains("notification_method = \"osc9\""))
        XCTAssertTrue(updated.contains("notification_condition = \"always\""))
    }

    func testUpsertTuiSettingsReplacesExistingKeysInExistingSection() {
        let content = """
        model = "gpt-5"

        [tui]
        notification_method = "bel"
        notification_condition = "unfocused"
        """

        let updated = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: content)

        XCTAssertTrue(updated.contains("notification_method = \"osc9\""))
        XCTAssertTrue(updated.contains("notification_condition = \"always\""))
        // Old values gone
        XCTAssertFalse(updated.contains("\"bel\""))
        XCTAssertFalse(updated.contains("\"unfocused\""))
        // Only one [tui] section
        let tuiCount = updated.components(separatedBy: "[tui]").count - 1
        XCTAssertEqual(tuiCount, 1)
    }

    func testUpsertTuiSettingsPreservesOtherKeysInSection() {
        let content = """
        model = "gpt-5"

        [tui]
        animations = true
        notification_method = "bel"
        """

        let updated = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: content)

        XCTAssertTrue(updated.contains("animations = true"))
        XCTAssertTrue(updated.contains("notification_method = \"osc9\""))
        XCTAssertTrue(updated.contains("notification_condition = \"always\""))
    }

    func testUpsertTuiSettingsIsIdempotent() {
        let content = """
        model = "gpt-5"
        """

        let once = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: content)
        let twice = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: once)

        XCTAssertEqual(once, twice, "Running the upsert twice must produce an identical file")
        let tuiCount = twice.components(separatedBy: "[tui]").count - 1
        XCTAssertEqual(tuiCount, 1)
    }

    func testUpsertTuiSettingsAppendsKeysWhenSectionExistsWithoutThem() {
        let content = """
        [tui]
        animations = true
        """

        let updated = CodexNotifyHookConfiguration.upsertTuiNotificationSettings(in: content)

        XCTAssertTrue(updated.contains("animations = true"))
        XCTAssertTrue(updated.contains("notification_method = \"osc9\""))
        XCTAssertTrue(updated.contains("notification_condition = \"always\""))
    }
}

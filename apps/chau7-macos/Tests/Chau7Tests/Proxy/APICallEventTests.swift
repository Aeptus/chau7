import XCTest
@testable import Chau7Core

// Note: These tests are for the public types in the Chau7Core module.
// Full integration tests for APICallEvent/APICallStats require the Chau7 target.

final class APICallEventTests: XCTestCase {

    // MARK: - AIEventSource Tests

    func testAPIProxyEventSource() {
        let source = AIEventSource.apiProxy
        XCTAssertEqual(source.rawValue, "api_proxy")
    }

    func testAllEventSourcesUnique() {
        let sources: [AIEventSource] = [
            .eventsLog, .terminalSession, .historyMonitor, .app, .apiProxy,
            .unknown, .shell, .claudeCode, .codex, .gemini, .chatgpt, .cursor, .windsurf,
            .copilot, .aider, .cline, .cody, .amazonQ, .continueAI
        ]
        let rawValues = sources.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "All event sources should have unique raw values")
    }

    // MARK: - AIEvent Tests

    func testAIEventWithCustomID() {
        let customID = UUID()
        let event = AIEvent(
            id: customID,
            source: .apiProxy,
            type: "api_call",
            tool: "Anthropic",
            message: "Test message",
            ts: "2025-01-14T12:00:00Z"
        )

        XCTAssertEqual(event.id, customID)
        XCTAssertEqual(event.source, .apiProxy)
        XCTAssertEqual(event.type, "api_call")
        XCTAssertEqual(event.tool, "Anthropic")
        XCTAssertEqual(event.message, "Test message")
    }

    func testAIEventWithoutCustomID() {
        let event = AIEvent(
            source: .apiProxy,
            type: "api_call",
            tool: "OpenAI",
            message: "Test",
            ts: "2025-01-14T12:00:00Z"
        )

        // ID should be auto-generated
        XCTAssertNotEqual(event.id, UUID())
        XCTAssertEqual(event.source, .apiProxy)
    }

    func testAIEventEquality() {
        let id = UUID()
        let event1 = AIEvent(id: id, source: .apiProxy, type: "api_call", tool: "Anthropic", message: "Test", ts: "2025-01-14T12:00:00Z")
        let event2 = AIEvent(id: id, source: .apiProxy, type: "api_call", tool: "Anthropic", message: "Test", ts: "2025-01-14T12:00:00Z")

        XCTAssertEqual(event1, event2)
    }
}

// MARK: - AIEvent Notification Tests

final class AIEventNotificationTests: XCTestCase {

    private func makeEvent(type: String, tool: String = "Claude", message: String = "") -> AIEvent {
        AIEvent(source: .app, type: type, tool: tool, message: message, ts: "2025-01-14T12:00:00Z")
    }

    // MARK: - notificationTitle

    func testNotificationTitle_NeedsValidation() {
        let event = makeEvent(type: "needs_validation")
        XCTAssertEqual(event.notificationTitle, "Claude: Needs review")
    }

    func testNotificationTitle_Idle() {
        let event = makeEvent(type: "idle")
        XCTAssertEqual(event.notificationTitle, "Claude: Waiting for input")
    }

    func testNotificationTitle_WaitingInput() {
        let event = makeEvent(type: "waiting_input")
        XCTAssertEqual(event.notificationTitle, "Claude: Waiting for input")
    }

    func testNotificationTitle_Finished() {
        let event = makeEvent(type: "finished")
        XCTAssertEqual(event.notificationTitle, "Claude: Finished")
    }

    func testNotificationTitle_Failed() {
        let event = makeEvent(type: "failed")
        XCTAssertEqual(event.notificationTitle, "Claude: Failed")
    }

    func testNotificationTitle_UnknownType() {
        let event = makeEvent(type: "some_custom_type")
        XCTAssertEqual(event.notificationTitle, "Claude: Update")
    }

    func testNotificationTitle_CaseInsensitive() {
        let event = makeEvent(type: "FINISHED")
        XCTAssertEqual(event.notificationTitle, "Claude: Finished")
    }

    func testNotificationTitle_WithToolOverride() {
        let event = makeEvent(type: "finished", tool: "Original")
        XCTAssertEqual(event.notificationTitle(toolOverride: "Cursor"), "Cursor: Finished")
    }

    func testNotificationTitle_EmptyToolOverrideFallsBackToTool() {
        let event = makeEvent(type: "finished", tool: "Claude")
        XCTAssertEqual(event.notificationTitle(toolOverride: ""), "Claude: Finished")
    }

    func testNotificationTitle_WhitespaceToolOverrideFallsBackToTool() {
        let event = makeEvent(type: "finished", tool: "Claude")
        XCTAssertEqual(event.notificationTitle(toolOverride: "  "), "Claude: Finished")
    }

    func testNotificationTitle_NilToolOverrideUsesTool() {
        let event = makeEvent(type: "idle", tool: "Aider")
        XCTAssertEqual(event.notificationTitle(toolOverride: nil), "Aider: Waiting for input")
    }

    // MARK: - notificationBody

    func testNotificationBody_NeedsValidation_EmptyMessage() {
        let event = makeEvent(type: "needs_validation")
        XCTAssertEqual(event.notificationBody, "Your input is required.")
    }

    func testNotificationBody_NeedsValidation_WithMessage() {
        let event = makeEvent(type: "needs_validation", message: "Please review the diff")
        XCTAssertEqual(event.notificationBody, "Please review the diff")
    }

    func testNotificationBody_Idle_EmptyMessage() {
        let event = makeEvent(type: "idle")
        XCTAssertEqual(event.notificationBody, "No new history entries for a while.")
    }

    func testNotificationBody_WaitingInput_EmptyMessage() {
        let event = makeEvent(type: "waiting_input")
        XCTAssertEqual(event.notificationBody, "Ready for your input.")
    }

    func testNotificationBody_Finished_EmptyMessage() {
        let event = makeEvent(type: "finished")
        XCTAssertEqual(event.notificationBody, "Done.")
    }

    func testNotificationBody_Finished_WithMessage() {
        let event = makeEvent(type: "finished", message: "Deployed to production")
        XCTAssertEqual(event.notificationBody, "Deployed to production")
    }

    func testNotificationBody_Failed_EmptyMessage() {
        let event = makeEvent(type: "failed")
        XCTAssertEqual(event.notificationBody, "Check the logs.")
    }

    func testNotificationBody_UnknownType_EmptyMessage() {
        let event = makeEvent(type: "custom_event")
        XCTAssertEqual(event.notificationBody, "custom_event")
    }

    func testNotificationBody_UnknownType_WithMessage() {
        let event = makeEvent(type: "custom_event", message: "Something happened")
        XCTAssertEqual(event.notificationBody, "custom_event: Something happened")
    }
}

// MARK: - AIEventSource Extended Tests

final class AIEventSourceExtendedTests: XCTestCase {

    func testCustomSourceViaInit() {
        let custom = AIEventSource(rawValue: "my_custom_app")
        XCTAssertEqual(custom.rawValue, "my_custom_app")
    }

    func testSourceCodableRoundTrip() throws {
        let original = AIEventSource.claudeCode
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AIEventSource.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, "claude_code")
    }

    func testSourceEquality() {
        let a = AIEventSource(rawValue: "test")
        let b = AIEventSource(rawValue: "test")
        let c = AIEventSource(rawValue: "other")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSourceHashable() {
        let sources: Set<AIEventSource> = [.app, .claudeCode, .app]
        XCTAssertEqual(sources.count, 2, "Duplicate sources should collapse in a Set")
    }

    func testSourceForProviderReturnsDedicatedAISource() {
        XCTAssertEqual(AIEventSource.forProvider("codex"), .codex)
        XCTAssertEqual(AIEventSource.forProvider("gemini"), .gemini)
        XCTAssertEqual(AIEventSource.forProvider("ChatGPT"), .chatgpt)
        XCTAssertEqual(AIEventSource.forProvider("amazon-q"), .amazonQ)
        XCTAssertEqual(AIEventSource.forProvider("Aider"), .aider)
        XCTAssertEqual(AIEventSource.forProvider("continue"), .continueAI)
        XCTAssertNil(AIEventSource.forProvider("nonexistent-tool"))
    }
}

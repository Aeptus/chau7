import XCTest
import Chau7Core

/// Compile-time tests that verify Sendable types can cross task boundaries.
/// If any type loses Sendable conformance, these tests will fail to compile.
final class SendableTests: XCTestCase {

    func testRemoteFrameSendable() async {
        let frame = RemoteFrame(type: 1, tabID: 1, seq: 0, payload: Data())
        let result = await Task { frame }.value
        XCTAssertEqual(result, frame)
    }

    func testAIEventSendable() async {
        let event = AIEvent(
            type: "test",
            tool: "cli",
            message: "msg",
            ts: "2024-01-01T00:00:00Z"
        )
        let result = await Task { event }.value
        XCTAssertEqual(result, event)
    }

    func testHistoryEntrySendable() async {
        let entry = HistoryEntry(sessionId: "test", timestamp: 1234567890, summary: "ls -la", isExit: false)
        let result = await Task { entry }.value
        XCTAssertEqual(result, entry)
    }

    func testCommandBlockSendable() async {
        let block = CommandBlock(command: "echo hello", startLine: 0, endLine: 1, startTime: Date())
        let result = await Task { block }.value
        XCTAssertEqual(result, block)
    }

    func testNotificationTriggerSendable() async {
        let trigger = NotificationTriggerCatalog.all.first!
        let result = await Task { trigger }.value
        XCTAssertEqual(result, trigger)
    }

    func testNotificationTriggerStateSendable() async {
        let state = NotificationTriggerState(overrides: ["test": true])
        let result = await Task { state }.value
        XCTAssertEqual(result, state)
    }

    func testProfileSwitchRuleSendable() async {
        let rule = ProfileSwitchRule(
            name: "test-rule",
            isEnabled: true,
            trigger: .directory(path: "/tmp"),
            profileName: "test",
            priority: 0
        )
        let result = await Task { rule }.value
        XCTAssertEqual(result, rule)
    }

    func testLLMProviderConfigSendable() async {
        let config = LLMProviderConfig(
            provider: .anthropic,
            apiKey: "test",
            endpoint: nil,
            model: "claude-3"
        )
        let result = await Task { config }.value
        XCTAssertEqual(result, config)
    }

    func testColorRGBSendable() async {
        let rgb = ColorParsing.RGB(red: 0.5, green: 0.5, blue: 0.5)
        let result = await Task { rgb }.value
        XCTAssertEqual(result, rgb)
    }

    func testChau7ConfigFileSendable() async {
        let config = Chau7ConfigFile(
            general: .init(shell: "/bin/zsh"),
            appearance: .init(fontSize: 14)
        )
        let result = await Task { config }.value
        XCTAssertEqual(result, config)
    }
}

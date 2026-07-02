import XCTest
@testable import Chau7Core

final class AIObservationTests: XCTestCase {
    func testIdentityAliasesAreOrderedSessionTabDirectoryEvent() {
        let tabID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let event = AIEvent(
            source: .claudeCode,
            type: "permission",
            tool: "Claude",
            message: "approve",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/../tmp/chau7",
            tabID: tabID,
            sessionID: "SESSION-1",
            reliability: .authoritative
        )

        let aliases = AIObservation.identityAliases(for: event)

        XCTAssertEqual(aliases.map(\.key), [
            "claude|session:session-1",
            "claude|tab:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "claude|dir:/tmp/chau7"
        ])
        XCTAssertEqual(
            AIObservation.preferredPrimaryKey(aliases: aliases, providerKey: "claude"),
            "claude|session:session-1"
        )
    }

    func testNotificationObservationClassifiesSourceExplicitly() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "terminal_osc9",
            reliability: .authoritative
        )
        let enriched = EnrichedEvent(event: event, kind: .taskFinished)

        let observation = AIObservation.notificationObservation(from: enriched)

        XCTAssertEqual(observation?.state, .finished)
        XCTAssertEqual(observation?.sourceClass, .terminalStructured)
        XCTAssertEqual(observation?.providerKey, "codex")
    }

    func testRawLifecycleObservationMapsUserPromptToRunning() {
        let event = AIEvent(
            source: .claudeCode,
            type: "user_prompt",
            rawType: "user_prompt",
            tool: "Claude",
            message: "next",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let observation = AIObservation.rawLifecycleObservation(from: event)

        XCTAssertEqual(observation?.state, .running)
        XCTAssertEqual(observation?.sourceClass, .providerHook)
    }
}

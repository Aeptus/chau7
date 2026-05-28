import XCTest
@testable import Chau7Core

final class AIEventNotificationEngineTests: XCTestCase {
    func testRawLifecycleEventReopensFinishedSessionThroughSingleEngine() {
        let engine = AIEventNotificationEngine()
        let now = Date()
        let finished = event(type: "finished", sessionID: "session-1")
        let running = event(type: "user_prompt", rawType: "user_prompt", sessionID: "session-1")
        let waiting = event(type: "waiting_input", sessionID: "session-1")

        XCTAssertDelivered(engine.process(finished, deliveryRequested: true, now: now), type: "finished")

        switch engine.process(running, deliveryRequested: false, now: now.addingTimeInterval(1)) {
        case .dropped(let drop):
            XCTAssertEqual(drop.stage, .ingress)
            XCTAssertTrue(drop.rawObservationNote?.contains("running") == true)
        case .accepted(let accepted):
            XCTAssertEqual(accepted.delivery, .disabled)
            XCTAssertTrue(accepted.rawObservationNote?.contains("running") == true)
        }

        XCTAssertDelivered(engine.process(waiting, deliveryRequested: true, now: now.addingTimeInterval(2)), type: "waiting_input")
    }

    func testDeliveryDisabledStillUpdatesSessionStateDeterministically() {
        let engine = AIEventNotificationEngine()
        let now = Date()
        let finished = event(type: "finished", sessionID: "session-1")
        let staleWaiting = event(
            type: "waiting_input",
            sessionID: "session-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        switch engine.process(finished, deliveryRequested: false, now: now) {
        case .accepted(let accepted):
            XCTAssertEqual(accepted.delivery, .disabled)
        case .dropped(let drop):
            XCTFail("Expected accepted finished event, got drop: \(drop.reason)")
        }

        switch engine.process(staleWaiting, deliveryRequested: true, now: now.addingTimeInterval(1)) {
        case .accepted(let accepted):
            switch accepted.delivery {
            case .dropped(let drop):
                XCTAssertEqual(drop.stage, .reconciliation)
                XCTAssertTrue(drop.reason.contains("Stale post-terminal"))
            case .deliver, .disabled:
                XCTFail("Expected stale waiting event to be dropped by reconciliation")
            }
        case .dropped(let drop):
            XCTFail("Expected ingress acceptance before reconciliation drop, got: \(drop.reason)")
        }
    }

    func testRepeatedAuthoritativeTerminalTurnDeliversAfterRepeatWindow() {
        let engine = AIEventNotificationEngine(
            sessionReconciler: AISessionEventReconciler(terminalRepeatWindow: 10)
        )
        let now = Date()
        let first = event(type: "finished", sessionID: "session-1")
        let nextTurn = event(type: "finished", sessionID: "session-1")

        XCTAssertDelivered(engine.process(first, deliveryRequested: true, now: now), type: "finished")
        XCTAssertDelivered(
            engine.process(nextTurn, deliveryRequested: true, now: now.addingTimeInterval(11)),
            type: "finished"
        )
    }

    func testDuplicateStateAcrossProducersReturnsAcceptedTimelineWithDroppedDelivery() {
        let engine = AIEventNotificationEngine()
        let now = Date()
        let first = event(
            type: "waiting_input",
            sessionID: "session-1",
            producer: "terminal_wait_pattern_attention",
            reliability: .heuristic
        )
        let duplicate = event(
            type: "waiting_input",
            sessionID: "session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        XCTAssertDelivered(engine.process(first, deliveryRequested: true, now: now), type: "waiting_input")

        switch engine.process(duplicate, deliveryRequested: true, now: now.addingTimeInterval(1)) {
        case .accepted(let accepted):
            XCTAssertEqual(accepted.acceptedEvent.sharedEvent.type, "waiting_input")
            switch accepted.delivery {
            case .dropped(let drop):
                XCTAssertEqual(drop.stage, .reconciliation)
                XCTAssertTrue(drop.reason.contains("Updated stronger duplicate session state"))
            case .deliver, .disabled:
                XCTFail("Expected duplicate delivery to be dropped")
            }
        case .dropped(let drop):
            XCTFail("Expected accepted timeline event with dropped delivery, got: \(drop.reason)")
        }
    }

    private func event(
        type: String,
        rawType: String? = nil,
        sessionID: String?,
        producer: String = "codex_notify_hook",
        reliability: AIEventReliability = .authoritative
    ) -> AIEvent {
        AIEvent(
            source: .codex,
            type: type,
            rawType: rawType,
            tool: "Codex",
            message: type,
            ts: "2026-04-01T00:00:00Z",
            sessionID: sessionID,
            producer: producer,
            reliability: reliability
        )
    }

    private func XCTAssertDelivered(
        _ outcome: AIEventNotificationEngine.Outcome,
        type: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .accepted(let accepted):
            switch accepted.delivery {
            case .deliver(let intent):
                XCTAssertEqual(intent.event.type, type, file: file, line: line)
            case .disabled:
                XCTFail("Expected delivery intent, got disabled delivery", file: file, line: line)
            case .dropped(let drop):
                XCTFail("Expected delivery intent, got drop: \(drop.reason)", file: file, line: line)
            }
        case .dropped(let drop):
            XCTFail("Expected accepted event, got drop: \(drop.reason)", file: file, line: line)
        }
    }
}

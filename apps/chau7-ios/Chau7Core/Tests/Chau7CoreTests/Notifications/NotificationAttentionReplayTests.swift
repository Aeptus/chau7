import Foundation
import XCTest
@testable import Chau7Core

final class NotificationAttentionReplayTests: XCTestCase {
    private struct Replay: Decodable {
        let name: String
        let events: [ReplayEvent]
    }

    private struct ReplayEvent: Decodable {
        let source: String
        let rawType: String
        let notificationType: String?
        let message: String
        let offset: TimeInterval
        let expectedKind: String?
        let expectedStage: String
        let expectedStyle: String?

        enum CodingKeys: String, CodingKey {
            case source, message, offset
            case rawType = "raw_type"
            case notificationType = "notification_type"
            case expectedKind = "expected_kind"
            case expectedStage = "expected_stage"
            case expectedStyle = "expected_style"
        }
    }

    func testRecordedAttentionScenariosReplayThroughCanonicalEngine() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "notification_attention_replays",
                withExtension: "json"
            )
        )
        let replays = try JSONDecoder().decode([Replay].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(replays.count, 12)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for replay in replays {
            let engine = AIEventNotificationEngine(
                sessionReconciler: AISessionEventReconciler(terminalRepeatWindow: 10)
            )
            for fixture in replay.events {
                let event = AIEvent(
                    source: source(named: fixture.source),
                    type: fixture.rawType,
                    rawType: fixture.rawType,
                    tool: fixture.source == "codex" ? "Codex" : "Claude",
                    message: fixture.message,
                    notificationType: fixture.notificationType,
                    ts: DateFormatters.iso8601.string(from: base.addingTimeInterval(fixture.offset)),
                    tabID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                    sessionID: "replay-session",
                    producer: "notification_replay",
                    reliability: .authoritative
                )
                let outcome = engine.process(
                    event,
                    deliveryRequested: true,
                    now: base.addingTimeInterval(fixture.offset)
                )
                assert(
                    outcome,
                    matches: fixture,
                    replayName: replay.name
                )
            }
        }
    }

    private func assert(
        _ outcome: AIEventNotificationEngine.Outcome,
        matches fixture: ReplayEvent,
        replayName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (fixture.expectedStage, outcome) {
        case ("ingress_drop", .dropped(let drop)):
            XCTAssertEqual(drop.stage, .ingress, replayName, file: file, line: line)

        case ("deliver", .accepted(let accepted)):
            XCTAssertEqual(accepted.enrichedEvent.kind.rawValue, fixture.expectedKind, replayName, file: file, line: line)
            guard case .deliver(let intent) = accepted.delivery else {
                return XCTFail("\(replayName): expected delivery, got \(accepted.delivery)", file: file, line: line)
            }
            XCTAssertEqual(
                NotificationStylePlanner.defaultStyleAction(for: intent.event)?.config["style"],
                fixture.expectedStyle,
                replayName,
                file: file,
                line: line
            )

        case ("reconciliation_drop", .accepted(let accepted)):
            XCTAssertEqual(accepted.enrichedEvent.kind.rawValue, fixture.expectedKind, replayName, file: file, line: line)
            guard case .dropped(let drop) = accepted.delivery else {
                return XCTFail("\(replayName): expected reconciliation drop", file: file, line: line)
            }
            XCTAssertEqual(drop.stage, .reconciliation, replayName, file: file, line: line)

        default:
            XCTFail("\(replayName): unexpected outcome \(outcome)", file: file, line: line)
        }
    }

    private func source(named value: String) -> AIEventSource {
        value == "codex" ? .codex : .claudeCode
    }
}

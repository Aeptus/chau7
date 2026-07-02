import XCTest
import AppKit
import Chau7Core
@testable import Chau7

/// Proves the A2 determinism contract: events published from concurrent
/// producer threads land in `recentEvents` in exactly the spine's seq order,
/// because delivery flows through the single spine-host pump instead of
/// scattered main-queue hops.
@MainActor
final class SpineOrderingIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
    }

    private func waitUntil(timeout: TimeInterval = 10.0, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testConcurrentProducersDeliverInSeqOrder() {
        let model = AppModel(notifications: NotificationServices())

        let producers = 4
        let perProducer = 30
        let total = producers * perProducer

        // Unique session per event so the session reconciler accepts every
        // one (repeated terminal states for the same identity are deduped by
        // design — that suppression is not what this test measures).
        // `recordEvent` is the synchronous any-thread spine funnel, so
        // handing the model to producer threads is the contract under test;
        // the box makes that crossing explicit to the compiler.
        let handle = ModelHandle(model: model)
        let group = DispatchGroup()
        for producer in 0 ..< producers {
            group.enter()
            DispatchQueue.global().async {
                for i in 0 ..< perProducer {
                    handle.model.recordEvent(
                        source: .claudeCode,
                        type: "finished",
                        tool: "Claude Code",
                        message: "p\(producer)-\(i)",
                        notify: false,
                        sessionID: "session-\(producer)-\(i)"
                    )
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        // All events reach the spine journal with dense seqs...
        XCTAssertTrue(
            waitUntil { model.eventSpine.journal.latestCursor == UInt64(total) },
            "expected \(total) ingested envelopes, saw \(model.eventSpine.journal.latestCursor)"
        )
        let (envelopes, _, _) = model.eventSpine.journal.envelopes(after: 0, limit: total)
        XCTAssertEqual(envelopes.map(\.seq), Array(1 ... UInt64(total)))

        // ...and the pump delivers them to recentEvents in seq order: the
        // last 25 retained events must be exactly the last 25 envelopes,
        // in order. Compared by message because the ingress adapters still
        // re-mint event IDs during shape conversion (removed in the
        // shape-collapse stage).
        let expectedTail = envelopes.suffix(25).compactMap { $0.aiEvent?.message }
        XCTAssertTrue(
            waitUntil { model.recentEvents.last?.message == expectedTail.last },
            "pump did not finish delivering; last=\(model.recentEvents.last?.message ?? "nil")"
        )
        XCTAssertEqual(model.recentEvents.map(\.message), expectedTail)
    }

    func testDeliveryRequestedIntentTravelsWithEnvelope() {
        let model = AppModel(notifications: NotificationServices())
        model.recordEvent(
            source: .apiProxy, type: "api_call", tool: "Anthropic",
            message: "m", notify: false, sessionID: "s"
        )
        model.recordEvent(
            source: .claudeCode, type: "finished", tool: "Claude Code",
            message: "m", notify: true, sessionID: "s"
        )
        XCTAssertTrue(waitUntil { model.eventSpine.journal.latestCursor == 2 })
        let (envelopes, _, _) = model.eventSpine.journal.envelopes(after: 0, limit: 2)
        XCTAssertEqual(envelopes.map(\.deliveryRequested), [false, true])
    }
}

/// Carries the non-Sendable AppModel into @Sendable producer closures.
/// Safe here because the closures only call `recordEvent`, whose whole
/// contract is synchronous lock-guarded ingest from any thread.
private struct ModelHandle: @unchecked Sendable {
    let model: AppModel
}

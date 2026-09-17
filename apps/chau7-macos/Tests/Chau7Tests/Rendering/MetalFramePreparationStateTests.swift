import XCTest
@testable import Chau7Core

final class MetalFramePreparationStateTests: XCTestCase {
    func testOutputDuringPreparationDrainsThroughFinalFrameWithoutAnotherEvent() throws {
        var state = MetalFramePreparationState()
        var requests = TerminalRenderRequestCoalescer()
        let firstTicket = try XCTUnwrap(state.request())
        let firstSnapshot = try XCTUnwrap(requests.drawRequest())

        requests.requestSync()
        XCTAssertNil(state.request())
        XCTAssertEqual(state.complete(firstTicket, succeeded: true), .publish)

        XCTAssertTrue(try requests.completeCommittedDraw(
            XCTUnwrap(requests.drawRequest()),
            preparedSyncRequest: firstSnapshot
        ))
        let finalTicket = try XCTUnwrap(state.consume(firstTicket))
        let finalSnapshot = try XCTUnwrap(requests.drawRequest())
        XCTAssertTrue(finalSnapshot.shouldSync)

        XCTAssertEqual(state.complete(finalTicket, succeeded: true), .publish)
        XCTAssertFalse(try requests.completeCommittedDraw(
            XCTUnwrap(requests.drawRequest()),
            preparedSyncRequest: finalSnapshot
        ))
        XCTAssertNil(state.consume(finalTicket))
        XCTAssertNil(state.prepared)
        XCTAssertNil(state.inFlight)
        XCTAssertNil(requests.drawRequest())
    }

    func testRedundantFollowUpCanRetireBeforeSnapshotWithoutBlockingNewOutput() throws {
        var state = MetalFramePreparationState()
        var requests = TerminalRenderRequestCoalescer()
        let ticket = try XCTUnwrap(state.request())
        let snapshot = try XCTUnwrap(requests.drawRequest())
        // A visibility retry, unlike PTY output, adds no newer sync generation.
        XCTAssertNil(state.request())
        XCTAssertEqual(state.complete(ticket, succeeded: true), .publish)
        XCTAssertFalse(requests.completeCommittedDraw(snapshot, preparedSyncRequest: snapshot))

        let redundant = try XCTUnwrap(state.consume(ticket))
        XCTAssertNil(requests.drawRequest())
        XCTAssertEqual(state.complete(redundant, succeeded: false), .discard)
        XCTAssertNil(state.prepared)

        requests.requestSync()
        XCTAssertNotNil(state.request(), "Future typing must start a worker instead of waiting behind an orphan frame")
    }

    func testBurstCoalescesToOneFollowUpPreparation() throws {
        var state = MetalFramePreparationState()
        let first = try XCTUnwrap(state.request())

        for _ in 0 ..< 1000 {
            XCTAssertNil(state.request())
        }

        XCTAssertEqual(state.complete(first, succeeded: true), .publish)
        let second = try XCTUnwrap(state.consume(first))
        XCTAssertNotEqual(second, first)
        XCTAssertNil(state.request(), "the follow-up remains the sole in-flight preparation")
    }

    func testBindingResetRejectsLateOutgoingFrame() throws {
        var state = MetalFramePreparationState()
        let outgoing = try XCTUnwrap(state.request())

        state.resetForNewBinding()

        XCTAssertEqual(state.complete(outgoing, succeeded: true), .discard)
        let incoming = try XCTUnwrap(state.request())
        XCTAssertNotEqual(incoming.bindingGeneration, outgoing.bindingGeneration)
    }

    func testPreparedFrameMustBeConsumedByItsOwnTicket() throws {
        var state = MetalFramePreparationState()
        let ticket = try XCTUnwrap(state.request())
        XCTAssertEqual(state.complete(ticket, succeeded: true), .publish)

        let foreign = MetalFramePreparationTicket(
            id: ticket.id &+ 1,
            bindingGeneration: ticket.bindingGeneration
        )
        XCTAssertNil(state.consume(foreign))
        XCTAssertEqual(state.prepared, ticket)
        XCTAssertNil(state.consume(ticket))
        XCTAssertNil(state.prepared)
    }
}

import XCTest
@testable import Chau7Core

final class MetalFramePreparationStateTests: XCTestCase {
    func testBurstCoalescesToOneFollowUpPreparation() throws {
        var state = MetalFramePreparationState()
        let first = try XCTUnwrap(state.request())

        for _ in 0 ..< 1_000 {
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

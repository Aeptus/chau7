import XCTest
@testable import Chau7Core

final class TerminalRenderRequestCoalescerTests: XCTestCase {
    func testInitialStateRequestsSyncAndPresent() {
        let coalescer = TerminalRenderRequestCoalescer()

        let request = coalescer.drawRequest()

        XCTAssertEqual(request?.shouldSync, true)
        XCTAssertEqual(request?.shouldPresent, true)
    }

    func testCommittedDrawClearsConsumedRequest() throws {
        var coalescer = TerminalRenderRequestCoalescer()
        let request = try XCTUnwrap(coalescer.drawRequest())

        let needsFollowUp = coalescer.completeCommittedDraw(request)

        XCTAssertFalse(needsFollowUp)
        XCTAssertFalse(coalescer.needsSync)
        XCTAssertFalse(coalescer.needsPresent)
        XCTAssertNil(coalescer.drawRequest())
    }

    func testNewSyncRequestDuringDrawSurvivesCommittedOlderFrame() throws {
        var coalescer = TerminalRenderRequestCoalescer()
        let inFlight = try XCTUnwrap(coalescer.drawRequest())

        coalescer.requestSync()
        let needsFollowUp = coalescer.completeCommittedDraw(inFlight)

        XCTAssertTrue(needsFollowUp)
        XCTAssertTrue(coalescer.needsSync)
        XCTAssertTrue(coalescer.needsPresent)

        let followUp = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertTrue(followUp.shouldSync)
        XCTAssertTrue(followUp.shouldPresent)
    }

    func testNewPresentRequestDuringSyncDrawKeepsPresentOnlyFollowUp() throws {
        var coalescer = TerminalRenderRequestCoalescer()
        let syncRequest = try XCTUnwrap(coalescer.drawRequest())

        coalescer.requestPresent()
        let needsFollowUp = coalescer.completeCommittedDraw(syncRequest)

        XCTAssertTrue(needsFollowUp)
        XCTAssertFalse(coalescer.needsSync)
        XCTAssertTrue(coalescer.needsPresent)

        let followUp = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertFalse(followUp.shouldSync)
        XCTAssertTrue(followUp.shouldPresent)
    }

    func testNewSyncRequestDuringPresentOnlyDrawKeepsSyncFollowUp() throws {
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: true)
        let presentOnly = try XCTUnwrap(coalescer.drawRequest())

        coalescer.requestSync()
        let needsFollowUp = coalescer.completeCommittedDraw(presentOnly)

        XCTAssertTrue(needsFollowUp)
        XCTAssertTrue(coalescer.needsSync)
        XCTAssertTrue(coalescer.needsPresent)
    }
}

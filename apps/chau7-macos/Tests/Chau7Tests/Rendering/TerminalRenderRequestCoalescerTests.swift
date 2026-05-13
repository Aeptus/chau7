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

    func testSyncBurstCoalescesToSingleLatestDrawRequest() throws {
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: false)

        for _ in 0 ..< 100 {
            coalescer.requestSync()
        }

        let request = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertTrue(request.shouldSync)
        XCTAssertTrue(request.shouldPresent)
        XCTAssertEqual(coalescer.diagnostics.pendingRequestCount, 2)
        XCTAssertEqual(coalescer.diagnostics.syncRequestCount, 100)
        XCTAssertEqual(coalescer.diagnostics.presentRequestCount, 100)
        XCTAssertEqual(coalescer.diagnostics.coalescedSyncRequestCount, 99)
        XCTAssertEqual(coalescer.diagnostics.coalescedPresentRequestCount, 99)

        XCTAssertFalse(coalescer.completeCommittedDraw(request))
        XCTAssertNil(coalescer.drawRequest())
    }

    func testPresentBurstCoalescesWithoutForcingSync() throws {
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: false)

        for _ in 0 ..< 12 {
            coalescer.requestPresent()
        }

        let request = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertFalse(request.shouldSync)
        XCTAssertTrue(request.shouldPresent)
        XCTAssertEqual(coalescer.diagnostics.pendingRequestCount, 1)
        XCTAssertEqual(coalescer.diagnostics.syncRequestCount, 0)
        XCTAssertEqual(coalescer.diagnostics.presentRequestCount, 12)
        XCTAssertEqual(coalescer.diagnostics.coalescedPresentRequestCount, 11)
    }

    func testDiagnosticsRetainLatestFrameWinsAfterOlderCommit() throws {
        var coalescer = TerminalRenderRequestCoalescer()
        let inFlight = try XCTUnwrap(coalescer.drawRequest())

        for _ in 0 ..< 10 {
            coalescer.requestSync()
        }

        XCTAssertTrue(coalescer.completeCommittedDraw(inFlight))
        XCTAssertTrue(coalescer.needsSync)
        XCTAssertTrue(coalescer.needsPresent)
        XCTAssertEqual(coalescer.diagnostics.syncRequestCount, 11)
        XCTAssertEqual(coalescer.diagnostics.presentRequestCount, 11)
        XCTAssertEqual(coalescer.diagnostics.coalescedSyncRequestCount, 10)
        XCTAssertEqual(coalescer.diagnostics.coalescedPresentRequestCount, 10)
    }

    func testTwelveAgentBurstKeepsOnlyLatestFramePending() throws {
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: false)

        for _ in 0 ..< 12 {
            for _ in 0 ..< 25 {
                coalescer.requestSync()
            }
        }

        var diagnostics = coalescer.diagnostics
        XCTAssertEqual(diagnostics.syncRequestCount, 300)
        XCTAssertEqual(diagnostics.presentRequestCount, 300)
        XCTAssertEqual(diagnostics.pendingRequestCount, 2)
        XCTAssertEqual(diagnostics.coalescedSyncRequestCount, 299)
        XCTAssertEqual(diagnostics.coalescedPresentRequestCount, 299)

        let inFlight = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertTrue(inFlight.shouldSync)
        XCTAssertTrue(inFlight.shouldPresent)

        for _ in 0 ..< 12 {
            coalescer.requestSync()
        }

        XCTAssertTrue(coalescer.completeCommittedDraw(inFlight))
        diagnostics = coalescer.diagnostics
        XCTAssertEqual(diagnostics.syncRequestCount, 312)
        XCTAssertEqual(diagnostics.presentRequestCount, 312)
        XCTAssertEqual(diagnostics.pendingRequestCount, 2)
        XCTAssertEqual(diagnostics.coalescedSyncRequestCount, 311)
        XCTAssertEqual(diagnostics.coalescedPresentRequestCount, 311)

        let followUp = try XCTUnwrap(coalescer.drawRequest())
        XCTAssertTrue(followUp.shouldSync)
        XCTAssertTrue(followUp.shouldPresent)
        XCTAssertFalse(coalescer.completeCommittedDraw(followUp))
        XCTAssertNil(coalescer.drawRequest())
    }

    func testResetDropsStalePendingRequestsAndDiagnostics() {
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: false)

        coalescer.requestPresent()
        coalescer.requestSync()
        XCTAssertNotNil(coalescer.drawRequest())

        coalescer.reset()

        XCTAssertFalse(coalescer.needsSync)
        XCTAssertFalse(coalescer.needsPresent)
        XCTAssertEqual(coalescer.diagnostics.pendingRequestCount, 0)
        XCTAssertEqual(coalescer.diagnostics.syncRequestCount, 0)
        XCTAssertEqual(coalescer.diagnostics.presentRequestCount, 0)
        XCTAssertEqual(coalescer.diagnostics.coalescedSyncRequestCount, 0)
        XCTAssertEqual(coalescer.diagnostics.coalescedPresentRequestCount, 0)
        XCTAssertNil(coalescer.drawRequest())
    }
}

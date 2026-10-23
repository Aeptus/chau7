import XCTest
import Chau7Core

final class RemoteGridDeliveryPolicyTests: XCTestCase {
    func testMatchingConnectedStreamAcceptsFrame() {
        XCTAssertTrue(deliver())
    }

    func testReconnectSelectionAndPaneReplacementRejectOldFrames() {
        XCTAssertFalse(deliver(epoch: 2))
        XCTAssertFalse(deliver(tab: 2))
        XCTAssertFalse(deliver(session: "replacement"))
        XCTAssertFalse(deliver(connected: false))
        XCTAssertFalse(deliver(full: false))
        XCTAssertFalse(deliver(tab: nil))
        XCTAssertFalse(deliver(session: nil))
    }

    private func deliver(
        epoch: UInt64 = 1,
        tab: UInt32? = 1,
        session: String? = "pane",
        connected: Bool = true,
        full: Bool = true
    ) -> Bool {
        RemoteGridDeliveryPolicy.shouldDeliver(
            capturedEpoch: 1, currentEpoch: epoch, capturedTab: 1, selectedTab: tab,
            capturedSession: "pane", currentSession: session,
            isConnected: connected, streamsTerminal: full
        )
    }
}

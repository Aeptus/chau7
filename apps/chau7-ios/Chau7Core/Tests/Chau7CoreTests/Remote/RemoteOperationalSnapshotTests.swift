import XCTest
@testable import Chau7Core

final class RemoteOperationalSnapshotTests: XCTestCase {
    func testSummaryCorrelatesEveryRemoteLayer() {
        let snapshot = RemoteOperationalSnapshot(
            agent: "running",
            ipc: "connected",
            relay: "reconnecting",
            session: "ready",
            tabCount: 33,
            stream: "full"
        )

        XCTAssertEqual(
            snapshot.summary,
            "agent=running ipc=connected relay=reconnecting session=ready tabs=33 stream=full"
        )
    }

    func testNegativeTabCountIsClamped() {
        let snapshot = RemoteOperationalSnapshot(
            agent: "stopped",
            ipc: "disconnected",
            relay: "unknown",
            session: "disconnected",
            tabCount: -1,
            stream: "full"
        )

        XCTAssertEqual(snapshot.tabCount, 0)
    }
}

import XCTest
@testable import Chau7

final class DevServerMonitorTests: XCTestCase {
    func testBurstChecksContinueWhilePortIsStillPending() {
        let server = DevServerMonitor.DevServerInfo(
            name: "Vite",
            port: nil,
            url: "http://localhost",
            pid: nil
        )

        XCTAssertFalse(
            DevServerMonitor.shouldStopBurstChecks(currentServer: server, burstChecksRemaining: 3)
        )
    }

    func testBurstChecksStopOncePortIsKnown() {
        let server = DevServerMonitor.DevServerInfo(
            name: "Vite",
            port: 5173,
            url: "http://localhost:5173",
            pid: 123
        )

        XCTAssertTrue(
            DevServerMonitor.shouldStopBurstChecks(currentServer: server, burstChecksRemaining: 3)
        )
    }

    func testBurstChecksStopWhenRetriesAreExhausted() {
        XCTAssertTrue(
            DevServerMonitor.shouldStopBurstChecks(currentServer: nil, burstChecksRemaining: 0)
        )
    }
}

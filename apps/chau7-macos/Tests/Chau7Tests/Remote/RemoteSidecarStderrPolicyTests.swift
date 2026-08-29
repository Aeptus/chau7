import XCTest
@testable import Chau7Core

final class RemoteSidecarStderrPolicyTests: XCTestCase {
    func testSuppressesInjectedMallocStackLoggingNoise() {
        XCTAssertEqual(
            RemoteSidecarStderrPolicy.disposition(
                for: "chau7-remote: MallocStackLogging: can't turn off malloc stack logging because it was not enabled."
            ),
            .suppress
        )
    }

    func testRoutineReconnectLifecycleIsInformational() {
        XCTAssertEqual(
            RemoteSidecarStderrPolicy.disposition(
                for: "2026/08/29 10:00:00 relay disconnected, reconnecting in 2s"
            ),
            .info
        )
        XCTAssertEqual(
            RemoteSidecarStderrPolicy.disposition(
                for: "2026/08/29 10:00:00 ipc disconnected, reconnecting in 1s"
            ),
            .info
        )
    }

    func testConnectionFailuresRemainWarnings() {
        XCTAssertEqual(
            RemoteSidecarStderrPolicy.disposition(
                for: "2026/08/29 10:00:00 relay connect: websocket handshake: 503 (retry in 2s)"
            ),
            .warning
        )
    }

    func testUnknownStderrRemainsWarning() {
        XCTAssertEqual(
            RemoteSidecarStderrPolicy.disposition(for: "unexpected helper failure"),
            .warning
        )
    }
}

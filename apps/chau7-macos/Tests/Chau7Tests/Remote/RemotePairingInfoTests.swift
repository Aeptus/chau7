import XCTest
@testable import Chau7

final class RemotePairingInfoTests: XCTestCase {
    func testPairingJSONStringEncodesExpectedPayload() throws {
        let info = RemotePairingInfo(
            deviceID: "device-123",
            macPub: "mac-pub",
            pairingCode: "123456",
            expiresAt: "2026-05-12T12:00:00Z",
            relayURL: "wss://relay.chau7.sh/connect"
        )

        let json = try XCTUnwrap(info.pairingJSONString())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(RemoteQRPayload.self, from: data)

        XCTAssertEqual(
            payload,
            RemoteQRPayload(
                relayURL: "wss://relay.chau7.sh/connect",
                deviceID: "device-123",
                macPub: "mac-pub",
                pairingCode: "123456",
                expiresAt: "2026-05-12T12:00:00Z"
            )
        )
    }

    func testPairingJSONStringPrettyPrintedUsesMultilineOutput() throws {
        let info = RemotePairingInfo(
            deviceID: "device-123",
            macPub: "mac-pub",
            pairingCode: "123456",
            expiresAt: "2026-05-12T12:00:00Z",
            relayURL: "wss://relay.chau7.sh/connect"
        )

        let json = try XCTUnwrap(info.pairingJSONString(prettyPrinted: true))

        XCTAssertTrue(json.contains("\n"))
        XCTAssertTrue(json.contains("\"relay_url\""))
    }

    func testPairingRegenerationPlanStartsAgentWhenRemoteIsEnabled() {
        let plan = RemotePairingRegenerationPlan.make(
            isRemoteEnabled: true,
            isAgentRunning: false
        )

        XCTAssertEqual(
            plan,
            RemotePairingRegenerationPlan(
                shouldStopAgent: false,
                shouldStartAgent: true
            )
        )
    }

    func testPairingRegenerationPlanRestartsRunningAgentWhenEnabled() {
        let plan = RemotePairingRegenerationPlan.make(
            isRemoteEnabled: true,
            isAgentRunning: true
        )

        XCTAssertEqual(
            plan,
            RemotePairingRegenerationPlan(
                shouldStopAgent: true,
                shouldStartAgent: true
            )
        )
    }

    func testPairingRegenerationPlanDoesNotRestartDisabledRemoteControl() {
        let plan = RemotePairingRegenerationPlan.make(
            isRemoteEnabled: false,
            isAgentRunning: true
        )

        XCTAssertEqual(
            plan,
            RemotePairingRegenerationPlan(
                shouldStopAgent: true,
                shouldStartAgent: false
            )
        )
    }
}

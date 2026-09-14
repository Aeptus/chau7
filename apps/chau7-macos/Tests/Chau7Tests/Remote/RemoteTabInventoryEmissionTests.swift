import XCTest
@testable import Chau7Core

final class RemoteTabInventoryEmissionTests: XCTestCase {
    func testDuplicateInventoryIsSuppressed() {
        var gate = RemoteTabInventoryEmissionGate()
        let payload = makePayload(title: "Shell")

        XCTAssertTrue(gate.shouldEmit(payload))
        XCTAssertFalse(gate.shouldEmit(payload))
    }

    func testSemanticChangeIsEmitted() {
        var gate = RemoteTabInventoryEmissionGate()

        XCTAssertTrue(gate.shouldEmit(makePayload(title: "Shell")))
        XCTAssertTrue(gate.shouldEmit(makePayload(title: "Build")))
    }

    func testResetMakesCurrentInventoryEligibleForNewSession() {
        var gate = RemoteTabInventoryEmissionGate()
        let payload = makePayload(title: "Shell")
        XCTAssertTrue(gate.shouldEmit(payload))
        XCTAssertFalse(gate.shouldEmit(payload))

        gate.reset()

        XCTAssertTrue(gate.shouldEmit(payload))
    }

    private func makePayload(title: String) -> RemoteTabListPayload {
        RemoteTabListPayload(
            tabs: [
                RemoteTabDescriptor(
                    tabID: 1,
                    title: title,
                    isActive: true,
                    isMCPControlled: false
                )
            ],
            capabilities: [RemoteTabListPayload.keyInputCapability]
        )
    }
}

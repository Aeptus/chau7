import Foundation
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

    func testTerminalColorSchemeChangeIsEmitted() {
        var gate = RemoteTabInventoryEmissionGate()

        XCTAssertTrue(gate.shouldEmit(makePayload(title: "Shell", colorScheme: .default)))
        XCTAssertTrue(gate.shouldEmit(makePayload(title: "Shell", colorScheme: .dracula)))
    }

    func testTerminalColorSchemeUsesSnakeCaseWireKey() throws {
        let data = try JSONEncoder().encode(makePayload(title: "Shell", colorScheme: .dracula))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(object["terminal_color_scheme"])
        XCTAssertNil(object["terminalColorScheme"])
    }

    func testResetMakesCurrentInventoryEligibleForNewSession() {
        var gate = RemoteTabInventoryEmissionGate()
        let payload = makePayload(title: "Shell")
        XCTAssertTrue(gate.shouldEmit(payload))
        XCTAssertFalse(gate.shouldEmit(payload))

        gate.reset()

        XCTAssertTrue(gate.shouldEmit(payload))
    }

    private func makePayload(
        title: String,
        colorScheme: TerminalColorScheme? = nil
    ) -> RemoteTabListPayload {
        RemoteTabListPayload(
            tabs: [
                RemoteTabDescriptor(
                    tabID: 1,
                    title: title,
                    isActive: true,
                    isMCPControlled: false
                )
            ],
            capabilities: [RemoteTabListPayload.keyInputCapability],
            terminalColorScheme: colorScheme
        )
    }
}

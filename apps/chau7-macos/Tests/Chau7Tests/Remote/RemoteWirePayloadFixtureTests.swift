import XCTest
@testable import Chau7Core

/// Golden-fixture round-trip tests for the shared wire payloads.
///
/// The fixtures under `services/chau7-remote/docs/fixtures/` are the
/// language-neutral contract: this suite proves the Swift types decode them
/// and re-encode without loss, and `internal/agent/fixtures_test.go` proves
/// the same for the Go mirrors. A payload change that breaks either side
/// fails one of the two suites instead of shipping silent drift.
final class RemoteWirePayloadFixtureTests: XCTestCase {

    private static let fixturesURL = // <repo>/apps/chau7-macos/Tests/Chau7Tests/Remote/ThisFile.swift → <repo>
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ThisFile.swift
        .deletingLastPathComponent() // Remote
        .deletingLastPathComponent() // Chau7Tests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // chau7-macos
        .deletingLastPathComponent() // apps
        .appendingPathComponent("services/chau7-remote/docs/fixtures")

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesURL.appendingPathComponent(name))
    }

    /// Decode → encode → decode; assert value equality and semantic JSON
    /// equality with the fixture (key order ignored, absent optionals stay
    /// absent).
    private func assertRoundTrip<T: Codable & Equatable>(
        _ type: T.Type,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try fixtureData(fixture)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let decoded = try decoder.decode(T.self, from: data)
        let reencoded = try encoder.encode(decoded)
        let redecoded = try decoder.decode(T.self, from: reencoded)
        XCTAssertEqual(decoded, redecoded, "value round-trip drifted for \(fixture)", file: file, line: line)

        let originalObject = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        XCTAssertEqual(
            reencodedObject, originalObject,
            "JSON round-trip drifted for \(fixture)", file: file, line: line
        )
    }

    func testApprovalRequestFixture() throws {
        try assertRoundTrip(ApprovalRequestPayload.self, fixture: "approval_request.json")
    }

    func testApprovalResponseFixture() throws {
        try assertRoundTrip(ApprovalResponsePayload.self, fixture: "approval_response.json")
    }

    func testClientStateFixture() throws {
        try assertRoundTrip(RemoteClientStatePayload.self, fixture: "client_state.json")
    }

    func testTabListFixture() throws {
        try assertRoundTrip(RemoteTabListPayload.self, fixture: "tab_list.json")
    }

    func testTabSwitchFixture() throws {
        try assertRoundTrip(RemoteTabSwitchPayload.self, fixture: "tab_switch.json")
    }

    func testPendingStateFixture() throws {
        try assertRoundTrip(RemotePendingStatePayload.self, fixture: "pending_state.json")
    }

    func testRemoteErrorFixture() throws {
        try assertRoundTrip(RemoteErrorPayload.self, fixture: "remote_error.json")
    }

    func testHelloFixture() throws {
        try assertRoundTrip(RemoteHelloPayload.self, fixture: "hello.json")
    }

    func testPairRequestFixture() throws {
        try assertRoundTrip(RemotePairRequestPayload.self, fixture: "pair_request.json")
    }

    func testPairAcceptFixture() throws {
        try assertRoundTrip(RemotePairAcceptPayload.self, fixture: "pair_accept.json")
    }

    func testSessionReadyFixture() throws {
        try assertRoundTrip(RemoteSessionReadyPayload.self, fixture: "session_ready.json")
    }

    func testPairingInfoFixture() throws {
        try assertRoundTrip(RemotePairingPayload.self, fixture: "pairing_info.json")
    }

    func testNotificationEventFixture() throws {
        try assertRoundTrip(RemoteNotificationEventPayload.self, fixture: "notification_event.json")
    }

    // MARK: - Interop leniency

    func testApprovalRequestDecodesWithoutTimestamp() throws {
        // The Go agent's /pending re-encode historically omitted `timestamp`;
        // the shared type must stay decode-tolerant so a pending snapshot with
        // approvals never fails wholesale.
        let json = #"{"request_id":"r","command":"c","flagged_command":"c"}"#
        let payload = try JSONDecoder().decode(ApprovalRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.timestamp, "")
        XCTAssertEqual(payload.requestID, "r")
    }

    func testTabDescriptorDecodesWithoutMCPFlag() throws {
        let json = #"{"tab_id":1,"title":"t","is_active":true}"#
        let tab = try JSONDecoder().decode(RemoteTabDescriptor.self, from: Data(json.utf8))
        XCTAssertFalse(tab.isMCPControlled)
    }
}

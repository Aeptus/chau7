import XCTest
import Chau7Core
@testable import Chau7

final class RemoteRelayCredentialsTests: XCTestCase {
    private func credentials(deviceID: String = "device-a") -> RemoteRelayCredentials {
        RemoteRelayCredentials(
            deviceID: deviceID,
            keyID: "key-a",
            macSecret: Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            iosSecret: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        )
    }

    func testOwnerOnlyBundleLoadsAndSignsMacIssueRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("credentials.json")
        try JSONEncoder().encode(credentials()).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let loaded = try RemoteRelayCredentials.load(from: url, deviceID: "device-a")
        XCTAssertEqual(loaded, credentials())
        let token = try XCTUnwrap(RelayToken.make(deviceID: loaded.deviceID, keyID: loaded.keyID, secret: loaded.macSecret, role: "mac", scope: "issues"))
        XCTAssertTrue(token.hasPrefix("v3.key-a."))
        XCTAssertThrowsError(try RemoteRelayCredentials.load(from: url, deviceID: "device-b"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try RemoteRelayCredentials.load(from: url, deviceID: "device-a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try RemoteRelayCredentials.load(from: link, deviceID: "device-a"))
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try RemoteRelayCredentials.load(from: url, deviceID: "device-a"))
    }

    func testInvalidBundleFailsClosedWithoutSharedOrWeakKeys() {
        let valid = credentials()
        XCTAssertFalse(valid.isValid(for: "device-b"))
        XCTAssertFalse(RemoteRelayCredentials(deviceID: "device-a", keyID: "key-a", macSecret: valid.macSecret, iosSecret: valid.macSecret).isValid(for: "device-a"))
        XCTAssertFalse(RemoteRelayCredentials(deviceID: "device-a", keyID: "key-a", macSecret: "weak", iosSecret: valid.iosSecret).isValid(for: "device-a"))
    }
}

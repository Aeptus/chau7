import XCTest
import Chau7Core

final class MCPProtocolCompatibilityTests: XCTestCase {
    func testSupportedVersionsAreOrderedNewestFirst() {
        XCTAssertEqual(
            MCPProtocolCompatibility.supportedVersions,
            ["2025-11-25", "2025-06-18", "2024-11-05"]
        )
        XCTAssertEqual(MCPProtocolCompatibility.preferredVersion, "2025-11-25")
    }

    func testNegotiationEchoesEverySupportedRevision() {
        for version in MCPProtocolCompatibility.supportedVersions {
            XCTAssertEqual(MCPProtocolCompatibility.negotiate(requestedVersion: version), version)
        }
    }

    func testNegotiationRejectsUnknownRevision() {
        XCTAssertNil(MCPProtocolCompatibility.negotiate(requestedVersion: "2023-01-01"))
    }
}

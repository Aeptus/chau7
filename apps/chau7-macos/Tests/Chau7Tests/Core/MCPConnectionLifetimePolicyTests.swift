import XCTest
@testable import Chau7Core

final class MCPConnectionLifetimePolicyTests: XCTestCase {
    func testInitializedConnectionsHaveNoServerIdleReadTimeout() {
        XCTAssertNil(MCPConnectionLifetimePolicy.receiveTimeoutSeconds)
        XCTAssertEqual(MCPConnectionLifetimePolicy.sendTimeoutSeconds, 30)
    }
}

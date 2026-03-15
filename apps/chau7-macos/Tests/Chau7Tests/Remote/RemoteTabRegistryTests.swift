import XCTest
@testable import Chau7

final class RemoteTabRegistryTests: XCTestCase {
    func testRebuildPreservesExistingTabIDsAndBuildsSessionLookup() throws {
        let firstID = UUID()
        let secondID = UUID()
        var registry = RemoteTabRegistry()

        _ = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: firstID,
                    sessionIdentifier: "session-a",
                    title: "A",
                    isActive: true,
                    isMCPControlled: false
                ),
                RemoteTabRegistryEntry(
                    id: secondID,
                    sessionIdentifier: "session-b",
                    title: "B",
                    isActive: false,
                    isMCPControlled: true
                )
            ]
        )

        let firstTabID = try XCTUnwrap(registry.tabID(for: firstID))
        let secondTabID = try XCTUnwrap(registry.tabID(for: secondID))

        let rebuilt = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: secondID,
                    sessionIdentifier: "session-b",
                    title: "B2",
                    isActive: true,
                    isMCPControlled: true
                ),
                RemoteTabRegistryEntry(
                    id: firstID,
                    sessionIdentifier: "session-a",
                    title: "A2",
                    isActive: false,
                    isMCPControlled: false
                )
            ]
        )

        XCTAssertEqual(registry.tabID(for: firstID), firstTabID)
        XCTAssertEqual(registry.tabID(for: secondID), secondTabID)
        XCTAssertEqual(registry.tabID(forSessionIdentifier: "session-a"), firstTabID)
        XCTAssertEqual(registry.uuid(for: secondTabID), secondID)
        XCTAssertEqual(rebuilt.map(\.tabID), [secondTabID, firstTabID])
    }

    func testBackgroundTabIDsExcludeSelectedTab() throws {
        let firstID = UUID()
        let secondID = UUID()
        var registry = RemoteTabRegistry()
        _ = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: firstID,
                    sessionIdentifier: "session-a",
                    title: "A",
                    isActive: true,
                    isMCPControlled: false
                ),
                RemoteTabRegistryEntry(
                    id: secondID,
                    sessionIdentifier: "session-b",
                    title: "B",
                    isActive: false,
                    isMCPControlled: false
                )
            ]
        )

        let background = registry.backgroundTabIDs(for: [firstID, secondID], selectedTabID: firstID)

        XCTAssertEqual(background, [try XCTUnwrap(registry.tabID(for: secondID))])
    }
}

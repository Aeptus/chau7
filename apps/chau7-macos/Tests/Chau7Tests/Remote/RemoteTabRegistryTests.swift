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
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: true,
                    isMCPControlled: false
                ),
                RemoteTabRegistryEntry(
                    id: secondID,
                    sessionIdentifier: "session-b",
                    title: "B",
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
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
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: true,
                    isMCPControlled: true
                ),
                RemoteTabRegistryEntry(
                    id: firstID,
                    sessionIdentifier: "session-a",
                    title: "A2",
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: false,
                    isMCPControlled: false
                )
            ]
        )

        XCTAssertEqual(registry.tabID(for: firstID), firstTabID)
        XCTAssertEqual(registry.tabID(for: secondID), secondTabID)
        XCTAssertEqual(registry.tabID(forSessionIdentifier: "session-a"), firstTabID)
        XCTAssertEqual(registry.uuid(for: secondTabID), secondID)
        XCTAssertEqual(rebuilt.map { $0.tabID }, [secondTabID, firstTabID])
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
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: true,
                    isMCPControlled: false
                ),
                RemoteTabRegistryEntry(
                    id: secondID,
                    sessionIdentifier: "session-b",
                    title: "B",
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: false,
                    isMCPControlled: false
                )
            ]
        )

        let background = registry.backgroundTabIDs(for: [firstID, secondID], selectedTabID: firstID)

        XCTAssertEqual(background, try [XCTUnwrap(registry.tabID(for: secondID))])
    }

    func testRebuildCarriesAIProviderAndMetadataIntoDescriptors() throws {
        var registry = RemoteTabRegistry()
        let descriptors = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: UUID(),
                    sessionIdentifier: "session-a",
                    title: "Build",
                    projectName: "chau7",
                    branchName: "main",
                    aiProvider: "Claude",
                    isActive: true,
                    isMCPControlled: false
                )
            ]
        )

        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.projectName, "chau7")
        XCTAssertEqual(descriptor.branchName, "main")
        XCTAssertEqual(descriptor.aiProvider, "Claude")
        XCTAssertTrue(descriptor.isActive)
    }

    func testTabDescriptorAIProviderRoundTripsThroughJSON() throws {
        let descriptor = RemoteTabDescriptor(
            tabID: 7,
            title: "Codex",
            projectName: "chau7",
            branchName: "feature",
            aiProvider: "Codex",
            isActive: false,
            isMCPControlled: true
        )

        let data = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"ai_provider\":\"Codex\""))

        let decoded = try JSONDecoder().decode(RemoteTabDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor)
    }
}

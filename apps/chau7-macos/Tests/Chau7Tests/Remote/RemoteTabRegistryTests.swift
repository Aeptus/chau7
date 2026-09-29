import XCTest
@testable import Chau7
import Chau7Core

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

    func testTerminalSizeIsNotCarriedOnTheTabDescriptor() throws {
        // Width deliberately moved to the tab-scoped TERMINAL_SIZE frame: it is a
        // rendering concern, and a window resize changes it without any tab
        // appearing or disappearing.
        let uuid = UUID()
        var registry = RemoteTabRegistry()
        let descriptors = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: uuid,
                    sessionIdentifier: nil,
                    title: "Claude",
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: true,
                    isMCPControlled: false
                )
            ]
        )
        let descriptor = try XCTUnwrap(descriptors.first)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(descriptor), encoding: .utf8))
        XCTAssertFalse(
            json.contains("terminal_cols"),
            "terminal size must not ride on the inventory; it would only update incidentally"
        )
    }

    func testTerminalSizePayloadRoundTripsThroughJSON() throws {
        let payload = RemoteTerminalSizePayload(cols: 120, rows: 40)
        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("\"cols\":120"))
        XCTAssertTrue(json.contains("\"rows\":40"))
        let decoded = try JSONDecoder().decode(RemoteTerminalSizePayload.self, from: encoded)
        XCTAssertEqual(decoded, payload)
    }

    func testOlderMacInventoryWithoutDimensionsStillDecodes() throws {
        // Backward compatibility: a peer predating the field — and a peer that
        // still sends the old keys, which are now ignored — must both decode.
        let legacy = """
        {"tab_id":3,"title":"legacy","is_active":true}
        """
        let descriptor = try JSONDecoder().decode(RemoteTabDescriptor.self, from: Data(legacy.utf8))
        XCTAssertEqual(descriptor.tabID, 3)
        XCTAssertEqual(descriptor.title, "legacy")

        // A Mac still emitting the old inventory keys must not break the client.
        let stale = """
        {"tab_id":4,"title":"old-shape","is_active":true,"terminal_cols":120,"terminal_rows":40}
        """
        let staleDescriptor = try JSONDecoder().decode(RemoteTabDescriptor.self, from: Data(stale.utf8))
        XCTAssertEqual(staleDescriptor.tabID, 4, "unknown inventory keys must be ignored, not fatal")
    }
}

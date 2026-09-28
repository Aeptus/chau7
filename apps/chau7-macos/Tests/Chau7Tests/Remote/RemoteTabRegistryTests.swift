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

    func testTerminalDimensionsAreAdvertisedOnTheDescriptor() throws {
        let uuid = UUID()
        var registry = RemoteTabRegistry()
        var entry = RemoteTabRegistryEntry(
            id: uuid,
            sessionIdentifier: nil,
            title: "Claude",
            projectName: nil,
            branchName: nil,
            aiProvider: nil,
            isActive: true,
            isMCPControlled: false
        )
        entry.terminalCols = 120
        entry.terminalRows = 40

        let descriptors = registry.rebuild(with: [entry])
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.terminalCols, 120)
        XCTAssertEqual(descriptor.terminalRows, 40)

        // The client sizes its own emulator to this width, so it has to
        // survive the wire as the snake_case key the protocol documents.
        let encoded = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("\"terminal_cols\":120"))
        let decoded = try JSONDecoder().decode(RemoteTabDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, descriptor)
    }

    func testUnlaidOutTerminalAdvertisesNoDimensions() throws {
        // A tab with no attached view reports 0, which must be sent as absent
        // rather than 0 — a zero-width engine would ingest nothing.
        let uuid = UUID()
        var registry = RemoteTabRegistry()
        let descriptors = registry.rebuild(
            with: [
                RemoteTabRegistryEntry(
                    id: uuid,
                    sessionIdentifier: nil,
                    title: "Empty",
                    projectName: nil,
                    branchName: nil,
                    aiProvider: nil,
                    isActive: true,
                    isMCPControlled: false
                )
            ]
        )
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertNil(descriptor.terminalCols)
        XCTAssertNil(descriptor.terminalRows)
    }

    func testOlderMacWithoutDimensionsStillDecodes() throws {
        // Backward compatibility: a peer that predates the field must still be
        // readable, and the client falls back to its own viewport width.
        let json = """
        {"tab_id":3,"title":"legacy","is_active":true}
        """
        let descriptor = try JSONDecoder().decode(RemoteTabDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(descriptor.tabID, 3)
        XCTAssertNil(descriptor.terminalCols)
        XCTAssertNil(descriptor.terminalRows)
    }
}

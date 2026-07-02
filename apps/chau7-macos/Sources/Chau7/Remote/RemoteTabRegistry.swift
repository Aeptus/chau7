import Chau7Core
import Foundation

struct RemoteTabRegistryEntry {
    let id: UUID
    let sessionIdentifier: String?
    let title: String
    let projectName: String?
    let branchName: String?
    let aiProvider: String?
    let isActive: Bool
    let isMCPControlled: Bool
}

struct RemoteTabRegistry {
    /// Sentinel tabID in remote IPC payloads meaning "not scoped to a
    /// specific registry entry". On the request side (snapshots,
    /// switches), it resolves to the currently-selected tab. On the
    /// send side (approval requests, activity broadcasts, tab list
    /// frames), it marks the frame as non-tab-scoped. Using the named
    /// constant keeps the protocol contract obvious at call sites.
    static let unscopedTabID: UInt32 = 0

    private(set) var tabIDByUUID: [UUID: UInt32] = [:]
    private(set) var uuidByTabID: [UInt32: UUID] = [:]
    private(set) var tabIDBySessionIdentifier: [String: UInt32] = [:]
    private var nextTabID: UInt32 = 1

    mutating func rebuild(with entries: [RemoteTabRegistryEntry]) -> [RemoteTabDescriptor] {
        var newTabIDByUUID: [UUID: UInt32] = [:]
        var newUUIDByTabID: [UInt32: UUID] = [:]
        var newTabIDBySession: [String: UInt32] = [:]
        var descriptors: [RemoteTabDescriptor] = []

        for entry in entries {
            let tabID = tabIDByUUID[entry.id] ?? nextTabID
            if tabIDByUUID[entry.id] == nil {
                nextTabID = nextTabID &+ 1
            }

            newTabIDByUUID[entry.id] = tabID
            newUUIDByTabID[tabID] = entry.id
            if let sessionIdentifier = entry.sessionIdentifier {
                newTabIDBySession[sessionIdentifier] = tabID
            }

            descriptors.append(
                RemoteTabDescriptor(
                    tabID: tabID,
                    title: entry.title,
                    projectName: entry.projectName,
                    branchName: entry.branchName,
                    aiProvider: entry.aiProvider,
                    isActive: entry.isActive,
                    isMCPControlled: entry.isMCPControlled
                )
            )
        }

        tabIDByUUID = newTabIDByUUID
        uuidByTabID = newUUIDByTabID
        tabIDBySessionIdentifier = newTabIDBySession
        return descriptors
    }

    func tabID(for uuid: UUID) -> UInt32? {
        tabIDByUUID[uuid]
    }

    func uuid(for tabID: UInt32) -> UUID? {
        uuidByTabID[tabID]
    }

    func tabID(forSessionIdentifier sessionIdentifier: String) -> UInt32? {
        tabIDBySessionIdentifier[sessionIdentifier]
    }

    func backgroundTabIDs(for tabIDs: [UUID], selectedTabID: UUID) -> [UInt32] {
        tabIDs.compactMap { tabIDByUUID[$0] }.filter { tabIDByUUID[selectedTabID] != $0 }
    }
}

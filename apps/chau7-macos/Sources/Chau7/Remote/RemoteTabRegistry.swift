import Foundation

struct RemoteTabRegistryEntry {
    let id: UUID
    let sessionIdentifier: String?
    let title: String
    let isActive: Bool
    let isMCPControlled: Bool
}

struct RemoteTabRegistry {
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

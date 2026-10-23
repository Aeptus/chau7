import Foundation

/// Allocates deterministic control-plane tab aliases (`tab_1`, `tab_2`, ...)
/// for otherwise random overlay tab UUIDs. Slots are recycled when tabs close.
public struct MCPTabIDAllocator {
    private var slotByTabID: [UUID: Int] = [:]
    private var tabIDBySlot: [Int: UUID] = [:]

    public init() {}

    public mutating func assignID(for tabID: UUID) -> String {
        if let slot = slotByTabID[tabID] {
            return Self.alias(for: slot)
        }

        let slot = nextAvailableSlot()
        slotByTabID[tabID] = slot
        tabIDBySlot[slot] = tabID
        return Self.alias(for: slot)
    }

    public func id(for tabID: UUID) -> String? {
        guard let slot = slotByTabID[tabID] else { return nil }
        return Self.alias(for: slot)
    }

    public func nativeTabID(for controlPlaneID: String) -> UUID? {
        guard let slot = Self.slot(from: controlPlaneID) else { return nil }
        return tabIDBySlot[slot]
    }

    public mutating func release(tabID: UUID) {
        guard let slot = slotByTabID.removeValue(forKey: tabID) else { return }
        tabIDBySlot.removeValue(forKey: slot)
    }

    public mutating func prune(validTabIDs: Set<UUID>) {
        for tabID in slotByTabID.keys where !validTabIDs.contains(tabID) {
            release(tabID: tabID)
        }
    }

    public static func isControlPlaneID(_ value: String) -> Bool {
        slot(from: value) != nil
    }

    private func nextAvailableSlot() -> Int {
        var candidate = 1
        while tabIDBySlot[candidate] != nil {
            candidate += 1
        }
        return candidate
    }

    private static func alias(for slot: Int) -> String {
        "tab_\(slot)"
    }

    private static func slot(from value: String) -> Int? {
        guard value.hasPrefix("tab_") else { return nil }
        let suffix = value.dropFirst(4)
        guard let slot = Int(suffix), slot > 0 else { return nil }
        return slot
    }
}

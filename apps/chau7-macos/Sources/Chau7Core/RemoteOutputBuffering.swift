import Foundation

public enum RemoteOutputTuning {
    public static let maxRetainedBytes = 200_000
    public static let maxIncomingFrameBytes = 65_536
    public static let maxPendingBytesPerTab = 32_768
    public static let flushInterval = Duration.milliseconds(33)

    public static func trimRetainedText(_ input: String) -> String {
        guard input.utf8.count > maxRetainedBytes else { return input }
        return String(decoding: Data(input.utf8.suffix(maxRetainedBytes)), as: UTF8.self)
    }

    public static func capSnapshot(_ data: Data) -> Data {
        Data(data.suffix(maxRetainedBytes))
    }

    public static func capIncomingFrame(_ data: Data) -> Data {
        Data(data.prefix(maxIncomingFrameBytes))
    }
}

public struct RemotePendingOutputBuffer<Chunk> {
    private var pendingByTabID: [UInt32: Chunk] = [:]

    public init() {}

    public var isEmpty: Bool {
        pendingByTabID.isEmpty
    }

    public var tabIDs: [UInt32] {
        Array(pendingByTabID.keys)
    }

    public subscript(tabID: UInt32) -> Chunk? {
        pendingByTabID[tabID]
    }

    public mutating func append(
        _ chunk: Chunk,
        to tabID: UInt32,
        merging: (inout Chunk, Chunk) -> Void
    ) {
        if var existing = pendingByTabID[tabID] {
            merging(&existing, chunk)
            pendingByTabID[tabID] = existing
        } else {
            pendingByTabID[tabID] = chunk
        }
    }

    @discardableResult
    public mutating func drain(tabID: UInt32) -> Chunk? {
        pendingByTabID.removeValue(forKey: tabID)
    }

    public mutating func drainAll(sortedByTabID: Bool = false) -> [(UInt32, Chunk)] {
        let drained: [(UInt32, Chunk)]
        if sortedByTabID {
            drained = pendingByTabID.sorted(by: { $0.key < $1.key })
        } else {
            drained = Array(pendingByTabID)
        }
        pendingByTabID.removeAll(keepingCapacity: true)
        return drained
    }

    public mutating func retain(only tabIDs: Set<UInt32>) {
        pendingByTabID = pendingByTabID.filter { tabIDs.contains($0.key) }
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        pendingByTabID.removeAll(keepingCapacity: keepingCapacity)
    }
}

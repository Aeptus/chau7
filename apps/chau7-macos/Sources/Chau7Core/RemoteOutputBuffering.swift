import Foundation

public enum RemoteOutputTuning {
    public static let maxRetainedBytes = 200_000
    public static let maxIncomingFrameBytes = 65536
    public static let maxPendingBytesPerTab = 16384
    /// The PTY ingestion side coalesces tiny reads for at most half of a 120 Hz
    /// display frame before handing them to the protocol sender.
    public static let sourceMicroBatchIntervalSeconds: TimeInterval = 0.004
    /// Tiny sender-side batching amortizes IPC/WebSocket overhead without
    /// adding a perceptible terminal delay.
    public static let senderMicroBatchInterval = Duration.milliseconds(4)
    /// Plain-text fallback publication is frame paced rather than tied to the
    /// sender's transport cadence.
    public static let plainTextPublishInterval = Duration.milliseconds(16)
    /// Full terminal grids are coalesced and capped at roughly 15 FPS.
    public static let gridSnapshotInterval = Duration.milliseconds(67)

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

public enum RemoteTerminalStreamingPolicy {
    /// Missing presentation means an older client. Preserve the historical
    /// dual stream until that client upgrades.
    public static func sendsOutputFrames(for presentation: RemoteTerminalPresentation?) -> Bool {
        presentation != .grid
    }

    public static func sendsTextSnapshots(for presentation: RemoteTerminalPresentation?) -> Bool {
        presentation != .grid
    }

    public static func sendsGridSnapshots(for presentation: RemoteTerminalPresentation?) -> Bool {
        presentation == nil || presentation == .grid
    }

    /// Only an older client expects a grid after every text-output batch.
    /// Current replay/text clients use snapshots solely as initial/recovery
    /// checkpoints, while grid clients are driven by their own invalidations.
    public static func sendsGridCheckpointAfterOutput(for presentation: RemoteTerminalPresentation?) -> Bool {
        presentation == nil
    }
}

/// Optional metadata prepended to negotiated OUTPUT frames. The frame flag is
/// authoritative, so ordinary terminal bytes can never be mistaken for this
/// envelope merely because they happen to begin with the same magic bytes.
public struct RemoteTimedOutputChunk: Equatable, Sendable {
    public static let encodedHeaderSize = 24
    private static let magic = Data([0x43, 0x48, 0x37, 0x4F]) // "CH7O"

    public let firstCapturedAtMicroseconds: UInt64
    public let sentAtMicroseconds: UInt64
    public let bytes: Data

    public init(firstCapturedAtMicroseconds: UInt64, sentAtMicroseconds: UInt64, bytes: Data) {
        self.firstCapturedAtMicroseconds = firstCapturedAtMicroseconds
        self.sentAtMicroseconds = sentAtMicroseconds
        self.bytes = bytes
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.encodedHeaderSize + bytes.count)
        data.append(Self.magic)
        data.append(1) // version
        data.append(contentsOf: [0, 0, 0])
        data.appendUInt64LE(firstCapturedAtMicroseconds)
        data.appendUInt64LE(sentAtMicroseconds)
        data.append(bytes)
        return data
    }

    public static func decode(from data: Data) -> Self? {
        guard data.count >= encodedHeaderSize,
              data.prefix(magic.count) == magic,
              data[4] == 1,
              let captured = try? data.readUInt64LE(at: 8),
              let sent = try? data.readUInt64LE(at: 16),
              captured <= sent
        else { return nil }
        return Self(
            firstCapturedAtMicroseconds: captured,
            sentAtMicroseconds: sent,
            bytes: Data(data.dropFirst(encodedHeaderSize))
        )
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

import Foundation

/// Tells the relay how much this phone has taken in.
///
/// The relay cannot see its own send queue, so it cannot tell a phone on a
/// slow link from one that is keeping up. The phone therefore reports a
/// running total of the bytes it has received and finished with; the relay
/// compares that with what it sent and sheds replaceable screen frames, or
/// drops the connection, for a phone that is far behind.
public struct RelayReceiveAcknowledger: Sendable {
    /// Report after this many more bytes. Coarse on purpose: the relay acts in
    /// megabytes, and a report per frame would double the traffic of typing.
    public static let byteInterval: UInt64 = 256 * 1024

    public private(set) var received: UInt64 = 0
    public private(set) var acknowledged: UInt64 = 0

    public init() {}

    public mutating func noteReceived(bytes: Int) {
        received += UInt64(max(0, bytes))
    }

    /// The total to report now, or nil when too little has changed.
    /// `queuedBytes` are received but not yet applied, so not yet taken in.
    public mutating func totalToAcknowledge(queuedBytes: Int) -> UInt64? {
        let queued = UInt64(max(0, queuedBytes))
        let takenIn = received > queued ? received - queued : 0
        guard takenIn >= acknowledged + Self.byteInterval else { return nil }
        acknowledged = takenIn
        return takenIn
    }

    /// The `RELAY_ACK` frame: a header and the total as 8 little-endian bytes.
    public static func frame(total: UInt64) -> Data {
        var payload = Data(capacity: 8)
        payload.appendUInt64LE(total)
        return RemoteFrame(type: RemoteFrameType.relayAck.rawValue, tabID: 0, seq: 0, payload: payload).encode()
    }
}

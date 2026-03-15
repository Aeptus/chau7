import Foundation

public enum RemoteFrameError: Error, Sendable {
    case insufficientData
    case invalidLength
    case unsupportedVersion(UInt8)
}

extension RemoteFrameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "Insufficient data to decode remote frame"
        case .invalidLength:
            return "Remote frame payload length does not match available data"
        case .unsupportedVersion(let v):
            return "Unsupported remote frame version: \(v)"
        }
    }
}

public struct RemoteFrame: Equatable, Sendable {
    public static let headerSize = 20
    public static let flagEncrypted: UInt8 = 0x01

    public let version: UInt8
    public let type: UInt8
    public let flags: UInt8
    public let reserved: UInt8
    public let tabID: UInt32
    public let seq: UInt64
    public let payload: Data

    public init(
        version: UInt8 = 1,
        type: UInt8,
        flags: UInt8 = 0,
        reserved: UInt8 = 0,
        tabID: UInt32,
        seq: UInt64,
        payload: Data
    ) {
        self.version = version
        self.type = type
        self.flags = flags
        self.reserved = reserved
        self.tabID = tabID
        self.seq = seq
        self.payload = payload
    }

    /// Typed frame type accessor.
    public var frameType: RemoteFrameType? {
        RemoteFrameType(rawValue: type)
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(version)
        data.append(type)
        data.append(flags)
        data.append(reserved)
        data.appendUInt32LE(tabID)
        data.appendUInt64LE(seq)
        data.appendUInt32LE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public func headerBytes(payloadLen: UInt32) -> Data {
        var data = Data(capacity: Self.headerSize)
        data.append(version)
        data.append(type)
        data.append(flags)
        data.append(reserved)
        data.appendUInt32LE(tabID)
        data.appendUInt64LE(seq)
        data.appendUInt32LE(payloadLen)
        return data
    }

    public static func decode(from data: Data) throws -> RemoteFrame {
        guard data.count >= headerSize else {
            throw RemoteFrameError.insufficientData
        }

        let version = data[0]
        guard version == 1 else {
            throw RemoteFrameError.unsupportedVersion(version)
        }

        let type = data[1]
        let flags = data[2]
        let reserved = data[3]
        let tabID = try data.readUInt32LE(at: 4)
        let seq = try data.readUInt64LE(at: 8)
        let payloadLen = try Int(data.readUInt32LE(at: 16))

        let expectedSize = headerSize + payloadLen
        guard data.count >= expectedSize else {
            throw RemoteFrameError.invalidLength
        }

        let payload = data.subdata(in: headerSize ..< expectedSize)
        return RemoteFrame(
            version: version,
            type: type,
            flags: flags,
            reserved: reserved,
            tabID: tabID,
            seq: seq,
            payload: payload
        )
    }
}

public enum RemoteFrameType: UInt8, CaseIterable, Sendable {
    case hello = 0x01
    case pairRequest = 0x02
    case pairAccept = 0x03
    case pairReject = 0x04
    case sessionReady = 0x05
    case pairingInfo = 0x40
    case sessionStatus = 0x41
    case remoteTelemetry = 0x42
    case tabList = 0x10
    case tabSwitch = 0x11
    case activityState = 0x12
    case activityCleared = 0x13
    case cachedTabList = 0x14
    case output = 0x20
    case input = 0x21
    case snapshot = 0x22
    case approvalRequest = 0x50
    case approvalResponse = 0x51
    case ping = 0x30
    case pong = 0x31
    case error = 0x7F
}

extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 56))
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard count >= offset + 4 else { throw RemoteFrameError.insufficientData }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func readUInt64LE(at offset: Int) throws -> UInt64 {
        guard count >= offset + 8 else { throw RemoteFrameError.insufficientData }
        let b0 = UInt64(self[offset])
        let b1 = UInt64(self[offset + 1]) << 8
        let b2 = UInt64(self[offset + 2]) << 16
        let b3 = UInt64(self[offset + 3]) << 24
        let b4 = UInt64(self[offset + 4]) << 32
        let b5 = UInt64(self[offset + 5]) << 40
        let b6 = UInt64(self[offset + 6]) << 48
        let b7 = UInt64(self[offset + 7]) << 56
        return b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7
    }
}

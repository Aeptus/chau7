import Foundation

/// Little-endian byte codec helpers shared by every wire-format type in
/// `Chau7Core` (`RemoteFrame`, `RemoteTerminalGridSnapshot`, and any
/// future binary protocol). Prior to consolidation, `appendUInt16LE` /
/// `appendUInt32LE` / `readUInt32LE` / `readUInt64LE` lived in two
/// files with near-identical bounds-check patterns — three implementations
/// of the same byte shuffle and three chances to get the upper-bound
/// check off-by-one.
///
/// All reads throw `RemoteFrameError.insufficientData` when the buffer
/// is too short, matching the historical contract of
/// `RemoteFrame.swift`'s decoders.
extension Data {

    // MARK: - Append (little-endian)

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

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

    // MARK: - Read (little-endian)

    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard count >= offset + 2 else { throw RemoteFrameError.insufficientData }
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1]) << 8
        return b0 | b1
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

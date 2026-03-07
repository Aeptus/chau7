import Foundation

public enum FrameParsingError: Error, Equatable, Sendable {
    case invalidFrameLength(Int)
}

extension FrameParsingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let len):
            return "Invalid frame length: \(len)"
        }
    }
}

public enum FrameParser {
    public static let defaultMaxFrameSize = 5 * 1024 * 1024
    public static let lengthPrefixSize = 4

    /// Parse length-prefixed frames from a buffer, modifying it in-place.
    ///
    /// On invalid frame length (zero or exceeding max): skips the 4-byte length prefix
    /// and continues parsing. On decode failure: collects the error and continues
    /// parsing subsequent frames.
    public static func parseFrames(
        from buffer: inout Data,
        maxFrameSize: Int = defaultMaxFrameSize
    ) -> (frames: [RemoteFrame], errors: [Error]) {
        var frames: [RemoteFrame] = []
        var errors: [Error] = []

        while buffer.count >= lengthPrefixSize {
            guard let frameLen = try? Int(buffer.readUInt32LE(at: 0)) else {
                buffer.removeSubrange(0 ..< lengthPrefixSize)
                continue
            }

            if frameLen <= 0 || frameLen > maxFrameSize {
                errors.append(FrameParsingError.invalidFrameLength(frameLen))
                buffer.removeSubrange(0 ..< lengthPrefixSize)
                continue
            }

            let totalNeeded = lengthPrefixSize + frameLen
            guard buffer.count >= totalNeeded else { break }

            let frameData = buffer.subdata(in: lengthPrefixSize ..< totalNeeded)
            buffer.removeSubrange(0 ..< totalNeeded)

            do {
                let frame = try RemoteFrame.decode(from: frameData)
                frames.append(frame)
            } catch {
                errors.append(error)
            }
        }

        return (frames, errors)
    }

    /// Encode a RemoteFrame with a 4-byte little-endian length prefix for transport.
    public static func packForTransport(_ frame: RemoteFrame) -> Data {
        let encoded = frame.encode()
        var data = Data(capacity: lengthPrefixSize + encoded.count)
        data.appendUInt32LE(UInt32(encoded.count))
        data.append(encoded)
        return data
    }
}

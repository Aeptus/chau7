import Foundation

public struct TerminalOSC9Parser {
    public enum Event: Equatable {
        case chau7(key: String, value: String)
        case foreign(message: String)
    }

    private static let osc9Prefix: [UInt8] = [0x1B, 0x5D, 0x39, 0x3B]
    private static let chau7Prefix = Array("chau7;".utf8)
    private static let belTerminator: UInt8 = 0x07
    private static let maxBufferedBytes = 65_536

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func ingest(_ data: Data) -> [Event] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)

        var events: [Event] = []
        while let prefixStart = firstPrefixStart(in: buffer) {
            if prefixStart > 0 {
                buffer.removeFirst(prefixStart)
            }

            let payloadStart = Self.osc9Prefix.count
            guard let terminator = firstTerminator(in: buffer, startingAt: payloadStart) else {
                trimOversizedIncompleteBuffer()
                break
            }

            let payloadBytes = Array(buffer[payloadStart ..< terminator.payloadEnd])
            if let event = Self.event(fromPayload: payloadBytes) {
                events.append(event)
            }

            buffer.removeFirst(terminator.consumeEnd)
        }

        if firstPrefixStart(in: buffer) == nil {
            retainPotentialPrefixSuffix()
        }
        return events
    }

    private struct Terminator {
        let payloadEnd: Int
        let consumeEnd: Int
    }

    private func firstPrefixStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= Self.osc9Prefix.count else { return nil }
        return bytes.indices.dropLast(Self.osc9Prefix.count - 1).first { index in
            bytes[index ..< index + Self.osc9Prefix.count].elementsEqual(Self.osc9Prefix)
        }
    }

    private func firstTerminator(in bytes: [UInt8], startingAt start: Int) -> Terminator? {
        var index = start
        while index < bytes.count {
            if bytes[index] == Self.belTerminator {
                return Terminator(payloadEnd: index, consumeEnd: index + 1)
            }
            if bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == 0x5C {
                return Terminator(payloadEnd: index, consumeEnd: index + 2)
            }
            index += 1
        }
        return nil
    }

    private static func event(fromPayload payloadBytes: [UInt8]) -> Event? {
        guard let payload = String(bytes: payloadBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !payload.isEmpty else {
            return nil
        }

        guard payloadBytes.starts(with: chau7Prefix) else {
            return .foreign(message: payload)
        }

        let body = String(payload.dropFirst("chau7;".count))
        guard let separator = body.firstIndex(of: "=") else { return nil }
        let key = String(body[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return .chau7(key: String(key), value: String(value))
    }

    private mutating func retainPotentialPrefixSuffix() {
        let suffixLength = potentialPrefixSuffixLength(in: buffer)
        if suffixLength == 0 {
            buffer.removeAll(keepingCapacity: true)
        } else if buffer.count > suffixLength {
            buffer = Array(buffer.suffix(suffixLength))
        }
    }

    private mutating func trimOversizedIncompleteBuffer() {
        guard buffer.count > Self.maxBufferedBytes else { return }
        retainPotentialPrefixSuffix()
    }

    private func potentialPrefixSuffixLength(in bytes: [UInt8]) -> Int {
        let maxLength = min(bytes.count, Self.osc9Prefix.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if bytes.suffix(length).elementsEqual(Self.osc9Prefix.prefix(length)) {
                return length
            }
        }
        return 0
    }
}

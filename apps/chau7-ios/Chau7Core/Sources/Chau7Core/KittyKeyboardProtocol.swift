import Foundation

/// Kitty progressive keyboard enhancement protocol implementation.
/// See: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
///
/// Programs request keyboard modes via: CSI > flags u
/// Programs query current mode via: CSI ? u
/// Programs pop mode via: CSI < u
///
/// Enhancement flags (bitfield):
/// 1 = disambiguate escape codes
/// 2 = report event types (press/repeat/release)
/// 4 = report alternate keys
/// 8 = report all keys as escape codes
/// 16 = report associated text
public struct KittyKeyboardProtocol: Sendable {
    /// Current enhancement flags (bitfield)
    public private(set) var flags: UInt32 = 0

    /// Stack of previous flag states (push/pop mechanism)
    public private(set) var flagStack: [UInt32] = []

    /// Maximum stack depth to prevent memory issues
    public static let maxStackDepth = 64

    public init() {}

    // MARK: - Flag Management

    /// Push current flags and set new flags
    /// CSI > flags u
    public mutating func pushFlags(_ newFlags: UInt32) {
        if flagStack.count < Self.maxStackDepth {
            flagStack.append(flags)
        }
        flags = newFlags
    }

    /// Pop to previous flags
    /// CSI < number u  (pop `number` entries, default 1)
    public mutating func popFlags(count: Int = 1) {
        for _ in 0 ..< count {
            guard let previous = flagStack.popLast() else { break }
            flags = previous
        }
    }

    /// Query current flags (response: CSI ? flags u)
    public func queryResponse() -> [UInt8] {
        let response = "\u{1b}[?\(flags)u"
        return Array(response.utf8)
    }

    // MARK: - Flag Checks

    public var disambiguateEscapeCodes: Bool {
        flags & 1 != 0
    }

    public var reportEventTypes: Bool {
        flags & 2 != 0
    }

    public var reportAlternateKeys: Bool {
        flags & 4 != 0
    }

    public var reportAllKeysAsEscapeCodes: Bool {
        flags & 8 != 0
    }

    public var reportAssociatedText: Bool {
        flags & 16 != 0
    }

    // MARK: - Key Encoding

    /// Encodes a key event according to the current enhancement flags.
    /// Format: CSI number:shifted_key ; modifiers:event_type u
    public func encodeKeyEvent(_ event: KittyKeyEvent) -> [UInt8] {
        // If no enhancements active, return legacy encoding
        guard flags > 0 else {
            return event.legacyEncoding
        }

        var parts: [String] = []

        // Base key number
        var keyPart = "\(event.keyCode)"
        if reportAlternateKeys, let shifted = event.shiftedKey {
            keyPart += ":\(shifted)"
        }
        parts.append(keyPart)

        // Modifiers and event type
        var modPart = ""
        let modValue = event.modifiers.wireValue
        if modValue > 1 || (reportEventTypes && event.eventType != .press) {
            modPart = "\(modValue)"
        }
        if reportEventTypes, event.eventType != .press {
            modPart += ":\(event.eventType.rawValue)"
        }
        if !modPart.isEmpty {
            parts.append(modPart)
        }

        // Build CSI sequence
        let inner = parts.joined(separator: ";")
        let seq = "\u{1b}[\(inner)u"
        return Array(seq.utf8)
    }

    /// Parse a CSI sequence to check if it is a keyboard protocol request.
    /// Returns nil if not a keyboard protocol sequence.
    public static func parseRequest(_ sequence: [UInt8]) -> KeyboardProtocolRequest? {
        guard sequence.count >= 3 else { return nil }
        guard sequence.first == 0x1B, sequence[1] == 0x5B else { return nil } // ESC [

        let content = sequence.dropFirst(2)
        guard let last = content.last, last == 0x75 else { return nil } // u
        let inner = content.dropLast()

        guard let firstChar = inner.first else {
            return .query
        }

        if firstChar == 0x3E { // >
            let numStr = String(bytes: inner.dropFirst(), encoding: .ascii) ?? "0"
            let flags = UInt32(numStr) ?? 0
            return .push(flags)
        } else if firstChar == 0x3C { // <
            let numStr = String(bytes: inner.dropFirst(), encoding: .ascii) ?? "1"
            let count = Int(numStr) ?? 1
            return .pop(count)
        } else if firstChar == 0x3F { // ?
            return .query
        }

        return nil
    }
}

// MARK: - Supporting Types

public struct KittyKeyEvent: Sendable {
    public let keyCode: Int // Unicode codepoint or functional key number
    public let shiftedKey: Int? // Shifted version of the key
    public let baseKey: Int? // Base layout key
    public let modifiers: KittyModifiers
    public let eventType: KittyEventType
    public let text: String? // Associated text (if flag 16)
    public let legacyEncoding: [UInt8] // Fallback legacy sequence

    public init(
        keyCode: Int,
        shiftedKey: Int? = nil,
        baseKey: Int? = nil,
        modifiers: KittyModifiers = .none,
        eventType: KittyEventType = .press,
        text: String? = nil,
        legacyEncoding: [UInt8] = []
    ) {
        self.keyCode = keyCode
        self.shiftedKey = shiftedKey
        self.baseKey = baseKey
        self.modifiers = modifiers
        self.eventType = eventType
        self.text = text
        self.legacyEncoding = legacyEncoding
    }
}

public struct KittyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let none = KittyModifiers([])
    public static let shift = KittyModifiers(rawValue: 1)
    public static let alt = KittyModifiers(rawValue: 1 << 1)
    public static let ctrl = KittyModifiers(rawValue: 1 << 2)
    public static let `super` = KittyModifiers(rawValue: 1 << 3)
    public static let hyper = KittyModifiers(rawValue: 1 << 4)
    public static let meta = KittyModifiers(rawValue: 1 << 5)
    public static let capsLock = KittyModifiers(rawValue: 1 << 6)
    public static let numLock = KittyModifiers(rawValue: 1 << 7)

    /// Converts to the Kitty wire protocol modifier value (1-based encoding).
    /// The protocol encodes modifiers as: 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0) + ...
    public var wireValue: UInt32 {
        rawValue + 1
    }
}

public enum KittyEventType: Int, Sendable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

public enum KeyboardProtocolRequest: Equatable, Sendable {
    case push(UInt32)
    case pop(Int)
    case query
}

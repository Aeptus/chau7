import Foundation

/// Lightweight JSON value used for delegated-task schemas and structured results.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(object):
            try container.encode(object)
        case let .array(array):
            try container.encode(array)
        case let .string(string):
            try container.encode(string)
        case let .number(number):
            try container.encode(number)
        case let .bool(bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }

    public static func from(any value: Any) -> JSONValue? {
        switch value {
        case let object as [String: Any]:
            var converted: [String: JSONValue] = [:]
            for (key, rawValue) in object {
                guard let jsonValue = JSONValue.from(any: rawValue) else {
                    return nil
                }
                converted[key] = jsonValue
            }
            return .object(converted)
        case let array as [Any]:
            let converted = array.compactMap(JSONValue.from(any:))
            guard converted.count == array.count else { return nil }
            return .array(converted)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }

    public var foundationValue: Any {
        switch self {
        case let .object(object):
            return object.mapValues(\.foundationValue)
        case let .array(array):
            return array.map(\.foundationValue)
        case let .string(string):
            return string
        case let .number(number):
            if number.rounded(.towardZero) == number {
                return Int(number)
            }
            return number
        case let .bool(bool):
            return bool
        case .null:
            return NSNull()
        }
    }

    public var stringValue: String? {
        if case let .string(string) = self {
            return string
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(bool) = self {
            return bool
        }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(object) = self {
            return object
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(array) = self {
            return array
        }
        return nil
    }

    public var isInteger: Bool {
        guard case let .number(number) = self else { return false }
        return number.rounded(.towardZero) == number
    }
}

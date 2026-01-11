import Foundation

struct AIEvent: Identifiable, Equatable {
    let id = UUID()
    let type: String
    let tool: String
    let message: String
    let ts: String

    /// Returns the notification title for this event.
    var notificationTitle: String {
        switch type.lowercased() {
        case "needs_validation":
            return "\(tool): Validation needed"
        case "idle":
            return "\(tool): Possibly waiting for you"
        case "finished":
            return "\(tool): Task finished"
        case "failed":
            return "\(tool): Task failed"
        default:
            return "\(tool): Update"
        }
    }

    /// Returns the notification body for this event.
    var notificationBody: String {
        switch type.lowercased() {
        case "needs_validation":
            return message.isEmpty ? "Your input is required." : message
        case "idle":
            return message.isEmpty ? "No new history entries for a while." : message
        case "finished":
            return message.isEmpty ? "Done." : message
        case "failed":
            return message.isEmpty ? "Check the logs." : message
        default:
            return message.isEmpty ? type : "\(type): \(message)"
        }
    }
}

enum AIEventParseError: Error {
    case notJSONObject
    case missingField(String)
    case invalidFieldType(String)
}

final class AIEventParser {
    static func parse(line: String) throws -> AIEvent {
        guard let data = line.data(using: .utf8) else {
            throw AIEventParseError.notJSONObject
        }

        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw AIEventParseError.notJSONObject
        }

        func getString(_ key: String, default defaultValue: String? = nil) throws -> String {
            if let value = dict[key] {
                guard let stringValue = value as? String else {
                    throw AIEventParseError.invalidFieldType(key)
                }
                return stringValue
            }
            if let defaultValue {
                return defaultValue
            }
            throw AIEventParseError.missingField(key)
        }

        let type = try getString("type")
        let tool = try getString("tool", default: "CLI")
        let message = try getString("message", default: "")
        let ts = try getString(
            "ts",
            default: DateFormatters.nowISO8601()
        )

        return AIEvent(type: type, tool: tool, message: message, ts: ts)
    }
}

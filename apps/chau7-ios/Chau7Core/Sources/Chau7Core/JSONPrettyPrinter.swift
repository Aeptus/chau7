import Foundation

public enum JSONPrettyPrinter {
    public static func prettyPrint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return nil
        }
        return String(data: prettyData, encoding: .utf8)
    }
}

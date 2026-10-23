import Foundation

public enum StructuredResultExtractor {
    public static func capture(
        sessionID: String,
        turnID: String,
        summary: String?,
        output: String?,
        schema: JSONValue?
    ) -> RuntimeTurnResult? {
        let candidates = extractCandidates(summary: summary, output: output)
        for candidate in candidates {
            guard let data = candidate.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let value = JSONValue.from(any: object) else {
                continue
            }

            let validationErrors = schema.map { validate(value: value, schema: $0) } ?? []
            return RuntimeTurnResult(
                sessionID: sessionID,
                turnID: turnID,
                status: validationErrors.isEmpty ? .available : .invalid,
                source: candidate.source,
                schema: schema,
                value: value,
                validationErrors: validationErrors,
                rawText: candidate.text
            )
        }

        guard let schema else { return nil }
        let rawText = (summary ?? output)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeTurnResult(
            sessionID: sessionID,
            turnID: turnID,
            status: .missing,
            source: "missing",
            schema: schema,
            value: nil,
            validationErrors: ["No structured JSON result matching the requested schema was found."],
            rawText: rawText
        )
    }

    public static func validate(value: JSONValue, schema: JSONValue) -> [String] {
        guard case let .object(rootSchema) = schema else {
            return ["Schema must be a JSON object."]
        }
        return validate(value: value, schemaObject: rootSchema, path: "$")
    }

    private static func validate(value: JSONValue, schemaObject: [String: JSONValue], path: String) -> [String] {
        var errors: [String] = []

        if let expectedType = schemaObject["type"]?.stringValue,
           !matches(type: expectedType, value: value) {
            errors.append("\(path) expected \(expectedType)")
            return errors
        }

        if let enumValues = schemaObject["enum"]?.arrayValue, !enumValues.contains(value) {
            errors.append("\(path) must match enum")
        }

        if case let .object(objectValue) = value {
            let properties = schemaObject["properties"]?.objectValue ?? [:]
            let required = schemaObject["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for key in required where objectValue[key] == nil {
                errors.append("\(path).\(key) is required")
            }
            for (key, childValue) in objectValue {
                if let childSchema = properties[key]?.objectValue {
                    errors.append(contentsOf: validate(value: childValue, schemaObject: childSchema, path: "\(path).\(key)"))
                } else if schemaObject["additionalProperties"]?.boolValue == false {
                    errors.append("\(path).\(key) is not allowed")
                }
            }
        } else if case let .array(arrayValue) = value,
                  let itemSchema = schemaObject["items"]?.objectValue {
            for (index, childValue) in arrayValue.enumerated() {
                errors.append(contentsOf: validate(value: childValue, schemaObject: itemSchema, path: "\(path)[\(index)]"))
            }
        }

        return errors
    }

    private static func matches(type: String, value: JSONValue) -> Bool {
        switch type {
        case "object":
            if case .object = value { return true }
        case "array":
            if case .array = value { return true }
        case "string":
            if case .string = value { return true }
        case "number":
            if case .number = value { return true }
        case "integer":
            return value.isInteger
        case "boolean":
            if case .bool = value { return true }
        case "null":
            if case .null = value { return true }
        default:
            return true
        }
        return false
    }

    private static func extractCandidates(summary: String?, output: String?) -> [(source: String, text: String)] {
        var candidates: [(source: String, text: String)] = []
        candidates.append(contentsOf: jsonCandidates(in: summary, prefix: "summary"))
        candidates.append(contentsOf: jsonCandidates(in: output, prefix: "output"))
        return candidates
    }

    private static func jsonCandidates(in text: String?, prefix: String) -> [(source: String, text: String)] {
        guard let text else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [(source: String, text: String)] = []
        if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive]) {
            let nsrange = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, options: [], range: nsrange)
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: trimmed) else { continue }
                let candidate = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    candidates.append(("\(prefix)_json_fence", candidate))
                }
            }
        }

        if trimmed.first == "{" || trimmed.first == "[" {
            candidates.append(("\(prefix)_raw_json", trimmed))
        }

        return candidates
    }
}

import Foundation

public struct CodexFeedbackPrompt: Equatable, Sendable {
    public let callID: String?
    public let message: String
    public let optionLabels: [String]

    public init(callID: String?, message: String, optionLabels: [String]) {
        self.callID = callID
        self.message = message
        self.optionLabels = optionLabels
    }
}

public enum CodexRolloutFeedbackRecord: Equatable, Sendable {
    case structuredPrompt(CodexFeedbackPrompt)
    case toolCallCompleted(callID: String, output: String)
}

public enum CodexFeedbackPromptParser {
    public static func parse(questions: [[String: Any]], callID: String?) -> CodexFeedbackPrompt? {
        guard !questions.isEmpty else { return nil }
        let questionTexts = questions.compactMap { nonEmptyString($0["question"]) }
        guard !questionTexts.isEmpty else { return nil }
        let optionLabels = questions.flatMap { question -> [String] in
            guard let options = question["options"] as? [[String: Any]] else { return [] }
            return options.compactMap { nonEmptyString($0["label"]) }
        }
        return CodexFeedbackPrompt(
            callID: callID,
            message: questionTexts.joined(separator: "\n"),
            optionLabels: optionLabels
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CodexRolloutFeedbackParser {
    public static func parse(line: String) -> CodexRolloutFeedbackRecord? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "response_item",
              let payload = root["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }

        switch payloadType {
        case "function_call":
            guard payload["name"] as? String == "request_user_input",
                  let callID = nonEmptyString(payload["call_id"]),
                  let arguments = payload["arguments"] as? String,
                  let prompt = parsePrompt(arguments: arguments, callID: callID) else {
                return nil
            }
            return .structuredPrompt(prompt)

        case "function_call_output":
            guard let callID = nonEmptyString(payload["call_id"]) else { return nil }
            return .toolCallCompleted(callID: callID, output: stringify(payload["output"]))

        default:
            return nil
        }
    }

    public static func isUnavailableOutput(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("request_user_input is unavailable")
            || normalized.contains("requires plan mode")
    }

    private static func parsePrompt(arguments: String, callID: String) -> CodexFeedbackPrompt? {
        guard let data = arguments.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = root["questions"] as? [[String: Any]] else {
            return nil
        }
        return CodexFeedbackPromptParser.parse(questions: questions, callID: callID)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringify(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

public enum CodexFeedbackProposalClassifier {
    public static func detect(in message: String) -> CodexFeedbackPrompt? {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let tailLines = Array(lines.suffix(80))
        let tail = tailLines.joined(separator: "\n")
        let lowerTail = tail.lowercased()

        guard containsResponseDirective(lowerTail) else { return nil }

        let numbered = numberedOptions(in: tailLines)
        let bullets = trailingBulletOptions(in: tailLines)
        let inline = inlineCodeOptions(in: tailLines.suffix(12).joined(separator: "\n"))
        let options = deduplicated(numbered.count >= 2 ? numbered : (bullets.count >= 2 ? bullets : inline))

        let unresolvedDecisionCount = unresolvedDecisions(in: lowerTail)
        guard options.count >= 2 || unresolvedDecisionCount >= 2 else { return nil }

        let prompt = lastDirectiveParagraph(in: tailLines)
            ?? "Codex is waiting for your choice."
        return CodexFeedbackPrompt(callID: nil, message: prompt, optionLabels: options)
    }

    private static func containsResponseDirective(_ text: String) -> Bool {
        let patterns = [
            "tell me ", "choose ", "select ", "pick ", "reply with", "respond with",
            "let me know which", "which option", "confirm ", "needs your confirmation",
            "until you confirm", "pending your confirmation", "waiting for your choice",
            "dis-moi", "dites-moi", "choisis", "choisissez", "sélectionne", "sélectionnez",
            "réponds", "répondez", "indique-moi", "confirme", "confirmez",
            "tant que tu ne les confirmes pas", "en attente de ta confirmation",
            "les choix possibles"
        ]
        return patterns.contains { text.contains($0) }
    }

    private static func numberedOptions(in lines: [String]) -> [String] {
        let patterns = [
            #"^\s*(?:[-*]\s*)?#?(\d+)\s*[\.)\:]?\s+(.+?)\s*$"#,
            #"^\s*(\d+)\.\s+(.+?)\s*$"#
        ]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var options: [String] = []
        for line in lines {
            for regex in regexes {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      match.numberOfRanges >= 3,
                      let labelRange = Range(match.range(at: 2), in: line) else { continue }
                let label = cleanLabel(String(line[labelRange]))
                if !label.isEmpty { options.append(label) }
                break
            }
        }
        return options
    }

    private static func trailingBulletOptions(in lines: [String]) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"^\s*[-*]\s+(.+?)\s*$"#)
        guard let regex else { return [] }
        return lines.suffix(20).compactMap { line in
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let labelRange = Range(match.range(at: 1), in: line) else { return nil }
            let label = cleanLabel(String(line[labelRange]))
            return label.isEmpty ? nil : label
        }
    }

    private static func inlineCodeOptions(in text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"`([^`\n]{1,80})`"#)
        guard let regex else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[valueRange])
            guard !value.contains("/"), !value.contains("."), !value.contains(" ") else { return nil }
            return value
        }
    }

    private static func unresolvedDecisions(in text: String) -> Int {
        if text.contains("two recommendations") || text.contains("two decisions")
            || text.contains("deux recommandations") || text.contains("deux décisions") {
            return 2
        }
        return 0
    }

    private static func lastDirectiveParagraph(in lines: [String]) -> String? {
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = nonEmpty.last else { return nil }
        return cleanLabel(last)
    }

    private static func cleanLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

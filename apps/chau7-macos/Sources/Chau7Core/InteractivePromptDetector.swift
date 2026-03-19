import CryptoKit
import Foundation

public struct DetectedInteractivePrompt: Equatable, Sendable {
    public let signature: String
    public let prompt: String
    public let detail: String?
    public let options: [RemoteInteractivePromptOption]

    public init(signature: String, prompt: String, detail: String?, options: [RemoteInteractivePromptOption]) {
        self.signature = signature
        self.prompt = prompt
        self.detail = detail
        self.options = options
    }
}

public enum InteractivePromptDetector {
    public static func detect(in text: String, toolName: String) -> DetectedInteractivePrompt? {
        guard supports(toolName: toolName) else { return nil }

        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        let allLines = normalized.components(separatedBy: "\n")
        let lines = Array(allLines.suffix(80))

        guard let match = findPrompt(in: lines) else { return nil }
        let signature = signature(prompt: match.prompt, options: match.options)
        return DetectedInteractivePrompt(
            signature: signature,
            prompt: match.prompt,
            detail: match.detail,
            options: match.options
        )
    }

    private static func supports(toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("claude") || normalized.contains("codex")
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func findPrompt(in lines: [String]) -> (prompt: String, detail: String?, options: [RemoteInteractivePromptOption])? {
        guard !lines.isEmpty else { return nil }

        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = cleanedLine(lines[index])
            guard isPromptLine(line) else { continue }

            let options = parseOptions(in: lines, after: index)
            guard options.count >= 2 else { continue }

            let detail = parseDetail(in: lines, aroundPromptAt: index)
            return (line, detail, options)
        }

        return nil
    }

    private static func parseOptions(in lines: [String], after promptIndex: Int) -> [RemoteInteractivePromptOption] {
        var options: [RemoteInteractivePromptOption] = []

        for offset in 1 ... 8 {
            let index = promptIndex + offset
            guard index < lines.count else { break }

            let raw = cleanedLine(lines[index])
            if raw.isEmpty {
                if !options.isEmpty { break }
                continue
            }

            if let option = parseOption(from: raw) {
                options.append(option)
                continue
            }

            if !options.isEmpty {
                break
            }
        }

        return options
    }

    private static func parseOption(from line: String) -> RemoteInteractivePromptOption? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[^A-Za-z0-9]*([0-9]+)\.\s+(.+?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges == 3,
              let tokenRange = Range(match.range(at: 1), in: line),
              let labelRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let token = String(line[tokenRange])
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }

        let destructiveWords = ["deny", "reject", "cancel", "abort", "stop", "no"]
        let isDestructive = destructiveWords.contains { label.lowercased().contains($0) }
        return RemoteInteractivePromptOption(
            id: token,
            label: label,
            response: token + "\r",
            isDestructive: isDestructive
        )
    }

    private static func parseDetail(in lines: [String], aroundPromptAt index: Int) -> String? {
        var details: [String] = []

        for offset in 1 ... 2 {
            let previousIndex = index - offset
            guard previousIndex >= 0 else { break }
            let candidate = cleanedLine(lines[previousIndex])
            guard !candidate.isEmpty, !isMetaLine(candidate), !isPromptLine(candidate) else { continue }
            details.insert(candidate, at: 0)
        }

        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    private static func cleanedLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMetaLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("esc to cancel") ||
            lowered.contains("tab to amend") ||
            lowered.contains("ctrl+e") ||
            lowered.contains("press ctrl") ||
            lowered.contains("ctrl+c")
    }

    private static func isPromptLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let keywords = [
            "do you want",
            "select an option",
            "choose an option",
            "which option",
            "continue",
            "proceed",
            "approve",
            "allow this"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private static func signature(prompt: String, options: [RemoteInteractivePromptOption]) -> String {
        let basis = prompt + "\n" + options.map { "\($0.id):\($0.label)" }.joined(separator: "\n")
        return Data(SHA256.hash(data: Data(basis.utf8)).prefix(12)).base64EncodedString()
    }
}

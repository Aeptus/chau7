import Foundation

public enum RuntimeToolEventMetadata {
    public struct ToolResultMetadata: Equatable, Sendable {
        public let success: Bool
        public let exitCode: Int?
        public let error: String?
        public let outputPreview: String?

        public init(success: Bool, exitCode: Int?, error: String?, outputPreview: String?) {
            self.success = success
            self.exitCode = exitCode
            self.error = error
            self.outputPreview = outputPreview
        }
    }

    public static func argsSummary(from message: String, maxLength: Int = 200) -> String? {
        truncatedPreview(message, maxLength: maxLength)
    }

    public static func outputPreview(from message: String, maxLength: Int = 500) -> String? {
        truncatedPreview(message, maxLength: maxLength)
    }

    public static func inferResult(toolName _: String, message: String) -> ToolResultMetadata {
        let preview = outputPreview(from: message)
        let exitCode = extractExitCode(from: message)
        let lowercase = message.lowercased()
        let success: Bool

        if let exitCode {
            success = exitCode == 0
        } else if lowercase.contains("error") || lowercase.contains("failed") || lowercase.contains("denied") {
            success = false
        } else {
            success = true
        }

        let error = success ? nil : preview
        return ToolResultMetadata(
            success: success,
            exitCode: exitCode,
            error: error,
            outputPreview: preview
        )
    }

    public static func extractFilePath(toolName: String, message: String, cwd: String) -> String? {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return nil }

        let simpleFileTools = Set(["Write", "Edit", "Read", "NotebookEdit"])
        if simpleFileTools.contains(toolName) {
            return normalizePathCandidate(firstPathLikeToken(in: trimmedMessage) ?? trimmedMessage, cwd: cwd)
        }

        let tokenized = CommandDetection.tokenize(trimmedMessage)
        guard !tokenized.isEmpty else { return normalizePathCandidate(trimmedMessage, cwd: cwd) }

        switch toolName {
        case "Bash":
            return extractBashFilePath(from: tokenized, cwd: cwd)
        case "Grep", "Glob", "LS":
            return extractTargetPath(from: tokenized, cwd: cwd)
        default:
            return extractTargetPath(from: tokenized, cwd: cwd)
        }
    }

    private static func extractBashFilePath(from tokens: [String], cwd: String) -> String? {
        let candidate = candidatePathTokens(from: tokens).first
        return candidate.flatMap { normalizePathCandidate($0, cwd: cwd) }
    }

    private static func extractTargetPath(from tokens: [String], cwd: String) -> String? {
        for token in candidatePathTokens(from: tokens) {
            if let path = normalizePathCandidate(token, cwd: cwd) {
                return path
            }
        }
        return nil
    }

    private static func candidatePathTokens(from tokens: [String]) -> [String] {
        tokens.filter { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !trimmed.hasPrefix("-") else { return false }
            guard trimmed != "|", trimmed != "&&", trimmed != "||" else { return false }
            guard !trimmed.contains("=") else { return false }
            return looksLikePath(trimmed)
        }
    }

    private static func firstPathLikeToken(in message: String) -> String? {
        let tokens = CommandDetection.tokenize(message)
        return candidatePathTokens(from: tokens).first
    }

    private static func looksLikePath(_ token: String) -> Bool {
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~/") {
            return true
        }
        if token.contains("/") {
            return true
        }
        if token.contains("*") || token.contains("?") {
            return true
        }
        if token.contains("."),
           token.range(of: #"^[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func normalizePathCandidate(_ token: String, cwd: String) -> String? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            return trimmed
        }
        if trimmed.hasPrefix("~/") {
            return NSString(string: trimmed).expandingTildeInPath
        }
        if !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).appendingPathComponent(trimmed).standardized.path
        }
        return trimmed
    }

    private static func extractExitCode(from message: String) -> Int? {
        let patterns = [
            #"exit[_ ]code[:= ]+(-?\d+)"#,
            #"exited with (?:status|code)[:= ]+(-?\d+)"#,
            #"returned[:= ]+(-?\d+)"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(message.startIndex ..< message.endIndex, in: message)
                if let match = regex.firstMatch(in: message, options: [], range: range),
                   match.numberOfRanges > 1,
                   let codeRange = Range(match.range(at: 1), in: message) {
                    return Int(message[codeRange])
                }
            }
        }

        return nil
    }

    private static func truncatedPreview(_ message: String, maxLength: Int) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength {
            return trimmed
        }
        return String(trimmed.prefix(maxLength))
    }
}

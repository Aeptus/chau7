import Foundation

/// Shared policy for terminal input that should not be persisted verbatim.
public enum SensitiveInputGuard {
    public static let redactedPlaceholder = "[REDACTED SENSITIVE INPUT]"

    /// Patterns that indicate a command contains inline secrets.
    /// These commands are safe to execute, but should not be stored in logs,
    /// history, or analytics because they embed credentials as arguments.
    public static let sensitiveArgumentPatterns: [String] = [
        "-p ", "-p=", "--password=", "--password ",
        "--passphrase=", "--passphrase ",
        "--token=", "--token ",
        "--secret=", "--secret ",
        "--api-key=", "--api-key ",
        "--apikey=", "--apikey ",
        "--auth-token=",
        "authorization: bearer", "authorization:bearer",
        "authorization: basic", "authorization:basic",
        "-H 'Authorization", "-H \"Authorization",
        "PASSWORD=", "TOKEN=", "SECRET=", "API_KEY=",
        "AWS_SECRET_ACCESS_KEY=",
        "GITHUB_TOKEN=", "GH_TOKEN="
    ]

    public static func containsInlineSecrets(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for pattern in sensitiveArgumentPatterns {
            if lowered.contains(pattern.lowercased()) {
                return true
            }
        }
        return false
    }

    public static func shouldPersistInput(_ text: String, echoDisabled: Bool) -> Bool {
        guard !echoDisabled else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return true
    }

    public static func sanitizedCommandForPersistence(_ command: String, echoDisabled: Bool = false) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if echoDisabled {
            return redactedPlaceholder
        }
        if containsInlineSecrets(trimmed) {
            if let summary = commandSummary(from: trimmed) {
                return "\(summary) \(redactedPlaceholder)"
            }
            return redactedPlaceholder
        }
        return trimmed
    }

    public static func sanitizedInputLineForPersistence(_ text: String, echoDisabled: Bool = false) -> String? {
        guard shouldPersistInput(text, echoDisabled: echoDisabled) else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return sanitizedCommandForPersistence(normalized)
    }

    private static func commandSummary(from command: String) -> String? {
        let tokens = CommandDetection.tokenize(command)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }

            let normalized = CommandDetection.normalizeToken(token)
            if normalized == "sudo" {
                index += 1
                while index < tokens.count {
                    let option = tokens[index]
                    if option == "--" {
                        index += 1
                        break
                    }
                    if !option.hasPrefix("-") {
                        break
                    }
                    if CommandDetection.sudoOptionsWithValue.contains(option), index + 1 < tokens.count {
                        index += 2
                    } else {
                        index += 1
                    }
                }
                continue
            }

            if CommandDetection.wrapperCommands.contains(normalized) {
                index += 1
                continue
            }

            return normalized
        }

        guard index < tokens.count else { return nil }
        return CommandDetection.normalizeToken(tokens[index])
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else { return false }
        return !token[..<equalsIndex].contains("/")
    }
}

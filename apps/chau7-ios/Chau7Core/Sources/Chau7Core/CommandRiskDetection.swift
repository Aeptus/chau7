import Foundation

public enum CommandRiskDetection {
    /// Returns true if the command line matches any configured risky patterns.
    /// Matching is case-insensitive, whitespace-normalized, and token-bounded.
    public static func isRisky(commandLine: String, patterns: [String]) -> Bool {
        let normalizedCommand = normalize(commandLine)
        return isRisky(normalizedCommand: normalizedCommand, patterns: patterns, requiresExecutableContext: false)
    }

    /// Returns true when a terminal output row contains a risky command-like span.
    /// This deliberately rejects explanatory prose such as "do not run rm -rf".
    public static func isRiskyOutputLine(_ line: String, patterns: [String]) -> Bool {
        let normalizedCommand = normalize(trimCommandDecorations(line))
        return isRisky(normalizedCommand: normalizedCommand, patterns: patterns, requiresExecutableContext: true)
    }

    private static func isRisky(normalizedCommand: String, patterns: [String], requiresExecutableContext: Bool) -> Bool {
        guard !normalizedCommand.isEmpty else { return false }
        for rawPattern in patterns {
            let normalizedPattern = normalize(rawPattern)
            guard !normalizedPattern.isEmpty else { continue }
            if containsCommandPattern(
                normalizedPattern,
                in: normalizedCommand,
                requiresExecutableContext: requiresExecutableContext
            ) {
                return true
            }
        }
        return false
    }

    private static func containsCommandPattern(
        _ pattern: String,
        in command: String,
        requiresExecutableContext: Bool
    ) -> Bool {
        var searchStart = command.startIndex
        while let range = command.range(of: pattern, range: searchStart ..< command.endIndex) {
            if hasTokenBoundaries(for: pattern, in: command, range: range),
               !requiresExecutableContext || hasExecutableContext(before: range.lowerBound, pattern: pattern, in: command) {
                return true
            }
            searchStart = command.index(after: range.lowerBound)
        }
        return false
    }

    private static func hasExecutableContext(before matchStart: String.Index, pattern: String, in command: String) -> Bool {
        let prefix = String(command[..<matchStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return true }

        // Option-only patterns are too broad for output scanning unless they are
        // embedded in a larger command pattern that starts at command position.
        if pattern.first == "-" { return false }

        let tail = commandTail(beforeMatchIn: prefix)
        if tail.isEmpty { return true }
        return isExecutionPrefix(tail)
    }

    private static func commandTail(beforeMatchIn prefix: String) -> String {
        let separators = ["&&", "||", ";", "|"]
        var splitIndex: String.Index?
        for separator in separators {
            if let range = prefix.range(of: separator, options: .backwards),
               splitIndex.map({ range.upperBound > $0 }) ?? true {
                splitIndex = range.upperBound
            }
        }
        let tailStart = splitIndex ?? prefix.startIndex
        return trimTrailingSyntax(String(prefix[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isExecutionPrefix(_ prefix: String) -> Bool {
        let tokens = prefix
            .split(whereSeparator: { $0.isWhitespace })
            .map { cleanToken(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        if tokens.contains("-exec") { return true }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }

            switch token {
            case "sudo", "doas", "command", "builtin", "noglob", "time", "eval":
                index += 1
                while index < tokens.count, tokens[index].hasPrefix("-") {
                    index += 1
                }
            case "env":
                index += 1
                while index < tokens.count,
                      tokens[index].hasPrefix("-") || isEnvironmentAssignment(tokens[index]) {
                    index += 1
                }
            case "xargs":
                return true
            case "sh", "bash", "zsh", "fish":
                return tokens[(index + 1)...].contains("-c") || tokens[(index + 1)...].contains("-lc")
            case "python", "python3":
                return tokens[(index + 1)...].contains("-c")
            case "node", "ruby", "perl":
                return tokens[(index + 1)...].contains("-e")
            case "psql":
                return tokens[(index + 1)...].contains("-c")
            case "mysql":
                return tokens[(index + 1)...].contains("-e")
            case "sqlite3", "sql":
                return true
            default:
                return false
            }
        }
        return true
    }

    private static func hasTokenBoundaries(for pattern: String, in command: String, range: Range<String.Index>) -> Bool {
        if let first = pattern.first, requiresTokenBoundary(first),
           range.lowerBound > command.startIndex {
            let before = command[command.index(before: range.lowerBound)]
            if isCommandTokenCharacter(before) { return false }
        }

        if let last = pattern.last, requiresTokenBoundary(last),
           range.upperBound < command.endIndex {
            let after = command[range.upperBound]
            if isCommandTokenCharacter(after) { return false }
        }

        return true
    }

    private static func requiresTokenBoundary(_ character: Character) -> Bool {
        isCommandTokenCharacter(character)
    }

    private static func isCommandTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func trimCommandDecorations(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for pattern in ["^(\\$|%|#|>)\\s+", "^[-*+]\\s+", "^[0-9]+[.)]\\s+"] {
                if let stripped = stripRegexPrefix(pattern, from: text) {
                    text = stripped
                    changed = true
                }
            }
            if let stripped = stripWrappingBackticks(text) {
                text = stripped
                changed = true
            }
        }
        return text
    }

    private static func stripRegexPrefix(_ pattern: String, from text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression),
              range.lowerBound == text.startIndex
        else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingBackticks(_ text: String) -> String? {
        guard text.count >= 2, text.first == "`", text.last == "`" else { return nil }
        var stripped = text
        stripped.removeFirst()
        stripped.removeLast()
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingSyntax(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`("))
    }

    private static func cleanToken(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}"))
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let key = parts.first, !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }

    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}

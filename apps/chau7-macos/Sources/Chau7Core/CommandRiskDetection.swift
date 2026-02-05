import Foundation

public enum CommandRiskDetection {
    /// Returns true if the command line matches any configured risky patterns.
    /// Matching is case-insensitive and whitespace-normalized.
    public static func isRisky(commandLine: String, patterns: [String]) -> Bool {
        if let rust = RustCommandRisk.shared.isRisky(command: commandLine, patterns: patterns) {
            return rust
        }
        let normalizedCommand = normalize(commandLine)
        guard !normalizedCommand.isEmpty else { return false }
        for rawPattern in patterns {
            let normalizedPattern = normalize(rawPattern)
            guard !normalizedPattern.isEmpty else { continue }
            if normalizedCommand.contains(normalizedPattern) {
                return true
            }
        }
        return false
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

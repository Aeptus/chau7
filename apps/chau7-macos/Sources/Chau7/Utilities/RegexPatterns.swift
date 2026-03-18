import Foundation

// MARK: - Shared Regex Patterns (Code Optimization)

// Consolidates NSRegularExpression instances to avoid per-call compilation

/// Helper to create regex with clear error messages (Fix #10: safe regex initialization)
private func makeRegex(_ pattern: String, options: NSRegularExpression.Options = [], name: String) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        // Provide actionable error message for debugging
        fatalError("RegexPatterns.\(name): Invalid pattern '\(pattern)' - \(error.localizedDescription)")
    }
}

enum RegexPatterns {
    /// URL pattern for detecting clickable links (http, https, file, ssh, ftp, sftp)
    static let url: NSRegularExpression = makeRegex(
        #"(?:https?|file|ssh|ftp|sftp)://[^\s<>\[\]{}|\\^`"']+"#,
        options: [.caseInsensitive],
        name: "url"
    )

    /// File path pattern with optional line:column
    /// Matches: /path/to/file.ext:123:45 or ./relative/path.txt:10
    static let filePath: NSRegularExpression = makeRegex(
        #"(?:^|[\s"'`({\[])((?:[/.])?(?:[\w.-]+/)*[\w.-]+\.\w+)(?::(\d+))?(?::(\d+))?"#,
        name: "filePath"
    )
}

import Foundation

// MARK: - Shared Regex Patterns (Code Optimization)
// Consolidates NSRegularExpression instances to avoid per-call compilation

enum RegexPatterns {
    /// URL pattern for detecting clickable links
    static let url: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"https?://[^\s<>\[\]{}|\\^`"']+"#,
            options: [.caseInsensitive]
        )
    }()

    /// File path pattern with optional line:column
    /// Matches: /path/to/file.ext:123:45 or ./relative/path.txt:10
    static let filePath: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?:^|[\s"'`({\[])((?:[/.])?(?:[\w.-]+/)*[\w.-]+\.\w+)(?::(\d+))?(?::(\d+))?"#,
            options: []
        )
    }()
}

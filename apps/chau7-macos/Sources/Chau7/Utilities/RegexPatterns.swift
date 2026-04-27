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
    /// URL pattern for detecting clickable links. Four alternatives, in
    /// priority order:
    ///
    ///   1. Schemed URL (`https?://`, `file://`, `ssh://`, `ftp://`, `sftp://`)
    ///      — the canonical case.
    ///   2. `www.`-prefixed bare URL — e.g., `www.example.com/foo`. Anchoring
    ///      on the `www.` literal keeps false-positive risk near zero.
    ///   3. `localhost` (with optional port and path) — common in dev output.
    ///   4. Bare domain + path — `host.tld/...`. Requires (a) a leading
    ///      letter, (b) a 2–24-char alphabetic TLD, and (c) a literal `/`
    ///      after the TLD. The trailing-slash requirement is the key
    ///      disambiguator: it rejects version strings (`v1.2.3`), dot
    ///      properties (`self.foo.bar`), and bare filenames (`README.md`).
    ///
    /// Caller is expected to strip trailing prose punctuation (.,;:!?) from
    /// the matched substring before opening — see `findURLs(in:)` in
    /// `RustTerminalView+Mouse.swift`.
    static let url: NSRegularExpression = makeRegex(
        // swiftlint:disable:next line_length
        #"(?:https?|file|ssh|ftp|sftp)://[^\s<>\[\]{}|\\^`"']+|www\.[^\s<>\[\]{}|\\^`"']+|localhost(?::\d+)?(?:/[^\s<>\[\]{}|\\^`"']*)?|\b[a-zA-Z][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)*\.[a-zA-Z]{2,24}/[^\s<>\[\]{}|\\^`"']*"#,
        options: [.caseInsensitive],
        name: "url"
    )

    /// File path pattern with optional line:column
    /// Matches: /path/to/file.ext:123:45 or ./relative/path.txt:10
    static let filePath: NSRegularExpression = makeRegex(
        #"(?:^|[\s"'`({\[])((?:[/.])?(?:[\w.-]+/)*[\w.-]+\.\w+)(?::(\d+))?(?::(\d+))?"#,
        name: "filePath"
    )

    /// Eagerly touch every compiled regex so a bad pattern trips its
    /// `fatalError` at app launch rather than on first use.
    static func warmUp() {
        _ = url
        _ = filePath
    }
}

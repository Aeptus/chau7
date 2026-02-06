import Foundation
import AppKit

// MARK: - F08: Smart Syntax Highlighting

/// Helper to create regex with clear error messages (Fix #10: safe regex initialization)
private func makeRegex(_ pattern: String, options: NSRegularExpression.Options = [], name: String) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        fatalError("SyntaxHighlighter.\(name): Invalid pattern '\(pattern)' - \(error.localizedDescription)")
    }
}

/// Provides syntax highlighting for terminal output with caching and background processing.
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    // MARK: - Highlighting Cache (Performance Optimization)

    /// LRU cache for highlighted lines to avoid re-processing identical content
    private var highlightCache: [String: NSAttributedString] = [:]
    private let cacheQueue = DispatchQueue(label: "com.chau7.highlightCache")
    private let maxCacheSize = 500

    /// Background queue for expensive highlighting operations
    private let highlightQueue = DispatchQueue(label: "com.chau7.highlight", qos: .userInitiated)

    // MARK: - Pattern Definitions (Fix #10: safe regex initialization)

    /// URL pattern for clickable links
    private static let urlPattern = makeRegex(
        #"https?://[^\s<>\[\]{}|\\^`"']+"#,
        options: [.caseInsensitive],
        name: "urlPattern"
    )

    /// File path pattern (Unix-style)
    private static let pathPattern = makeRegex(
        #"(?:^|[\s])([/~][\w./-]+)"#,
        name: "pathPattern"
    )

    /// Error keywords pattern
    private static let errorPattern = makeRegex(
        #"\b(error|failed|failure|exception|fatal|critical|panic)\b"#,
        options: [.caseInsensitive],
        name: "errorPattern"
    )

    /// Warning keywords pattern
    private static let warningPattern = makeRegex(
        #"\b(warning|warn|deprecated|caution)\b"#,
        options: [.caseInsensitive],
        name: "warningPattern"
    )

    /// Success keywords pattern
    private static let successPattern = makeRegex(
        #"\b(success|passed|ok|done|complete|completed)\b"#,
        options: [.caseInsensitive],
        name: "successPattern"
    )

    /// Number pattern (integers, floats, hex)
    private static let numberPattern = makeRegex(
        #"\b(0x[0-9a-fA-F]+|\d+\.?\d*)\b"#,
        name: "numberPattern"
    )

    /// Quoted string pattern
    private static let stringPattern = makeRegex(
        #"([\"'])(?:(?!\1)[^\\]|\\.)*\1"#,
        name: "stringPattern"
    )

    /// JSON key pattern
    private static let jsonKeyPattern = makeRegex(
        #"\"(\w+)\"\s*:"#,
        name: "jsonKeyPattern"
    )

    /// Git branch/commit pattern
    private static let gitPattern = makeRegex(
        #"\b([a-f0-9]{7,40})\b|(?:origin/|HEAD\s*->?\s*)(\S+)"#,
        name: "gitPattern"
    )

    /// Command prompt pattern
    private static let promptPattern = makeRegex(
        #"^[\w@.-]+[:#$%>]\s"#,
        options: [.anchorsMatchLines],
        name: "promptPattern"
    )

    // MARK: - Highlight Colors

    private struct Colors {
        static let url = NSColor.systemBlue
        static let path = NSColor.systemCyan
        static let error = NSColor.systemRed
        static let warning = NSColor.systemOrange
        static let success = NSColor.systemGreen
        static let number = NSColor.systemPurple
        static let string = NSColor.systemYellow
        static let jsonKey = NSColor.systemTeal
        static let git = NSColor.systemPink
        static let prompt = NSColor.systemGray
    }

    private init() {}

    // MARK: - Highlighting

    /// Highlights a line of text and returns an attributed string.
    /// Uses caching to avoid re-processing identical lines.
    func highlight(_ text: String) -> NSAttributedString {
        guard FeatureSettings.shared.isSyntaxHighlightEnabled else {
            return NSAttributedString(string: text)
        }

        // Check cache first (thread-safe)
        var cachedResult: NSAttributedString?
        cacheQueue.sync {
            cachedResult = highlightCache[text]
        }
        if let cached = cachedResult {
            return cached
        }

        // Perform highlighting
        let result = performHighlight(text)

        // Cache the result (thread-safe, with size limit)
        cacheQueue.async { [weak self] in
            guard let self else { return }
            if self.highlightCache.count >= self.maxCacheSize {
                // Simple eviction: remove ~25% of entries
                let keysToRemove = Array(self.highlightCache.keys.prefix(self.maxCacheSize / 4))
                keysToRemove.forEach { self.highlightCache.removeValue(forKey: $0) }
            }
            self.highlightCache[text] = result
        }

        return result
    }

    /// Core highlighting logic (no caching)
    private func performHighlight(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)

        // Apply highlights in order (later patterns can override earlier ones)
        applyPattern(Self.numberPattern, to: attributed, in: range, color: Colors.number)
        applyPattern(Self.stringPattern, to: attributed, in: range, color: Colors.string)
        applyPattern(Self.pathPattern, to: attributed, in: range, color: Colors.path)

        if FeatureSettings.shared.isClickableURLsEnabled {
            applyURLPattern(to: attributed, in: range)
        }

        applyPattern(Self.jsonKeyPattern, to: attributed, in: range, color: Colors.jsonKey)
        applyPattern(Self.gitPattern, to: attributed, in: range, color: Colors.git)
        applyPattern(Self.promptPattern, to: attributed, in: range, color: Colors.prompt)

        // Status patterns last (most important)
        applyPattern(Self.successPattern, to: attributed, in: range, color: Colors.success)
        applyPattern(Self.warningPattern, to: attributed, in: range, color: Colors.warning)
        applyPattern(Self.errorPattern, to: attributed, in: range, color: Colors.error)

        return attributed
    }

    /// Highlights multiple lines efficiently using cache
    func highlightLines(_ lines: [String]) -> [NSAttributedString] {
        guard FeatureSettings.shared.isSyntaxHighlightEnabled else {
            return lines.map { NSAttributedString(string: $0) }
        }

        return lines.map { highlight($0) }
    }

    /// Highlights lines asynchronously on a background queue.
    /// - Parameters:
    ///   - lines: Lines to highlight
    ///   - completion: Called on main thread with results
    func highlightLinesAsync(_ lines: [String], completion: @escaping ([NSAttributedString]) -> Void) {
        guard FeatureSettings.shared.isSyntaxHighlightEnabled else {
            completion(lines.map { NSAttributedString(string: $0) })
            return
        }

        highlightQueue.async { [weak self] in
            guard let self else { return }
            let results = lines.map { self.highlight($0) }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// Clears the highlight cache (call when color settings change)
    func clearCache() {
        cacheQueue.async { [weak self] in
            self?.highlightCache.removeAll()
        }
    }

    // MARK: - Pattern Application

    private func applyPattern(
        _ pattern: NSRegularExpression,
        to attributed: NSMutableAttributedString,
        in range: NSRange,
        color: NSColor
    ) {
        pattern.enumerateMatches(in: attributed.string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func applyURLPattern(to attributed: NSMutableAttributedString, in range: NSRange) {
        Self.urlPattern.enumerateMatches(in: attributed.string, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let urlString = (attributed.string as NSString).substring(with: match.range)
            if let url = URL(string: urlString) {
                attributed.addAttributes([
                    .foregroundColor: Colors.url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ], range: match.range)
            }
        }
    }

}

// MARK: - Semantic Output Detector (F07 support)

/// Detects semantic meaning in terminal output for F07 search
final class SemanticOutputDetector: ObservableObject {
    /// Represents a detected command block
    struct CommandBlock: Identifiable {
        let id = UUID()
        let command: String
        let startRow: Int
        let endRow: Int
        let timestamp: Date
        var exitCode: Int32?
        var isError: Bool { exitCode != nil && exitCode != 0 }
    }

    /// Detected command blocks
    @Published private(set) var blocks: [CommandBlock] = []

    /// Current block being built
    private var currentBlock: (command: String, startRow: Int, lastRow: Int, timestamp: Date, exitCode: Int32?)?

    // MARK: - Detection

    /// Called when a command is entered
    func commandStarted(_ command: String, atRow row: Int) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }

        // Close any previous block
        if let current = currentBlock {
            blocks.append(CommandBlock(
                command: current.command,
                startRow: current.startRow,
                endRow: max(current.lastRow, current.startRow),
                timestamp: current.timestamp,
                exitCode: current.exitCode
            ))
        }

        currentBlock = (command, row, row, Date(), nil)
    }

    /// Called when a command finishes
    func commandFinished(atRow row: Int, exitCode: Int32) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }
        guard let current = currentBlock else { return }

        var block = CommandBlock(
            command: current.command,
            startRow: current.startRow,
            endRow: max(row, current.startRow),
            timestamp: current.timestamp
        )
        block.exitCode = exitCode
        blocks.append(block)
        currentBlock = nil
    }

    /// Update the last seen row for the active command block
    func updateCurrentRow(_ row: Int) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }
        guard var current = currentBlock else { return }
        if row > current.lastRow {
            current.lastRow = row
            currentBlock = current
        }
    }

    /// Finds blocks matching a query
    func search(query: String) -> [CommandBlock] {
        let lowercased = query.lowercased()
        var results = blocks.filter { block in
            block.command.lowercased().contains(lowercased)
        }
        if let current = currentBlock,
           current.command.lowercased().contains(lowercased) {
            results.append(CommandBlock(
                command: current.command,
                startRow: current.startRow,
                endRow: max(current.lastRow, current.startRow),
                timestamp: current.timestamp,
                exitCode: current.exitCode
            ))
        }
        return results
    }

    /// Finds error blocks
    func findErrors() -> [CommandBlock] {
        var results = blocks.filter { $0.isError }
        if let current = currentBlock,
           let exitCode = current.exitCode,
           exitCode != 0 {
            results.append(CommandBlock(
                command: current.command,
                startRow: current.startRow,
                endRow: max(current.lastRow, current.startRow),
                timestamp: current.timestamp,
                exitCode: exitCode
            ))
        }
        return results
    }

    /// Clears all tracked blocks
    func reset() {
        blocks.removeAll()
        currentBlock = nil
    }
}

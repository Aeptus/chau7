import Foundation

// MARK: - Snippet Parsing

/// Pure functions for snippet placeholder expansion and token replacement.
/// Extracted for testability.
public enum SnippetParsing {

    /// Represents a placeholder in a snippet
    public struct Placeholder: Equatable {
        public let index: Int
        public let start: Int
        public let length: Int

        public init(index: Int, start: Int, length: Int) {
            self.index = index
            self.start = start
            self.length = length
        }
    }

    /// Result of expanding placeholders in a snippet
    public struct ExpansionResult: Equatable {
        public let text: String
        public let placeholders: [Placeholder]
        public let finalCursorOffset: Int?

        public init(text: String, placeholders: [Placeholder], finalCursorOffset: Int?) {
            self.text = text
            self.placeholders = placeholders
            self.finalCursorOffset = finalCursorOffset
        }
    }

    // MARK: - Cached compiled patterns

    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\$\{(\d+)(?::([^}]*))?\}"#)
    private static let envTokenRegex = try! NSRegularExpression(pattern: #"\$\{env:([A-Za-z0-9_]+)\}"#)
    private static let hasPlaceholderRegex = try! Regex(#"\$\{\d+"#)

    // MARK: - Placeholder Expansion

    /// Expands placeholders in the format ${1}, ${2:default}, ${0} (final cursor)
    /// - Parameter input: The snippet text with placeholders
    /// - Returns: Expansion result with processed text and placeholder info
    public static func expandPlaceholders(in input: String) -> ExpansionResult {
        let range = NSRange(input.startIndex ..< input.endIndex, in: input)
        let matches = placeholderRegex.matches(in: input, range: range)

        guard !matches.isEmpty else {
            return ExpansionResult(text: input, placeholders: [], finalCursorOffset: nil)
        }

        var output = ""
        var placeholders: [Placeholder] = []
        var cursor = input.startIndex
        var currentLength = 0
        var finalOffset: Int?

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: input) else { continue }
            let before = input[cursor ..< fullRange.lowerBound]
            output.append(contentsOf: before)
            currentLength += before.count

            let indexString = Range(match.range(at: 1), in: input).map { String(input[$0]) } ?? "0"
            let index = Int(indexString) ?? 0
            let defaultText = Range(match.range(at: 2), in: input).map { String(input[$0]) } ?? ""

            output.append(contentsOf: defaultText)

            if index == 0 {
                finalOffset = currentLength + defaultText.count
            } else {
                placeholders.append(Placeholder(index: index, start: currentLength, length: defaultText.count))
            }
            currentLength += defaultText.count
            cursor = fullRange.upperBound
        }

        output.append(contentsOf: input[cursor ..< input.endIndex])

        let sorted = placeholders.sorted {
            if $0.index != $1.index {
                return $0.index < $1.index
            }
            return $0.start < $1.start
        }

        return ExpansionResult(text: output, placeholders: sorted, finalCursorOffset: finalOffset)
    }

    // MARK: - Environment Variable Replacement

    /// Replaces ${env:VARNAME} tokens with environment variable values
    /// - Parameter input: Text containing environment variable tokens
    /// - Returns: Text with environment variables expanded
    public static func replaceEnvTokens(in input: String) -> String {
        replaceEnvTokens(in: input, provider: { ProcessInfo.processInfo.environment[$0] ?? "" })
    }

    /// Replaces ${env:VARNAME} tokens using a custom provider (for testing)
    /// - Parameters:
    ///   - input: Text containing environment variable tokens
    ///   - provider: Function that returns value for an environment variable name
    /// - Returns: Text with environment variables expanded
    public static func replaceEnvTokens(in input: String, provider: (String) -> String) -> String {
        let range = NSRange(input.startIndex ..< input.endIndex, in: input)
        var output = input
        let matches = envTokenRegex.matches(in: input, range: range).reversed()

        for match in matches {
            guard match.numberOfRanges == 2,
                  let keyRange = Range(match.range(at: 1), in: output),
                  let fullRange = Range(match.range(at: 0), in: output) else { continue }
            let key = String(output[keyRange])
            let value = provider(key)
            output.replaceSubrange(fullRange, with: value)
        }

        return output
    }

    // MARK: - CSV Parsing

    /// Parses a comma-separated list of values
    /// - Parameter text: Comma-separated text
    /// - Returns: Array of trimmed, non-empty values
    public static func parseCSV(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Token Detection

    /// Checks if text contains any of the standard tokens
    public static func containsTokens(_ text: String) -> Bool {
        let tokens = ["${cwd}", "${home}", "${date}", "${time}", "${clip}"]
        return tokens.contains { text.contains($0) }
    }

    /// Checks if text contains environment variable tokens
    public static func containsEnvTokens(_ text: String) -> Bool {
        text.contains("${env:")
    }

    /// Checks if text contains placeholder syntax
    public static func containsPlaceholders(_ text: String) -> Bool {
        text.contains(hasPlaceholderRegex)
    }
}

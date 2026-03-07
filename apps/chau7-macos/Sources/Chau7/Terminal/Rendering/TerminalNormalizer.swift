import Foundation

// MARK: - Terminal Text Normalizer

/// Normalizes terminal output by processing control characters and escape sequences.
///
/// This utility handles:
/// - Backspace characters (^H, DEL) for proper character deletion
/// - ANSI escape sequences (colors, cursor movement, etc.)
/// - Other control characters (bell, form feed, etc.)
///
/// Used to convert raw terminal output to clean, displayable text.
enum TerminalNormalizer {

    // MARK: - Pre-compiled Regex (Memory Optimization)

    // Compiled once at startup instead of on every call (Fix #10: safe regex initialization)

    private static let ansiPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "\\u001B\\[[0-9;?]*[ -/]*[@-~]")
        } catch {
            fatalError("TerminalNormalizer.ansiPattern: Invalid pattern - \(error.localizedDescription)")
        }
    }()

    /// Fully normalizes terminal text by applying backspaces, stripping ANSI codes, and removing control characters.
    /// - Parameter input: Raw terminal text
    /// - Returns: Clean text suitable for display or searching
    static func normalize(_ input: String) -> String {
        var output = applyBackspaces(input)
        output = stripAnsi(output)
        output = stripControlChars(output)
        return output
    }

    /// Applies only backspace processing without stripping ANSI codes.
    /// Use this when you need to preserve color information for ANSI parsing.
    /// - Parameter input: Terminal text with potential backspace characters
    /// - Returns: Text with backspaces resolved
    static func applyBackspacesOnly(_ input: String) -> String {
        applyBackspaces(input)
    }

    private static func applyBackspaces(_ input: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(input.count)

        for ch in input {
            if ch == "\u{08}" || ch == "\u{7f}" {
                if !result.isEmpty {
                    result.removeLast()
                }
            } else {
                result.append(ch)
            }
        }

        return String(result)
    }

    private static func stripAnsi(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return ansiPattern.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    private static func stripControlChars(_ input: String) -> String {
        // Use reserveCapacity for better memory allocation
        var result = String()
        result.reserveCapacity(input.count)

        for scalar in input.unicodeScalars {
            if scalar == "\t" || scalar.value >= 0x20 {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }
}

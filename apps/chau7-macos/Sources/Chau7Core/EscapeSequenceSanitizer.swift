import Foundation

/// Utility for removing terminal escape sequences from text.
/// Used to clean messages for logging and history entries.
public enum EscapeSequenceSanitizer {
    /// Strips all terminal escape sequences from the input string.
    /// Handles CSI sequences, OSC sequences, focus events, cursor reports, and device attributes.
    ///
    /// - Parameter text: The input text potentially containing escape sequences
    /// - Returns: Clean text with all escape sequences removed
    public static func sanitize(_ text: String) -> String {
        var result = text

        // Order matters: process from most specific to most general

        // 1. OSC sequences: ESC ] ... ST (string terminator is BEL or ESC \)
        //    Examples: ]10;rgb:...\u{07}, ]7;file://...\u{07}
        //    Pattern: \e]...(\a|\e\\)
        result = result.replacingOccurrences(
            of: "\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)?",
            with: "",
            options: .regularExpression
        )
        // Also handle bare OSC without ESC prefix (sometimes appears in logs)
        result = result.replacingOccurrences(
            of: "\\][0-9;]*[^\\x07\\x1b]*(?:\\x07)?",
            with: "",
            options: .regularExpression
        )

        // 2. CSI sequences: ESC [ ... final_byte (0x40-0x7E)
        //    Examples: [O, [I (focus), [5;1R (cursor position), [?7u, [?65;4;1;2;6;21;22;17;28c
        //    Pattern: \e[...[@-~]
        result = result.replacingOccurrences(
            of: "\\x1b\\[[0-9;?]*[@-~]",
            with: "",
            options: .regularExpression
        )
        // Also handle bare CSI without ESC prefix
        result = result.replacingOccurrences(
            of: "\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )

        // 3. Bracketed paste markers: ESC [200~ and ESC [201~
        result = result.replacingOccurrences(
            of: "\\x1b\\[20[01]~",
            with: "",
            options: .regularExpression
        )
        // Bare versions
        result = result.replacingOccurrences(
            of: "\\[20[01]~",
            with: "",
            options: .regularExpression
        )

        // 4. Simple escape sequences: ESC followed by single char
        //    Examples: ESC c (reset), ESC 7/8 (save/restore cursor)
        result = result.replacingOccurrences(
            of: "\\x1b[^\\[\\]]",
            with: "",
            options: .regularExpression
        )

        // 5. Remove any remaining control characters except newlines/tabs
        result = result.unicodeScalars.filter { scalar in
            // Keep printable ASCII, newlines, tabs, and common whitespace
            if scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x09 {
                return true
            }
            // Remove control characters (0x00-0x1F except above, and 0x7F)
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
            return true
        }.map { Character($0) }.reduce(into: "") { $0.append($1) }

        // 6. Collapse multiple spaces into one
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Sanitizes text for logging purposes.
    /// More aggressive than basic sanitize - also limits length.
    ///
    /// - Parameters:
    ///   - text: The input text
    ///   - maxLength: Maximum length of output (default 500)
    /// - Returns: Sanitized text suitable for logging
    public static func sanitizeForLogging(_ text: String, maxLength: Int = 500) -> String {
        let sanitized = sanitize(text)
        if sanitized.count <= maxLength {
            return sanitized
        }
        return String(sanitized.prefix(maxLength - 3)) + "..."
    }

    /// Checks if the text contains escape sequences that should be sanitized.
    /// Useful for conditional logging.
    ///
    /// - Parameter text: The text to check
    /// - Returns: true if escape sequences are present
    public static func containsEscapeSequences(_ text: String) -> Bool {
        // Check for ESC character
        if text.contains("\u{1b}") {
            return true
        }
        // Check for common bare sequences that appear in logs
        let patterns = ["[O", "[I", "]10;", "]11;", "]7;", "[?", "[200~", "[201~"]
        for pattern in patterns {
            if text.contains(pattern) {
                return true
            }
        }
        return false
    }
}

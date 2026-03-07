import Foundation

/// Utility for removing terminal escape sequences from text.
/// Used to clean messages for logging and history entries.
public enum EscapeSequenceSanitizer {

    // MARK: - Precompiled regex patterns (compiled once at load time)

    /// 1. OSC: ESC ] ... (BEL | ESC \)
    private static let oscPattern = try! Regex(#"\x{1b}\][^\x{07}\x{1b}]*(?:\x{07}|\x{1b}\\)?"#)
    /// Bare OSC without ESC prefix
    private static let bareOscPattern = try! Regex(#"\][0-9;]*[^\x{07}\x{1b}]*(?:\x{07})?"#)
    /// 2. CSI: ESC [ params final_byte
    private static let csiPattern = try! Regex(#"\x{1b}\[[0-9;?]*[@-~]"#)
    /// Bare CSI without ESC prefix
    private static let bareCsiPattern = try! Regex(#"\[[0-9;?]*[A-Za-z]"#)
    // 3. Bracketed paste markers
    private static let pastePattern = try! Regex(#"\x{1b}\[20[01]~"#)
    private static let barePastePattern = try! Regex(#"\[20[01]~"#)
    /// 4. Simple escape: ESC + single char (not [ or ])
    private static let simpleEscPattern = try! Regex(#"\x{1b}[^\[\]]"#)

    /// Strips all terminal escape sequences from the input string.
    /// Handles CSI sequences, OSC sequences, focus events, cursor reports, and device attributes.
    ///
    /// - Parameter text: The input text potentially containing escape sequences
    /// - Returns: Clean text with all escape sequences removed
    public static func sanitize(_ text: String) -> String {
        if let rust = RustEscapeSanitizer.shared.sanitize(text) {
            return rust
        }
        return swiftSanitize(text)
    }

    private static func swiftSanitize(_ text: String) -> String {
        var result = text

        // Order matters: process from most specific to most general
        result.replace(Self.oscPattern, with: "")
        result.replace(Self.bareOscPattern, with: "")
        result.replace(Self.csiPattern, with: "")
        result.replace(Self.bareCsiPattern, with: "")
        result.replace(Self.pastePattern, with: "")
        result.replace(Self.barePastePattern, with: "")
        result.replace(Self.simpleEscPattern, with: "")

        // 5. Remove remaining control characters except newlines/tabs (single-pass)
        result = String(result.unicodeScalars.filter { scalar in
            if scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x09 {
                return true
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
            return true
        })

        // 6. Collapse multiple spaces into one (single-pass O(n))
        var collapsed = ""
        collapsed.reserveCapacity(result.count)
        var lastWasSpace = false
        for ch in result {
            if ch == " " {
                if !lastWasSpace { collapsed.append(ch) }
                lastWasSpace = true
            } else {
                collapsed.append(ch)
                lastWasSpace = false
            }
        }

        return collapsed.trimmingCharacters(in: .whitespaces)
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

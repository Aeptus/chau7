import Foundation

/// Clipboard text policy for terminal selections. TUIs can draw their own hard
/// wraps, which the screen buffer cannot distinguish from real line breaks.
public enum TerminalClipboard {
    public static func copiedText(_ text: String, fromTUI: Bool) -> String {
        fromTUI ? singleLine(text) : text
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

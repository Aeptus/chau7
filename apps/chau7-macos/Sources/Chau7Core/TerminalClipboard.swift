import Foundation

/// Clipboard text policy for terminal selections. TUIs can draw their own hard
/// wraps, which the screen buffer cannot distinguish from real line breaks.
public enum TerminalClipboard {
    public static func copiedText(_ text: String, fromTUI: Bool) -> String {
        fromTUI ? singleLine(text) : text
    }

    /// Reconstruct logical text from terminal rows without exposing their padding.
    /// Preserve spaces at soft wraps: they can separate command arguments.
    public static func gridText(rows: [String], softWrappedRows: Set<Int>) -> String {
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            if index > 0, softWrappedRows.contains(index) {
                lines[lines.count - 1] += row
            } else {
                if !lines.isEmpty { lines[lines.count - 1] = trimRowPadding(lines[lines.count - 1]) }
                lines.append(row)
            }
        }
        if !lines.isEmpty { lines[lines.count - 1] = trimRowPadding(lines[lines.count - 1]) }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func trimRowPadding(_ row: String) -> String {
        var end = row.endIndex
        while end > row.startIndex, row[row.index(before: end)] == " " {
            end = row.index(before: end)
        }
        return String(row[..<end])
    }

    static func singleLine(_ text: String) -> String {
        // Treat CRLF as one boundary so its LF is not mistaken for a blank row.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        let whitespace = CharacterSet.whitespaces
        var result = ""
        var previousEndsInWhitespace = false
        var blankRowSeparates = false

        for line in lines {
            let content = line.trimmingCharacters(in: whitespace)
            guard !content.isEmpty else {
                blankRowSeparates = !result.isEmpty
                continue
            }
            let beginsInWhitespace = line.unicodeScalars.first.map { whitespace.contains($0) } ?? false
            if !result.isEmpty, previousEndsInWhitespace || beginsInWhitespace || blankRowSeparates {
                result += " "
            }
            // A bare boundary can split a path, URL or other token. Keep it
            // contiguous; whitespace at either boundary separates arguments.
            result += content
            previousEndsInWhitespace = line.unicodeScalars.last.map { whitespace.contains($0) } ?? false
            blankRowSeparates = false
        }
        return result
    }
}

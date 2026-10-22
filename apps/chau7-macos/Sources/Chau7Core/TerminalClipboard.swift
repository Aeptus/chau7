import Foundation

/// Clipboard text policy for terminal selections. Keep explicit row breaks;
/// the terminal backend already joins rows that are true soft wraps.
public enum TerminalClipboard {
    public static func copiedText(_ text: String, fromTUI _: Bool) -> String {
        text
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

}

import Foundation

// MARK: - Input Line Tracker

/// Tracks which terminal rows contain user input (command prompts).
///
/// Used to identify and highlight command entry lines in the terminal display,
/// enabling features like:
/// - Visual distinction of input vs output
/// - Command history navigation
/// - Semantic output detection
///
/// Maintains a bounded set of row numbers to prevent unbounded memory growth.
final class InputLineTracker {
    private let maxEntries: Int
    private var rows: Set<Int> = []
    private var minTrackedRow: Int = 0

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    /// Records a row as containing user input.
    /// - Parameter row: The terminal row number (0-indexed)
    func record(row: Int) {
        rows.insert(row)
        if rows.count == 1 {
            minTrackedRow = row
        } else if row < minTrackedRow {
            minTrackedRow = row
        }
        pruneIfNeeded()
    }

    /// Returns input rows within the visible viewport.
    /// - Parameters:
    ///   - top: First visible row
    ///   - bottom: Last visible row
    /// - Returns: Array of row numbers that contain user input
    func visibleRows(top: Int, bottom: Int) -> [Int] {
        guard !rows.isEmpty else { return [] }
        return rows.filter { $0 >= top && $0 <= bottom }
    }

    /// Clears all tracked input rows.
    func reset() {
        rows.removeAll(keepingCapacity: true)
        minTrackedRow = 0
    }

    private func pruneIfNeeded() {
        guard rows.count > maxEntries else { return }
        if let minRow = rows.min() {
            minTrackedRow = minRow
        }
        while rows.count > maxEntries {
            rows.remove(minTrackedRow)
            minTrackedRow += 1
        }
    }
}

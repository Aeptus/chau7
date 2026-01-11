import Foundation

final class InputLineTracker {
    private let maxEntries: Int
    private var rows: Set<Int> = []
    private var minTrackedRow: Int = 0

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func record(row: Int) {
        rows.insert(row)
        if rows.count == 1 {
            minTrackedRow = row
        } else if row < minTrackedRow {
            minTrackedRow = row
        }
        pruneIfNeeded()
    }

    func visibleRows(top: Int, bottom: Int) -> [Int] {
        guard !rows.isEmpty else { return [] }
        return rows.filter { $0 >= top && $0 <= bottom }
    }

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

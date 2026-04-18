import Foundation

public enum MetalInstanceUpdatePlanner {
    public static func rowsToRefresh(
        totalRows: Int,
        dirtyRows: IndexSet,
        fullRefresh: Bool,
        previousCursorRow: Int?,
        currentCursorRow: Int?,
        cursorNeedsRefresh: Bool
    ) -> IndexSet {
        guard totalRows > 0 else { return [] }

        if fullRefresh {
            return IndexSet(integersIn: 0 ..< totalRows)
        }

        var rows = IndexSet()
        for row in dirtyRows where row >= 0 && row < totalRows {
            rows.insert(row)
        }

        guard cursorNeedsRefresh else { return rows }

        if let previousCursorRow, previousCursorRow >= 0, previousCursorRow < totalRows {
            rows.insert(previousCursorRow)
        }
        if let currentCursorRow, currentCursorRow >= 0, currentCursorRow < totalRows {
            rows.insert(currentCursorRow)
        }

        return rows
    }
}

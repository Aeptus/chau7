import Foundation

public enum RenderMemoryPressurePolicy {
    public static func ligatureEvictionCount(currentCount: Int, limit: Int) -> Int {
        guard currentCount > limit else { return 0 }
        guard limit > 0 else { return currentCount }

        let overflow = currentCount - limit
        let batch = max(limit / 16, 1)
        return min(currentCount, max(overflow, batch))
    }

    public static func retainedInlineImageIndices(
        anchorRows: [Int],
        displayOffset: Int,
        visibleRows: Int,
        rowMargin: Int,
        maxRetained: Int
    ) -> [Int] {
        guard maxRetained > 0 else { return [] }

        let safeVisibleRows = max(visibleRows, 0)
        let safeMargin = max(rowMargin, 0)
        let lowerBound = displayOffset - safeMargin
        let upperBound = displayOffset + safeVisibleRows + safeMargin

        let windowed = anchorRows.enumerated().compactMap { index, anchorRow in
            anchorRow >= lowerBound && anchorRow <= upperBound ? index : nil
        }

        guard windowed.count > maxRetained else { return windowed }
        return Array(windowed.suffix(maxRetained))
    }
}

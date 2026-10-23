public enum GridSyncStrategyPolicy {
    /// Use row-scoped updates whenever we have a trustworthy diff and at least
    /// one row changed, unless every visible row is dirty. Terminals frequently
    /// churn across many rows without truly replacing the full frame, so the
    /// partial path should remain the default as long as there is any clean row
    /// left to preserve.
    public static func shouldUsePartialSync(
        canCompare: Bool,
        dirtyRowCount: Int,
        gridRows: Int
    ) -> Bool {
        guard canCompare, dirtyRowCount > 0, gridRows > 0 else {
            return false
        }
        return dirtyRowCount < gridRows
    }
}

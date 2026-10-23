import Foundation

/// Deterministic limits for regenerable terminal memory. Authoritative PTY
/// content is never discarded to satisfy these limits: warm scrollback is
/// persisted before shrinking, and selected/live surfaces remain protected.
public enum TerminalMemoryBudgetPolicy {
    public static let defaultPerTabScrollbackBytes = 64 * 1024 * 1024
    public static let defaultPerTabRegenerableCacheBytes = 16 * 1024 * 1024
    public static let defaultGlobalRegenerableCacheBytes = 64 * 1024 * 1024

    public static func normalizedBudgetBytes(overrideMB: Int?, defaultBytes: Int) -> Int {
        guard let overrideMB, overrideMB > 0 else { return defaultBytes }
        return overrideMB * 1024 * 1024
    }

    public static func exceedsBudget(bytes: Int, budgetBytes: Int) -> Bool {
        bytes > max(0, budgetBytes)
    }

    /// Release the largest cold caches first. Visible selected panes stay hot,
    /// even if their combined working set exceeds the global target.
    public static func evictionIndices(cacheBytes: [Int], protectedIndices: Set<Int>, budgetBytes: Int) -> [Int] {
        let sizes = cacheBytes.map { max(0, $0) }
        var remaining = sizes.reduce(0, +)
        let budget = max(0, budgetBytes)
        let candidates = sizes.indices.filter { sizes[$0] > 0 && !protectedIndices.contains($0) }
            .sorted { sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0] > sizes[$1] }
        var evicted: [Int] = []
        for index in candidates {
            guard remaining > budget else { break }
            remaining -= sizes[index]
            evicted.append(index)
        }
        return evicted
    }

    /// Whole-window renderer resources are safe to evict only when AppKit says
    /// the surface cannot currently be seen. The triple-buffered last frame is
    /// retained separately for immediate tab switching inside visible windows.
    public static func shouldEvictRenderer(isWindowInvisible: Bool, allocatedBytes: Int) -> Bool {
        isWindowInvisible && allocatedBytes > 0
    }
}

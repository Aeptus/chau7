import Foundation

/// Deterministic limits for regenerable terminal memory. Authoritative PTY
/// content is never discarded to satisfy these limits: warm scrollback is
/// persisted before shrinking, and selected/live surfaces remain protected.
public enum TerminalMemoryBudgetPolicy {
    public static let defaultPerTabScrollbackBytes = 64 * 1_024 * 1_024
    public static let defaultPerTabRegenerableCacheBytes = 16 * 1_024 * 1_024

    public static func normalizedBudgetBytes(overrideMB: Int?, defaultBytes: Int) -> Int {
        guard let overrideMB, overrideMB > 0 else { return defaultBytes }
        return overrideMB * 1_024 * 1_024
    }

    public static func exceedsBudget(bytes: Int, budgetBytes: Int) -> Bool {
        bytes > max(0, budgetBytes)
    }

    /// Whole-window renderer resources are safe to evict only when AppKit says
    /// the surface cannot currently be seen. The triple-buffered last frame is
    /// retained separately for immediate tab switching inside visible windows.
    public static func shouldEvictRenderer(isWindowInvisible: Bool, allocatedBytes: Int) -> Bool {
        isWindowInvisible && allocatedBytes > 0
    }
}

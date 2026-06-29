import Foundation

/// Decides which restore source reflects the most recent save cycle.
///
/// Every save cycle stamps one fresh token onto the UserDefaults restore
/// index and the same token onto the file bundle's manifest. Token equality —
/// not timestamps — is the freshness signal, because unchanged-content saves
/// intentionally skip rewriting the bundle's sidecars (so the bundle's
/// `savedAt` legitimately lags while its content stays current).
public enum RestoreSourceArbiter {
    /// True when the bundle belongs to the latest save cycle and should be
    /// preferred (it carries full scrollback). False when the index advanced
    /// past the bundle — e.g. the bundle write failed for hours while the
    /// index kept saving — in which case restoring the bundle would resurrect
    /// a stale session.
    public static func bundleIsCurrent(bundleToken: String?, indexToken: String?) -> Bool {
        guard let indexToken else {
            // Pre-token index (or no index at all): no evidence against the
            // bundle; keep the historical bundle-first behavior.
            return true
        }
        guard let bundleToken else {
            // The index has a token but the bundle predates it: the bundle
            // missed at least one save cycle.
            return false
        }
        return bundleToken == indexToken
    }
}

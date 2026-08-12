import Foundation

/// Decides which restore source reflects the most recent save cycle.
///
/// Every save cycle stamps one fresh token onto the UserDefaults restore
/// index and the same token onto the file bundle's manifest. Token equality —
/// not timestamps — is the freshness signal, because unchanged-content saves
/// intentionally skip rewriting the bundle's sidecars (so the bundle's
/// `savedAt` legitimately lags while its content stays current).
public enum RestoreSourceArbiter {
    public enum Decision: Equatable {
        case bundleCurrent
        case bundleAheadOfIndex
        case indexCurrent
    }

    public static func decision(
        bundleToken: String?,
        bundlePreviousIndexToken: String? = nil,
        indexToken: String?
    ) -> Decision {
        guard let indexToken else { return .bundleCurrent }
        guard let bundleToken else { return .indexCurrent }
        if bundleToken == indexToken { return .bundleCurrent }

        // The bundle is committed before the index. If publication is
        // interrupted, its parent token proves that this bundle is the one
        // transaction newer source rather than a stale mismatched bundle.
        if bundlePreviousIndexToken == indexToken {
            return .bundleAheadOfIndex
        }
        return .indexCurrent
    }

    /// True when the bundle belongs to the latest save cycle and should be
    /// preferred (it carries full scrollback). False when the index advanced
    /// past the bundle — e.g. the bundle write failed for hours while the
    /// index kept saving — in which case restoring the bundle would resurrect
    /// a stale session.
    public static func bundleIsCurrent(
        bundleToken: String?,
        bundlePreviousIndexToken: String? = nil,
        indexToken: String?
    ) -> Bool {
        decision(
            bundleToken: bundleToken,
            bundlePreviousIndexToken: bundlePreviousIndexToken,
            indexToken: indexToken
        ) != .indexCurrent
    }
}

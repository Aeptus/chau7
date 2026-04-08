public enum ProtectedPathAutoAccessDecision: Equatable {
    case skipFeatureDisabled
    case skipCooldown
    case skipNeedsExplicitGrant
    case allowActiveScope
    case allowBookmarkedScope
}

public enum ProtectedPathAccessPolicy {
    public static func autoAccessDecision(
        isFeatureEnabled: Bool,
        hasActiveScope: Bool,
        hasSecurityScopedBookmark: Bool,
        isDeniedByCooldown: Bool
    ) -> ProtectedPathAutoAccessDecision {
        guard isFeatureEnabled else {
            return .skipFeatureDisabled
        }
        if hasActiveScope {
            return .allowActiveScope
        }
        if isDeniedByCooldown {
            return .skipCooldown
        }
        if hasSecurityScopedBookmark {
            return .allowBookmarkedScope
        }
        return .skipNeedsExplicitGrant
    }
}

public enum ProtectedPathAutoAccessDecision: Equatable {
    case skipFeatureDisabled
    case skipCooldown
    case skipNeedsExplicitGrant
    case skipStaleBookmark
    case allowActiveScope
    case allowBookmarkedScope
}

public enum ProtectedPathAccessState: String, Codable, Equatable {
    case unprotected
    case availableActiveScope
    case availableBookmarkedScope
    case blockedFeatureDisabled
    case blockedNeedsExplicitGrant
    case blockedCooldown
    case blockedStaleBookmark
}

public enum ProtectedPathRecommendedAction: String, Codable, Equatable {
    case none
    case enableFeature
    case grantAccess
    case waitForCooldown
    case regrantAccess
}

public struct ProtectedPathAccessSnapshot: Equatable, Codable {
    public let root: String?
    public let state: ProtectedPathAccessState
    public let canProbeLive: Bool
    public let canUseKnownIdentity: Bool
    public let hasKnownIdentity: Bool
    public let recommendedAction: ProtectedPathRecommendedAction

    public init(
        root: String?,
        state: ProtectedPathAccessState,
        canProbeLive: Bool,
        canUseKnownIdentity: Bool,
        hasKnownIdentity: Bool,
        recommendedAction: ProtectedPathRecommendedAction
    ) {
        self.root = root
        self.state = state
        self.canProbeLive = canProbeLive
        self.canUseKnownIdentity = canUseKnownIdentity
        self.hasKnownIdentity = hasKnownIdentity
        self.recommendedAction = recommendedAction
    }
}

public enum ProtectedPathAccessPolicy {
    public static func accessSnapshot(
        root: String?,
        isProtectedPath: Bool,
        isFeatureEnabled: Bool,
        hasActiveScope: Bool,
        hasSecurityScopedBookmark: Bool,
        isDeniedByCooldown: Bool,
        hasKnownIdentity: Bool,
        bookmarkResolveFailed: Bool = false
    ) -> ProtectedPathAccessSnapshot {
        guard isProtectedPath else {
            return ProtectedPathAccessSnapshot(
                root: nil,
                state: .unprotected,
                canProbeLive: true,
                canUseKnownIdentity: false,
                hasKnownIdentity: false,
                recommendedAction: .none
            )
        }

        if hasActiveScope {
            return ProtectedPathAccessSnapshot(
                root: root,
                state: .availableActiveScope,
                canProbeLive: true,
                canUseKnownIdentity: hasKnownIdentity,
                hasKnownIdentity: hasKnownIdentity,
                recommendedAction: .none
            )
        }

        if !isFeatureEnabled {
            return ProtectedPathAccessSnapshot(
                root: root,
                state: .blockedFeatureDisabled,
                canProbeLive: false,
                canUseKnownIdentity: hasKnownIdentity,
                hasKnownIdentity: hasKnownIdentity,
                recommendedAction: .enableFeature
            )
        }

        if bookmarkResolveFailed {
            return ProtectedPathAccessSnapshot(
                root: root,
                state: .blockedStaleBookmark,
                canProbeLive: false,
                canUseKnownIdentity: hasKnownIdentity,
                hasKnownIdentity: hasKnownIdentity,
                recommendedAction: .regrantAccess
            )
        }

        if isDeniedByCooldown {
            return ProtectedPathAccessSnapshot(
                root: root,
                state: .blockedCooldown,
                canProbeLive: false,
                canUseKnownIdentity: hasKnownIdentity,
                hasKnownIdentity: hasKnownIdentity,
                recommendedAction: .waitForCooldown
            )
        }

        if hasSecurityScopedBookmark {
            return ProtectedPathAccessSnapshot(
                root: root,
                state: .availableBookmarkedScope,
                canProbeLive: true,
                canUseKnownIdentity: hasKnownIdentity,
                hasKnownIdentity: hasKnownIdentity,
                recommendedAction: .none
            )
        }

        return ProtectedPathAccessSnapshot(
            root: root,
            state: .blockedNeedsExplicitGrant,
            canProbeLive: false,
            canUseKnownIdentity: hasKnownIdentity,
            hasKnownIdentity: hasKnownIdentity,
            recommendedAction: .grantAccess
        )
    }

    public static func autoAccessDecision(
        isFeatureEnabled: Bool,
        hasActiveScope: Bool,
        hasSecurityScopedBookmark: Bool,
        isDeniedByCooldown: Bool,
        bookmarkResolveFailed: Bool = false
    ) -> ProtectedPathAutoAccessDecision {
        let snapshot = accessSnapshot(
            root: nil,
            isProtectedPath: true,
            isFeatureEnabled: isFeatureEnabled,
            hasActiveScope: hasActiveScope,
            hasSecurityScopedBookmark: hasSecurityScopedBookmark,
            isDeniedByCooldown: isDeniedByCooldown,
            hasKnownIdentity: false,
            bookmarkResolveFailed: bookmarkResolveFailed
        )

        switch snapshot.state {
        case .availableActiveScope:
            return .allowActiveScope
        case .availableBookmarkedScope:
            return .allowBookmarkedScope
        case .blockedCooldown:
            return .skipCooldown
        case .blockedFeatureDisabled:
            return .skipFeatureDisabled
        case .blockedStaleBookmark:
            return .skipStaleBookmark
        case .blockedNeedsExplicitGrant:
            return .skipNeedsExplicitGrant
        case .unprotected:
            return .allowActiveScope
        }
    }
}

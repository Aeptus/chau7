public enum NotificationDropLogLevel: Equatable, Sendable {
    case trace
    case info
}

/// Separates deliberate provider-adapter filtering from ingress failures that
/// deserve a durable operational breadcrumb.
public enum NotificationDropLogPolicy {
    public static func level(for reason: String) -> NotificationDropLogLevel {
        let expectedFragments = [
            " is not user-facing",
            " is state-only; "
        ]
        if expectedFragments.contains(where: reason.contains) {
            return .trace
        }
        return .info
    }
}

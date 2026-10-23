import Foundation

public enum CodexFeedbackLookupPolicy {
    public static let fastRetryCount = 20

    /// Rollouts can appear well after launch. Keep discovery alive at low cost
    /// until the owning session stops, rather than latching a permanent miss.
    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt < fastRetryCount else { return 60 }
        return min(2, 0.25 * pow(1.45, Double(max(0, attempt))))
    }
}

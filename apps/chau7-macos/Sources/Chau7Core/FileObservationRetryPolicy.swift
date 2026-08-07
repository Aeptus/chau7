import Foundation

/// Backoff used while a watched path may be undergoing an atomic replacement.
/// Once the active window expires, callers should rely on an existing-parent
/// filesystem watch instead of continuing to poll the missing path.
public struct FileObservationRetryPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let activeRetryDuration: TimeInterval
    public let replacementDelay: TimeInterval

    public init(
        initialDelay: TimeInterval = 0.2,
        maximumDelay: TimeInterval = 5.0,
        activeRetryDuration: TimeInterval = 60.0,
        replacementDelay: TimeInterval = 0.2
    ) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
        self.activeRetryDuration = max(0, activeRetryDuration)
        self.replacementDelay = max(0, replacementDelay)
    }

    public func delay(forAttempt attempt: Int, elapsed: TimeInterval) -> TimeInterval? {
        guard elapsed < activeRetryDuration else { return nil }
        guard initialDelay > 0 else { return 0 }
        let exponent = min(max(0, attempt), 30)
        return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
    }

    public static let `default` = FileObservationRetryPolicy()
}

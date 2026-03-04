import Foundation

/// Token-bucket rate limiter for notification triggers.
/// Each trigger ID gets an independent bucket with configurable rate, burst, and cooldown.
///
/// Thread safety: all public methods are guarded by `@MainActor` since the notification
/// pipeline runs entirely on the main thread. No locks needed.
@MainActor
final class NotificationRateLimiter {

    struct Config: Codable, Equatable, Sendable {
        /// Maximum notifications per minute per trigger (token refill rate)
        var maxPerMinute: Int = 5
        /// Extra burst allowance above the per-minute rate
        var burstAllowance: Int = 3
        /// Minimum seconds between consecutive firings of the same trigger
        var cooldownSeconds: TimeInterval = 10

        static let `default` = Config()
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
        var lastFired: Date?
    }

    private var buckets: [String: Bucket] = [:]
    var config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// Atomically check whether a notification is allowed and consume a token if so.
    /// Returns `true` if the notification should proceed.
    func checkAndConsume(triggerId: String) -> Bool {
        let now = Date()
        var bucket = buckets[triggerId] ?? Bucket(
            tokens: Double(config.maxPerMinute + config.burstAllowance),
            lastRefill: now,
            lastFired: nil
        )

        // Refill tokens based on elapsed time
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        let refillRate = Double(config.maxPerMinute) / 60.0  // tokens per second
        let maxTokens = Double(config.maxPerMinute + config.burstAllowance)
        bucket.tokens = min(bucket.tokens + elapsed * refillRate, maxTokens)
        bucket.lastRefill = now

        // Check cooldown
        if let lastFired = bucket.lastFired,
           now.timeIntervalSince(lastFired) < config.cooldownSeconds {
            buckets[triggerId] = bucket
            return false
        }

        // Check token availability
        guard bucket.tokens >= 1.0 else {
            buckets[triggerId] = bucket
            return false
        }

        // Consume token and record firing
        bucket.tokens -= 1.0
        bucket.lastFired = now
        buckets[triggerId] = bucket
        return true
    }

    /// Reset all buckets (e.g., on settings change).
    func reset() {
        buckets.removeAll()
    }
}

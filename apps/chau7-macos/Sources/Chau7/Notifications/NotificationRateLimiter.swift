import Chau7Core
import Foundation

/// Token-bucket rate limiter for notification triggers.
/// Each trigger ID gets an independent bucket with configurable rate, burst, and cooldown.
///
/// Thread safety: all public methods are guarded by `@MainActor` since the notification
/// pipeline runs entirely on the main thread. No locks needed.
@MainActor
final class NotificationRateLimiter {

    struct Config: Codable, Equatable {
        /// Maximum notifications per minute per trigger (token refill rate)
        var maxPerMinute = 5
        /// Extra burst allowance above the per-minute rate
        var burstAllowance = 3
        /// Minimum seconds between consecutive firings of the same trigger
        var cooldownSeconds: TimeInterval = NotificationTimings.rateLimitCooldown

        static let `default` = Config()
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
        var lastFired: Date?
    }

    private var buckets: [String: Bucket] = [:]
    var config: Config

    /// Bucket-count above which `checkAndConsume` opportunistically prunes stale
    /// entries. Keys embed per-session/tab/CWD identity (and fall back to event
    /// UUIDs), so without pruning the map would grow unbounded.
    private static let pruneThreshold = 256

    init(config: Config = .default) {
        self.config = config
    }

    /// Atomically check whether a notification is allowed and consume a token if so.
    /// Returns `true` if the notification should proceed.
    func checkAndConsume(triggerId: String, now: Date = Date()) -> Bool {
        pruneStaleBuckets(now: now)
        var bucket = buckets[triggerId] ?? Bucket(
            tokens: Double(config.maxPerMinute + config.burstAllowance),
            lastRefill: now,
            lastFired: nil
        )

        // Refill tokens based on elapsed time
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        let refillRate = Double(config.maxPerMinute) / 60.0 // tokens per second
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

    /// Drops buckets that have fully refilled and are past cooldown — such a bucket
    /// is indistinguishable from a fresh one, so removing it frees memory without
    /// changing behavior. Only runs once the map exceeds `pruneThreshold`, bounding cost.
    private func pruneStaleBuckets(now: Date) {
        guard buckets.count > Self.pruneThreshold else { return }
        let maxTokens = Double(config.maxPerMinute + config.burstAllowance)
        let refillRate = Double(config.maxPerMinute) / 60.0
        let fullRefillWindow = refillRate > 0 ? maxTokens / refillRate : 0
        buckets = buckets.filter { _, bucket in
            let stillRefilling = now.timeIntervalSince(bucket.lastRefill) < fullRefillWindow
            let inCooldown = bucket.lastFired.map { now.timeIntervalSince($0) < config.cooldownSeconds } ?? false
            return stillRefilling || inCooldown
        }
    }

    /// Reset all buckets (e.g., on settings change).
    func reset() {
        buckets.removeAll()
    }
}

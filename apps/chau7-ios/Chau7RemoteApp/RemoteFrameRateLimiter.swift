import Foundation

/// Token-bucket rate limiter for inbound frames.
///
/// Used to throttle — not drop — a suspected flood from a hostile relay: when
/// the bucket is empty the receive loop reads more slowly instead of discarding
/// terminal data. Legitimate output is batched by the Mac, so normal sessions
/// stay well under the sustained rate.
struct RemoteFrameRateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date

    init(capacity: Double = 256, refillPerSecond: Double = 512, now: Date = Date()) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    /// Consumes one token; returns `false` when the sustained rate is exceeded
    /// (the caller should slow down rather than drop the frame).
    mutating func allow(now: Date = Date()) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

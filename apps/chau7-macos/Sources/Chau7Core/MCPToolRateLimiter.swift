import Foundation

/// Token-bucket rate limiter for MCP tool invocations.
/// Buckets are keyed by tool name so high-volume polling tools do not consume
/// the same budget as tab/session creation calls.
public struct MCPToolRateLimiter {
    public struct Limit: Equatable {
        public var maxPerMinute: Int
        public var burstAllowance: Int

        public init(maxPerMinute: Int, burstAllowance: Int) {
            self.maxPerMinute = max(0, maxPerMinute)
            self.burstAllowance = max(0, burstAllowance)
        }

        fileprivate var maxTokens: Double {
            Double(maxPerMinute + burstAllowance)
        }

        fileprivate var refillRatePerSecond: Double {
            Double(maxPerMinute) / 60.0
        }
    }

    public struct Config: Equatable {
        public var defaultLimit: Limit
        public var perToolLimits: [String: Limit]

        public init(defaultLimit: Limit, perToolLimits: [String: Limit] = [:]) {
            self.defaultLimit = defaultLimit
            self.perToolLimits = perToolLimits
        }

        public static let `default` = Config(
            defaultLimit: Limit(maxPerMinute: 120, burstAllowance: 30),
            perToolLimits: [
                "runtime_events_poll": Limit(maxPerMinute: 240, burstAllowance: 120),
                "runtime_turn_status": Limit(maxPerMinute: 240, burstAllowance: 120),
                "runtime_turn_wait": Limit(maxPerMinute: 180, burstAllowance: 60),
                "tab_output": Limit(maxPerMinute: 240, burstAllowance: 120),
                "tab_status": Limit(maxPerMinute: 240, burstAllowance: 120)
            ]
        )
    }

    public struct Decision: Equatable {
        public var isAllowed: Bool
        public var retryAfterSeconds: TimeInterval?

        public init(isAllowed: Bool, retryAfterSeconds: TimeInterval? = nil) {
            self.isAllowed = isAllowed
            self.retryAfterSeconds = retryAfterSeconds
        }
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    public var config: Config
    private var buckets: [String: Bucket] = [:]

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func evaluate(toolName: String, now: Date = Date()) -> Decision {
        let limit = config.perToolLimits[toolName] ?? config.defaultLimit
        var bucket = buckets[toolName] ?? Bucket(tokens: limit.maxTokens, lastRefill: now)

        let elapsed = max(0, now.timeIntervalSince(bucket.lastRefill))
        bucket.tokens = min(bucket.tokens + elapsed * limit.refillRatePerSecond, limit.maxTokens)
        bucket.lastRefill = now

        guard bucket.tokens >= 1 else {
            buckets[toolName] = bucket
            guard limit.refillRatePerSecond > 0 else {
                return Decision(isAllowed: false, retryAfterSeconds: nil)
            }
            let missingTokens = 1 - bucket.tokens
            return Decision(isAllowed: false, retryAfterSeconds: missingTokens / limit.refillRatePerSecond)
        }

        bucket.tokens -= 1
        buckets[toolName] = bucket
        return Decision(isAllowed: true)
    }

    public mutating func reset() {
        buckets.removeAll()
    }
}

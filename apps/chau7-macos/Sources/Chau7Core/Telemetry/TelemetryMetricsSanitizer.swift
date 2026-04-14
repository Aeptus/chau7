import Foundation

public enum TelemetryMetricsSanitizer {
    // Long-running local coding sessions can legitimately accumulate hundreds of
    // millions of billable tokens, especially on cached transcript replays.
    // Keep the guardrails high enough to reject obvious parser explosions without
    // invalidating real heavy sessions.
    private static let maxSingleFieldTokens = 1_000_000_000
    private static let maxBillableTokens = 2_000_000_000

    public static func sanitize(
        _ content: ExtractedRunContent,
        provider: String
    ) -> (content: ExtractedRunContent, warning: String?) {
        var sanitized = content

        let usage = TokenUsage(
            inputTokens: sanitized.totalInputTokens ?? 0,
            cacheCreationInputTokens: sanitized.totalCacheCreationInputTokens ?? 0,
            cacheReadInputTokens: sanitized.totalCacheReadInputTokens ?? 0,
            cachedInputTokens: sanitized.totalCachedInputTokens ?? 0,
            outputTokens: sanitized.totalOutputTokens ?? 0,
            reasoningOutputTokens: sanitized.totalReasoningOutputTokens ?? 0
        )

        if !usage.hasAnyTokens {
            sanitized.totalInputTokens = nil
            sanitized.totalCacheCreationInputTokens = nil
            sanitized.totalCacheReadInputTokens = nil
            sanitized.totalCachedInputTokens = nil
            sanitized.totalOutputTokens = nil
            sanitized.totalReasoningOutputTokens = nil
            sanitized.tokenUsageState = .missing
        } else if isImplausible(usage) {
            sanitized.totalInputTokens = nil
            sanitized.totalCacheCreationInputTokens = nil
            sanitized.totalCacheReadInputTokens = nil
            sanitized.totalCachedInputTokens = nil
            sanitized.totalOutputTokens = nil
            sanitized.totalReasoningOutputTokens = nil
            sanitized.costUSD = nil
            sanitized.tokenUsageState = .invalid
            sanitized.costState = .missing
            sanitized.costSource = .unavailable
            return (sanitized, "invalidated implausible token totals for provider=\(provider) total=\(usage.totalBillableTokens)")
        }

        if sanitized.costUSD == nil {
            sanitized.costState = .missing
            sanitized.costSource = .unavailable
        } else if sanitized.costState == .missing {
            sanitized.costState = .complete
            sanitized.costSource = sanitized.costSource ?? .observed
        }

        return (sanitized, nil)
    }

    private static func isImplausible(_ usage: TokenUsage) -> Bool {
        if usage.inputTokens > maxSingleFieldTokens { return true }
        if usage.cacheCreationInputTokens > maxSingleFieldTokens { return true }
        if usage.cacheReadInputTokens > maxSingleFieldTokens { return true }
        if usage.effectiveCachedInputTokens > maxSingleFieldTokens { return true }
        if usage.outputTokens > maxSingleFieldTokens { return true }
        if usage.reasoningOutputTokens > maxSingleFieldTokens { return true }
        if usage.totalBillableTokens > maxBillableTokens { return true }
        return false
    }
}

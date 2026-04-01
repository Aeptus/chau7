import Foundation

public enum TelemetryMetricsSanitizer {
    private static let maxSingleFieldTokens = 100_000_000
    private static let maxBillableTokens = 150_000_000

    public static func sanitize(
        _ content: ExtractedRunContent,
        provider: String
    ) -> (content: ExtractedRunContent, warning: String?) {
        var sanitized = content

        let usage = TokenUsage(
            inputTokens: sanitized.totalInputTokens ?? 0,
            cachedInputTokens: sanitized.totalCachedInputTokens ?? 0,
            outputTokens: sanitized.totalOutputTokens ?? 0,
            reasoningOutputTokens: sanitized.totalReasoningOutputTokens ?? 0
        )

        if !usage.hasAnyTokens {
            sanitized.totalInputTokens = nil
            sanitized.totalCachedInputTokens = nil
            sanitized.totalOutputTokens = nil
            sanitized.totalReasoningOutputTokens = nil
            sanitized.tokenUsageState = .missing
        } else if isImplausible(usage) {
            sanitized.totalInputTokens = nil
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
        if usage.cachedInputTokens > maxSingleFieldTokens { return true }
        if usage.outputTokens > maxSingleFieldTokens { return true }
        if usage.reasoningOutputTokens > maxSingleFieldTokens { return true }
        if usage.totalBillableTokens > maxBillableTokens { return true }
        return false
    }
}

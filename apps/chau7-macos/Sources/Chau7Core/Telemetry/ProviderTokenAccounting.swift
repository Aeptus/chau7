import Foundation

/// Converts provider-inclusive counters to Chau7's separate billable buckets.
public enum ProviderTokenAccounting {
    public static func uncachedInput(provider: String, input: Int?, cacheRead: Int?) -> Int? {
        guard let input else { return nil }
        switch provider.lowercased() {
        case "openai", "codex", "gemini": return max(0, input - max(0, cacheRead ?? 0))
        default: return input
        }
    }

    public static func visibleOutput(provider: String, output: Int?, reasoning: Int?) -> Int? {
        guard let output else { return nil }
        switch provider.lowercased() {
        case "openai", "codex": return max(0, output - max(0, reasoning ?? 0))
        default: return output
        }
    }
}

public extension UsageEvidence {
    var accountingInputTokens: Int? {
        guard sourceKind == .proxy, !uniqueEventKey.hasPrefix("run|") else { return inputTokens }
        return ProviderTokenAccounting.uncachedInput(provider: provider, input: inputTokens, cacheRead: cacheReadInputTokens)
    }

    var accountingOutputTokens: Int? {
        guard sourceKind == .proxy, !uniqueEventKey.hasPrefix("run|") else { return outputTokens }
        return ProviderTokenAccounting.visibleOutput(provider: provider, output: outputTokens, reasoning: reasoningOutputTokens)
    }

    var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: accountingInputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0,
            cachedInputTokens: (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0),
            outputTokens: accountingOutputTokens ?? 0,
            reasoningOutputTokens: reasoningOutputTokens ?? 0
        )
    }
}

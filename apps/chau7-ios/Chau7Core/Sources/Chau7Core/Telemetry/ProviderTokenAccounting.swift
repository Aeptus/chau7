import Foundation

/// Converts provider-inclusive counters to Chau7's separate billable buckets.
public enum ProviderTokenAccounting {
    public static let inclusiveInputProviders = ["openai", "codex", "chatgpt", "gemini", "google"]
    public static let inclusiveOutputProviders = ["openai", "codex", "chatgpt"]

    public static func uncachedInput(provider: String, input: Int?, cacheRead: Int?) -> Int? {
        guard let input else { return nil }
        let key = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inclusiveInputProviders.contains(key) ? max(0, input - max(0, cacheRead ?? 0)) : max(0, input)
    }

    public static func visibleOutput(provider: String, output: Int?, reasoning: Int?) -> Int? {
        guard let output else { return nil }
        let key = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inclusiveOutputProviders.contains(key) ? max(0, output - max(0, reasoning ?? 0)) : max(0, output)
    }

    public static func tokenUsage(provider: String, input: Int?, output: Int?, cacheCreation: Int?, cacheRead: Int?, reasoning: Int?) -> TokenUsage {
        let creation = max(0, cacheCreation ?? 0)
        let read = max(0, cacheRead ?? 0)
        return TokenUsage(
            inputTokens: uncachedInput(provider: provider, input: input, cacheRead: cacheRead) ?? 0,
            cacheCreationInputTokens: creation,
            cacheReadInputTokens: read,
            cachedInputTokens: creation + read,
            outputTokens: visibleOutput(provider: provider, output: output, reasoning: reasoning) ?? 0,
            reasoningOutputTokens: max(0, reasoning ?? 0)
        )
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

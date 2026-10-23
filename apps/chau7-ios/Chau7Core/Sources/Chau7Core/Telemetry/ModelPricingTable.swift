import Foundation

public struct ModelPricing: Codable, Equatable, Sendable {
    public let inputUSDPerMTok: Double
    public let cacheWriteUSDPerMTok: Double?
    public let cacheReadUSDPerMTok: Double
    public let outputUSDPerMTok: Double
    public let reasoningOutputUSDPerMTok: Double

    public init(
        inputUSDPerMTok: Double,
        cacheWriteUSDPerMTok: Double? = nil,
        cacheReadUSDPerMTok: Double,
        outputUSDPerMTok: Double,
        reasoningOutputUSDPerMTok: Double? = nil
    ) {
        self.inputUSDPerMTok = inputUSDPerMTok
        self.cacheWriteUSDPerMTok = cacheWriteUSDPerMTok
        self.cacheReadUSDPerMTok = cacheReadUSDPerMTok
        self.outputUSDPerMTok = outputUSDPerMTok
        self.reasoningOutputUSDPerMTok = reasoningOutputUSDPerMTok ?? outputUSDPerMTok
    }

    public func estimatedCostUSD(for usage: TokenUsage) -> Double {
        let uncategorizedCachedTokens = usage.uncategorizedCachedInputTokens
        let inputCost = Double(usage.inputTokens) * inputUSDPerMTok
        let cacheWriteCost = Double(usage.cacheCreationInputTokens) * (cacheWriteUSDPerMTok ?? inputUSDPerMTok)
        let cacheReadCost = Double(usage.cacheReadInputTokens) * cacheReadUSDPerMTok
        let uncategorizedCacheCost = Double(uncategorizedCachedTokens) * cacheReadUSDPerMTok
        let outputCost = Double(usage.outputTokens) * outputUSDPerMTok
        let reasoningCost = Double(usage.reasoningOutputTokens) * reasoningOutputUSDPerMTok
        let totalCost = inputCost + cacheWriteCost + cacheReadCost + uncategorizedCacheCost + outputCost + reasoningCost
        return totalCost / 1_000_000
    }

    public func estimatedCostUSD(for turnStats: TurnStats) -> Double {
        let inputCost = Double(turnStats.inputTokens) * inputUSDPerMTok
        let cacheWriteCost = Double(turnStats.cacheCreationTokens) * (cacheWriteUSDPerMTok ?? inputUSDPerMTok)
        let cacheReadCost = Double(turnStats.cacheReadTokens) * cacheReadUSDPerMTok
        let outputCost = Double(turnStats.outputTokens) * outputUSDPerMTok
        let reasoningCost = Double(turnStats.reasoningOutputTokens) * reasoningOutputUSDPerMTok
        let totalCost = inputCost + cacheWriteCost + cacheReadCost + outputCost + reasoningCost
        return totalCost / 1_000_000
    }
}

public enum ModelPricingTable {
    public static let version = "2026-04-13"

    private struct Entry: Sendable {
        let aliases: [String]
        let pricing: ModelPricing
    }

    private static let entries: [Entry] = [
        Entry(
            aliases: ["gpt-5.4", "gpt-5.4-chat-latest"],
            pricing: ModelPricing(inputUSDPerMTok: 2.50, cacheReadUSDPerMTok: 0.25, outputUSDPerMTok: 15.00)
        ),
        Entry(
            aliases: ["gpt-5.4-mini"],
            pricing: ModelPricing(inputUSDPerMTok: 0.75, cacheReadUSDPerMTok: 0.075, outputUSDPerMTok: 4.50)
        ),
        Entry(
            aliases: ["gpt-5.4-nano"],
            pricing: ModelPricing(inputUSDPerMTok: 0.20, cacheReadUSDPerMTok: 0.02, outputUSDPerMTok: 1.25)
        ),
        Entry(
            aliases: ["gpt-5.3-codex", "gpt-5.2-codex"],
            pricing: ModelPricing(inputUSDPerMTok: 1.75, cacheReadUSDPerMTok: 0.175, outputUSDPerMTok: 14.00)
        ),
        Entry(
            aliases: ["gpt-5.1-codex", "gpt-5-codex", "codex-mini-latest"],
            pricing: ModelPricing(inputUSDPerMTok: 1.25, cacheReadUSDPerMTok: 0.125, outputUSDPerMTok: 10.00)
        ),
        Entry(
            aliases: ["gpt-5.2", "gpt-5.2-chat-latest"],
            pricing: ModelPricing(inputUSDPerMTok: 1.75, cacheReadUSDPerMTok: 0.175, outputUSDPerMTok: 14.00)
        ),
        Entry(
            aliases: ["gpt-5.1", "gpt-5.1-chat-latest", "gpt-5", "gpt-5-chat-latest"],
            pricing: ModelPricing(inputUSDPerMTok: 1.25, cacheReadUSDPerMTok: 0.125, outputUSDPerMTok: 10.00)
        ),
        Entry(
            aliases: ["gpt-5-mini"],
            pricing: ModelPricing(inputUSDPerMTok: 0.25, cacheReadUSDPerMTok: 0.025, outputUSDPerMTok: 2.00)
        ),
        Entry(
            aliases: ["gpt-5-nano"],
            pricing: ModelPricing(inputUSDPerMTok: 0.05, cacheReadUSDPerMTok: 0.005, outputUSDPerMTok: 0.40)
        ),
        Entry(
            aliases: ["claude-opus-4.1", "claude-opus-4", "claude-opus-3"],
            pricing: ModelPricing(inputUSDPerMTok: 15.00, cacheWriteUSDPerMTok: 18.75, cacheReadUSDPerMTok: 1.50, outputUSDPerMTok: 75.00)
        ),
        Entry(
            aliases: ["claude-sonnet-4", "claude-sonnet-3.7", "claude-sonnet-3.5"],
            pricing: ModelPricing(inputUSDPerMTok: 3.00, cacheWriteUSDPerMTok: 3.75, cacheReadUSDPerMTok: 0.30, outputUSDPerMTok: 15.00)
        ),
        Entry(
            aliases: ["claude-haiku-3.5"],
            pricing: ModelPricing(inputUSDPerMTok: 0.80, cacheWriteUSDPerMTok: 1.00, cacheReadUSDPerMTok: 0.08, outputUSDPerMTok: 4.00)
        ),
        Entry(
            aliases: ["claude-haiku-3"],
            pricing: ModelPricing(inputUSDPerMTok: 0.25, cacheWriteUSDPerMTok: 0.30, cacheReadUSDPerMTok: 0.03, outputUSDPerMTok: 1.25)
        ),
        Entry(
            aliases: ["gemini-2.5-pro"],
            pricing: ModelPricing(inputUSDPerMTok: 1.25, cacheWriteUSDPerMTok: 0.125, cacheReadUSDPerMTok: 0.125, outputUSDPerMTok: 10.00)
        ),
        Entry(
            aliases: ["gemini-2.5-flash", "gemini-2.5-flash-preview-09-2025"],
            pricing: ModelPricing(inputUSDPerMTok: 0.30, cacheWriteUSDPerMTok: 0.03, cacheReadUSDPerMTok: 0.03, outputUSDPerMTok: 2.50)
        ),
        Entry(
            aliases: ["gemini-2.5-flash-lite", "gemini-2.5-flash-lite-preview-09-2025"],
            pricing: ModelPricing(inputUSDPerMTok: 0.10, cacheWriteUSDPerMTok: 0.01, cacheReadUSDPerMTok: 0.01, outputUSDPerMTok: 0.40)
        )
    ]

    /// Prefix → canonical-alias mapping for model IDs that didn't match an
    /// exact entry. Sorted by descending prefix length at static-init so the
    /// longest prefix wins — this makes the ordering explicit instead of
    /// hidden in the old sequential `if` ladder, where reorder would silently
    /// reroute, e.g., `gpt-5.2-codex` to `gpt-5.2` pricing.
    private struct PrefixRule: Sendable {
        let prefix: String
        let canonical: String
    }

    private static let prefixRules: [PrefixRule] = {
        let unsorted: [PrefixRule] = [
            // GPT-5.4 family — tier-specific variants before the bare model.
            PrefixRule(prefix: "gpt-5.4-mini", canonical: "gpt-5.4-mini"),
            PrefixRule(prefix: "gpt-5.4-nano", canonical: "gpt-5.4-nano"),
            PrefixRule(prefix: "gpt-5.4", canonical: "gpt-5.4"),
            // Codex models — 5.3/5.2 codex share pricing, 5.1/5 codex share pricing.
            PrefixRule(prefix: "gpt-5.3-codex", canonical: "gpt-5.3-codex"),
            PrefixRule(prefix: "gpt-5.2-codex", canonical: "gpt-5.3-codex"),
            PrefixRule(prefix: "gpt-5.1-codex", canonical: "gpt-5.1-codex"),
            PrefixRule(prefix: "gpt-5-codex", canonical: "gpt-5.1-codex"),
            // GPT-5.x and GPT-5 tiers — specific tiers before bare model.
            PrefixRule(prefix: "gpt-5.2", canonical: "gpt-5.2"),
            PrefixRule(prefix: "gpt-5.1", canonical: "gpt-5.1"),
            PrefixRule(prefix: "gpt-5-mini", canonical: "gpt-5-mini"),
            PrefixRule(prefix: "gpt-5-nano", canonical: "gpt-5-nano"),
            // Claude family fallback.
            PrefixRule(prefix: "claude-opus", canonical: "claude-opus-4.1"),
            PrefixRule(prefix: "claude-sonnet", canonical: "claude-sonnet-4"),
            PrefixRule(prefix: "claude-haiku", canonical: "claude-haiku-3.5"),
            // Gemini — flash-lite before flash (longest-prefix-wins handles this,
            // but keep adjacent for readability).
            PrefixRule(prefix: "gemini-2.5-pro", canonical: "gemini-2.5-pro"),
            PrefixRule(prefix: "gemini-2.5-flash-lite", canonical: "gemini-2.5-flash-lite"),
            PrefixRule(prefix: "gemini-2.5-flash", canonical: "gemini-2.5-flash")
        ]
        return unsorted.sorted { $0.prefix.count > $1.prefix.count }
    }()

    public static func pricing(for modelID: String?, providerHint: String? = nil) -> ModelPricing? {
        guard let normalized = normalize(modelID, providerHint: providerHint) else { return nil }
        if let exact = entries.first(where: { $0.aliases.contains(normalized) }) {
            return exact.pricing
        }
        for rule in prefixRules where normalized.hasPrefix(rule.prefix) {
            return pricing(for: rule.canonical, providerHint: providerHint)
        }
        return nil
    }

    public static func estimatedCostUSD(for usage: TokenUsage, modelID: String?, providerHint: String? = nil) -> Double? {
        pricing(for: modelID, providerHint: providerHint)?.estimatedCostUSD(for: usage)
    }

    public static func estimatedCostUSD(for turnStats: TurnStats, modelID: String?, providerHint: String? = nil) -> Double? {
        pricing(for: modelID, providerHint: providerHint)?.estimatedCostUSD(for: turnStats)
    }

    private static func normalize(_ modelID: String?, providerHint: String? = nil) -> String? {
        let candidate = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = providerHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = (candidate?.isEmpty == false ? candidate : fallback)?.lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "claude", "anthropic":
            return "claude-sonnet-4"
        case "codex", "openai", "gpt":
            return "gpt-5.3-codex"
        case "gemini", "google":
            return "gemini-2.5-flash"
        default:
            break
        }
        return raw
    }
}

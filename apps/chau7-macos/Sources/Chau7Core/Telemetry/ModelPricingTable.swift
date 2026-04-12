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
        (
            Double(usage.inputTokens) * inputUSDPerMTok
                + Double(usage.cachedInputTokens) * cacheReadUSDPerMTok
                + Double(usage.outputTokens) * outputUSDPerMTok
                + Double(usage.reasoningOutputTokens) * reasoningOutputUSDPerMTok
        ) / 1_000_000
    }

    public func estimatedCostUSD(for turnStats: TurnStats) -> Double {
        (
            Double(turnStats.inputTokens) * inputUSDPerMTok
                + Double(turnStats.cacheCreationTokens) * (cacheWriteUSDPerMTok ?? inputUSDPerMTok)
                + Double(turnStats.cacheReadTokens) * cacheReadUSDPerMTok
                + Double(turnStats.outputTokens) * outputUSDPerMTok
                + Double(turnStats.reasoningOutputTokens) * reasoningOutputUSDPerMTok
        ) / 1_000_000
    }
}

public enum ModelPricingTable {
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

    public static func pricing(for modelID: String?, providerHint: String? = nil) -> ModelPricing? {
        guard let normalized = normalize(modelID, providerHint: providerHint) else { return nil }
        if let exact = entries.first(where: { $0.aliases.contains(normalized) }) {
            return exact.pricing
        }

        if normalized.hasPrefix("claude-opus") {
            return pricing(for: "claude-opus-4.1", providerHint: providerHint)
        }
        if normalized.hasPrefix("claude-sonnet") {
            return pricing(for: "claude-sonnet-4", providerHint: providerHint)
        }
        if normalized.hasPrefix("claude-haiku") {
            return pricing(for: "claude-haiku-3.5", providerHint: providerHint)
        }
        if normalized.hasPrefix("gpt-5.4") {
            return pricing(for: normalized.contains("mini") ? "gpt-5.4-mini" : normalized.contains("nano") ? "gpt-5.4-nano" : "gpt-5.4")
        }
        if normalized.hasPrefix("gpt-5.3-codex") || normalized.hasPrefix("gpt-5.2-codex") {
            return pricing(for: "gpt-5.3-codex")
        }
        if normalized.hasPrefix("gpt-5.1-codex") || normalized.hasPrefix("gpt-5-codex") {
            return pricing(for: "gpt-5.1-codex")
        }
        if normalized.hasPrefix("gpt-5.2") {
            return pricing(for: "gpt-5.2")
        }
        if normalized.hasPrefix("gpt-5.1") || normalized == "gpt-5" {
            return pricing(for: "gpt-5.1")
        }
        if normalized.hasPrefix("gpt-5-mini") {
            return pricing(for: "gpt-5-mini")
        }
        if normalized.hasPrefix("gpt-5-nano") {
            return pricing(for: "gpt-5-nano")
        }
        if normalized.hasPrefix("gemini-2.5-pro") {
            return pricing(for: "gemini-2.5-pro")
        }
        if normalized.hasPrefix("gemini-2.5-flash-lite") {
            return pricing(for: "gemini-2.5-flash-lite")
        }
        if normalized.hasPrefix("gemini-2.5-flash") {
            return pricing(for: "gemini-2.5-flash")
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

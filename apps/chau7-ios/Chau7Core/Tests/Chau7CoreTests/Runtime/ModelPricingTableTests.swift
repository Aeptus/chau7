import XCTest
@testable import Chau7Core

final class ModelPricingTableTests: XCTestCase {
    func testResolvesKnownCodexModel() throws {
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "gpt-5.3-codex"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 1.75, accuracy: 0.0001)
        XCTAssertEqual(pricing.cacheReadUSDPerMTok, 0.175, accuracy: 0.0001)
        XCTAssertEqual(pricing.outputUSDPerMTok, 14.0, accuracy: 0.0001)
    }

    func testResolvesClaudeFamilyFallback() throws {
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "claude-sonnet-4.5-preview"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 3.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(pricing.cacheWriteUSDPerMTok), 3.75, accuracy: 0.0001)
        XCTAssertEqual(pricing.cacheReadUSDPerMTok, 0.30, accuracy: 0.0001)
        XCTAssertEqual(pricing.outputUSDPerMTok, 15.0, accuracy: 0.0001)
    }

    func testEstimatedCostUsesReasoningAndCacheBreakdown() throws {
        var stats = TurnStats()
        stats.addTokens(input: 1_000_000, output: 200_000, cacheCreation: 100_000, cacheRead: 300_000, reasoningOutput: 50000)

        let cost = try XCTUnwrap(ModelPricingTable.estimatedCostUSD(for: stats, modelID: "claude-sonnet-4"))
        XCTAssertEqual(cost, 7.215, accuracy: 0.0001)
    }

    func testEstimatedCostForAggregateUsageUsesCachedInputRate() throws {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 500_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 25000
        )
        let cost = try XCTUnwrap(ModelPricingTable.estimatedCostUSD(for: usage, modelID: "gpt-5.4-mini"))
        XCTAssertEqual(cost, 1.35, accuracy: 0.0001)
    }

    func testEstimatedCostForAggregateUsageUsesCacheWriteWhenBreakdownExists() throws {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cacheCreationInputTokens: 100_000,
            cacheReadInputTokens: 300_000,
            cachedInputTokens: 400_000,
            outputTokens: 200_000,
            reasoningOutputTokens: 50000
        )
        let cost = try XCTUnwrap(ModelPricingTable.estimatedCostUSD(for: usage, modelID: "claude-sonnet-4"))
        XCTAssertEqual(cost, 7.215, accuracy: 0.0001)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(ModelPricingTable.pricing(for: "unknown-model"))
        XCTAssertNil(ModelPricingTable.estimatedCostUSD(for: TokenUsage(inputTokens: 100), modelID: "unknown-model"))
    }

    func testProviderFallbackResolvesDefaultPricingFamily() throws {
        let codexCost = try XCTUnwrap(ModelPricingTable.estimatedCostUSD(
            for: TokenUsage(inputTokens: 1_000_000),
            modelID: nil,
            providerHint: "codex"
        ))
        XCTAssertEqual(codexCost, 1.75, accuracy: 0.0001)

        let claudeCost = try XCTUnwrap(ModelPricingTable.estimatedCostUSD(
            for: TokenUsage(inputTokens: 1_000_000),
            modelID: nil,
            providerHint: "claude"
        ))
        XCTAssertEqual(claudeCost, 3.0, accuracy: 0.0001)
    }

    // MARK: - Longest-prefix-wins (regression tests for the prefix-rule refactor)

    func testCodexPrefixWinsOverBareGPTPrefix() throws {
        // "gpt-5.2-codex" must route to gpt-5.3-codex pricing (Codex family),
        // NOT to "gpt-5.2" which has a shorter prefix. Before the prefix-rule
        // refactor this was order-dependent in the old `if` ladder.
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "gpt-5.2-codex-preview-2026-04"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 1.75, accuracy: 0.0001, "gpt-5.2-codex should route to Codex pricing, not gpt-5.2")
        XCTAssertEqual(pricing.outputUSDPerMTok, 14.00, accuracy: 0.0001)
    }

    func testGPT5CodexPrefixWinsOverBareGPT5() throws {
        // "gpt-5-codex-mini" shares the "gpt-5" prefix with bare gpt-5, but
        // the longer "gpt-5-codex" prefix must win.
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "gpt-5-codex-mini"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 1.25, accuracy: 0.0001, "gpt-5-codex-* must route to gpt-5.1-codex pricing")
    }

    func testGeminiFlashLiteWinsOverFlash() throws {
        // "gemini-2.5-flash-lite-preview" must route to flash-lite pricing,
        // not flash — the longer prefix wins regardless of declaration order.
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "gemini-2.5-flash-lite-preview-06-2025"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 0.10, accuracy: 0.0001, "flash-lite variants must not drop to flash pricing")
    }

    func testTierSpecificPrefixWinsForGPT54() throws {
        // Post-refactor: "gpt-5.4-mini-2026-03" routes to gpt-5.4-mini via
        // explicit prefix match (no more substring-based `contains("mini")`
        // heuristic). The old ternary would have matched any string with
        // "mini" anywhere after gpt-5.4; the new table requires the literal
        // "gpt-5.4-mini" prefix — which matches all real model names.
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "gpt-5.4-mini-2026-03"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 0.75, accuracy: 0.0001)
    }

    func testUnknownClaudeVariantFallsBackToFamilyPricing() throws {
        // Regression cover: the Claude family prefixes (opus/sonnet/haiku)
        // must still resolve unknown variants to the latest tier's pricing.
        let pricing = try XCTUnwrap(ModelPricingTable.pricing(for: "claude-opus-5-preview"))
        XCTAssertEqual(pricing.inputUSDPerMTok, 15.00, accuracy: 0.0001, "unknown Claude Opus variant should fall back to 4.1 pricing")
    }
}

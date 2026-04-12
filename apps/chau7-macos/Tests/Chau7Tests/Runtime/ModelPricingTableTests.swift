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
}

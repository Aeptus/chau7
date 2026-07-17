import XCTest
@testable import Chau7
@testable import Chau7Core

final class UsageNumberFormattingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UsageNumberFormattingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRegionalNumberFormatDefaultsToFrench() {
        let store = TerminalBehaviorStore(defaults: defaults)
        XCTAssertEqual(store.regionalNumberFormat, .french)
    }

    func testCountAbbreviationUsesSelectedRegionalSeparator() {
        let previous = FeatureSettings.shared.regionalNumberFormat
        defer { FeatureSettings.shared.regionalNumberFormat = previous }

        FeatureSettings.shared.regionalNumberFormat = .french
        XCTAssertEqual(CountFormat.abbreviated(1_200), "1,2K")

        FeatureSettings.shared.regionalNumberFormat = .unitedStates
        XCTAssertEqual(CountFormat.abbreviated(1_200), "1.2K")
    }

    func testPreciseCostFormattingDoesNotLeakFractionDigits() {
        let previous = FeatureSettings.shared.regionalNumberFormat
        defer { FeatureSettings.shared.regionalNumberFormat = previous }

        FeatureSettings.shared.regionalNumberFormat = .unitedStates
        XCTAssertEqual(LocalizedFormatters.formatCostPrecise(0.005), "$0.0050")
        XCTAssertEqual(LocalizedFormatters.formatCostPrecise(12.3), "$12.30")
    }

    func testProviderConsumptionUsesEffectiveCachedInputTokens() {
        let stats = ProviderConsumptionStats(
            provider: "codex",
            runCount: 1,
            totalInputTokens: 100,
            totalCachedInputTokens: 20,
            totalCacheCreationInputTokens: 30,
            totalCacheReadInputTokens: 40,
            totalOutputTokens: 50,
            totalReasoningOutputTokens: 10,
            totalCostUSD: 0.25
        )

        XCTAssertEqual(stats.effectiveCachedInputTokens, 70)
        XCTAssertEqual(stats.totalBillableTokens, 230)
    }
}

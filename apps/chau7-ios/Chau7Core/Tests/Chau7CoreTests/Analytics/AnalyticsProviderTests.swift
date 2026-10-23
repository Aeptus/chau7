import XCTest
import Chau7Core

final class AnalyticsProviderTests: XCTestCase {
    func testKeyBucketsOpenAIFamilyProvidersTogether() {
        XCTAssertEqual(AnalyticsProvider.key(for: "codex"), "openai")
        XCTAssertEqual(AnalyticsProvider.key(for: "ChatGPT"), "openai")
        XCTAssertEqual(AnalyticsProvider.key(for: "OpenAI"), "openai")
    }

    func testKeyBucketsAnthropicAndGoogleFamilies() {
        XCTAssertEqual(AnalyticsProvider.key(for: "Claude Code"), "anthropic")
        XCTAssertEqual(AnalyticsProvider.key(for: "anthropic"), "anthropic")
        XCTAssertEqual(AnalyticsProvider.key(for: "Gemini"), "google")
        XCTAssertEqual(AnalyticsProvider.key(for: "Google"), "google")
    }

    func testUnknownValuesRemainFilterable() {
        XCTAssertEqual(AnalyticsProvider.key(for: "shell"), "shell")
        XCTAssertEqual(AnalyticsProvider.displayName(for: "shell"), "Shell")
    }

    func testDisplayNameUsesVendorBranding() {
        XCTAssertEqual(AnalyticsProvider.displayName(for: "openai"), "OpenAI")
        XCTAssertEqual(AnalyticsProvider.displayName(for: "github"), "GitHub")
        XCTAssertEqual(AnalyticsProvider.displayName(for: "xai"), "xAI")
    }

    func testMatchesUsesCanonicalBuckets() {
        XCTAssertTrue(AnalyticsProvider.matches("codex", filterKey: "openai"))
        XCTAssertTrue(AnalyticsProvider.matches("Claude Code", filterKey: "anthropic"))
        XCTAssertFalse(AnalyticsProvider.matches("gemini", filterKey: "openai"))
        XCTAssertTrue(AnalyticsProvider.matches("gemini", filterKey: "all"))
    }
}

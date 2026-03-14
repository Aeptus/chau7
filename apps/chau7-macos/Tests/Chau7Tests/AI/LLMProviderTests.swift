import XCTest
@testable import Chau7Core

// MARK: - LLMProviderType Tests

final class LLMProviderTypeTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(LLMProviderType.allCases.count, 4)
    }

    func testIdentifiable() {
        XCTAssertEqual(LLMProviderType.openai.id, "openai")
        XCTAssertEqual(LLMProviderType.anthropic.id, "anthropic")
    }

    func testDisplayNames() {
        XCTAssertEqual(LLMProviderType.openai.displayName, "OpenAI")
        XCTAssertEqual(LLMProviderType.anthropic.displayName, "Anthropic")
        XCTAssertEqual(LLMProviderType.ollama.displayName, "Ollama")
        XCTAssertEqual(LLMProviderType.custom.displayName, "Custom")
    }

    func testDefaultEndpoints() {
        XCTAssertTrue(LLMProviderType.openai.defaultEndpoint.contains("openai.com"))
        XCTAssertTrue(LLMProviderType.anthropic.defaultEndpoint.contains("anthropic.com"))
        XCTAssertTrue(LLMProviderType.ollama.defaultEndpoint.contains("localhost"))
        XCTAssertEqual(LLMProviderType.custom.defaultEndpoint, "")
    }

    func testRequiresAPIKey() {
        XCTAssertTrue(LLMProviderType.openai.requiresAPIKey)
        XCTAssertTrue(LLMProviderType.anthropic.requiresAPIKey)
        XCTAssertFalse(LLMProviderType.ollama.requiresAPIKey)
        XCTAssertTrue(LLMProviderType.custom.requiresAPIKey)
    }

    func testDefaultModels() {
        XCTAssertFalse(LLMProviderType.openai.defaultModel.isEmpty)
        XCTAssertFalse(LLMProviderType.anthropic.defaultModel.isEmpty)
        XCTAssertFalse(LLMProviderType.ollama.defaultModel.isEmpty)
        XCTAssertEqual(LLMProviderType.custom.defaultModel, "")
    }

    func testCodableRoundTrip() throws {
        let original = LLMProviderType.anthropic
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMProviderType.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - LLMProviderConfig Tests

final class LLMProviderConfigTests: XCTestCase {

    func testInitWithDefaults() {
        let config = LLMProviderConfig(provider: .openai)

        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.apiKey, "")
        XCTAssertEqual(config.endpoint, LLMProviderType.openai.defaultEndpoint)
        XCTAssertEqual(config.model, LLMProviderType.openai.defaultModel)
        XCTAssertEqual(config.maxTokens, 1024)
    }

    func testInitWithCustomValues() {
        let config = LLMProviderConfig(
            provider: .custom,
            apiKey: "sk-test",
            endpoint: "https://my-llm.com/api",
            model: "my-model",
            maxTokens: 2048
        )

        XCTAssertEqual(config.endpoint, "https://my-llm.com/api")
        XCTAssertEqual(config.model, "my-model")
        XCTAssertEqual(config.maxTokens, 2048)
    }

    func testKeychainService() {
        let config = LLMProviderConfig(provider: .anthropic)
        XCTAssertEqual(config.keychainService, "com.chau7.llm.anthropic.apikey")
    }

    func testKeychainServiceUsesIsolationPrefixWhenConfigured() {
        let env = ["CHAU7_KEYCHAIN_SERVICE_PREFIX": "com.chau7.isolated"]
        let service = RuntimeIsolation.keychainServiceName(
            base: "com.chau7.llm.anthropic.apikey",
            environment: env
        )
        XCTAssertEqual(service, "com.chau7.isolated.com.chau7.llm.anthropic.apikey")
    }

    func testKeychainServiceIgnoresBlankIsolationPrefix() {
        let env = ["CHAU7_KEYCHAIN_SERVICE_PREFIX": "  "]
        let service = RuntimeIsolation.keychainServiceName(
            base: "com.chau7.llm.anthropic.apikey",
            environment: env
        )
        XCTAssertEqual(service, "com.chau7.llm.anthropic.apikey")
    }

    func testIsValidWithAPIKey() {
        let config = LLMProviderConfig(provider: .openai, apiKey: "sk-test")
        XCTAssertTrue(config.isValid)
    }

    func testIsInvalidWithoutRequiredAPIKey() {
        let config = LLMProviderConfig(provider: .openai, apiKey: "")
        XCTAssertFalse(config.isValid)
    }

    func testIsValidOllamaWithoutAPIKey() {
        let config = LLMProviderConfig(provider: .ollama)
        XCTAssertTrue(config.isValid)
    }

    func testIsInvalidWithEmptyEndpoint() {
        var config = LLMProviderConfig(provider: .ollama)
        config.endpoint = ""
        XCTAssertFalse(config.isValid)
    }

    func testIsInvalidWithEmptyModel() {
        var config = LLMProviderConfig(provider: .ollama)
        config.model = ""
        XCTAssertFalse(config.isValid)
    }

    func testIsInvalidWithZeroMaxTokens() {
        var config = LLMProviderConfig(provider: .ollama)
        config.maxTokens = 0
        XCTAssertFalse(config.isValid)
    }

    func testDefaultConfigsCoversAllProviders() {
        let configs = LLMProviderConfig.defaultConfigs
        for provider in LLMProviderType.allCases {
            XCTAssertNotNil(configs[provider], "\(provider) should have a default config")
        }
    }

    func testCodableRoundTrip() throws {
        let original = LLMProviderConfig(provider: .anthropic, apiKey: "key", maxTokens: 512)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        // apiKey is intentionally excluded from Codable (stored in Keychain)
        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.endpoint, original.endpoint)
        XCTAssertEqual(decoded.model, original.model)
        XCTAssertEqual(decoded.maxTokens, original.maxTokens)
        XCTAssertEqual(decoded.apiKey, "", "apiKey must not survive Codable round-trip")
    }
}

// MARK: - LLMRequest / LLMResponse Tests

final class LLMRequestResponseTests: XCTestCase {

    func testRequestInit() {
        let req = LLMRequest(systemPrompt: "You are helpful", userMessage: "Explain this error")
        XCTAssertEqual(req.systemPrompt, "You are helpful")
        XCTAssertEqual(req.userMessage, "Explain this error")
        XCTAssertEqual(req.maxTokens, 1024)
    }

    func testRequestCustomMaxTokens() {
        let req = LLMRequest(systemPrompt: "", userMessage: "", maxTokens: 256)
        XCTAssertEqual(req.maxTokens, 256)
    }

    func testResponseInit() {
        let resp = LLMResponse(content: "The error means...", tokensUsed: 150, model: "gpt-4o")
        XCTAssertEqual(resp.content, "The error means...")
        XCTAssertEqual(resp.tokensUsed, 150)
        XCTAssertEqual(resp.model, "gpt-4o")
    }

    func testResponseNilTokens() {
        let resp = LLMResponse(content: "answer", model: "model")
        XCTAssertNil(resp.tokensUsed)
    }
}

// MARK: - ExplanationConfidence / FixRiskLevel Tests

final class ExplanationModelsTests: XCTestCase {

    func testConfidenceCodableRoundTrip() throws {
        for confidence in [ExplanationConfidence.high, .medium, .low] {
            let data = try JSONEncoder().encode(confidence)
            let decoded = try JSONDecoder().decode(ExplanationConfidence.self, from: data)
            XCTAssertEqual(decoded, confidence)
        }
    }

    func testFixRiskLevelCodableRoundTrip() throws {
        for level in [FixRiskLevel.safe, .moderate, .dangerous] {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(FixRiskLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    func testErrorExplanationInit() {
        let explanation = ErrorExplanation(
            summary: "Permission denied",
            details: "The file is read-only",
            suggestedFix: "chmod +w file.txt",
            confidence: .high
        )

        XCTAssertEqual(explanation.summary, "Permission denied")
        XCTAssertEqual(explanation.details, "The file is read-only")
        XCTAssertEqual(explanation.suggestedFix, "chmod +w file.txt")
        XCTAssertEqual(explanation.confidence, .high)
    }

    func testErrorExplanationDefaults() {
        let explanation = ErrorExplanation(summary: "Error", details: "Details")
        XCTAssertNil(explanation.suggestedFix)
        XCTAssertEqual(explanation.confidence, .medium)
    }

    func testErrorExplanationEquality() {
        let a = ErrorExplanation(summary: "E", details: "D", confidence: .low)
        let b = ErrorExplanation(summary: "E", details: "D", confidence: .low)
        XCTAssertEqual(a, b)
    }

    func testFixSuggestionInit() {
        let fix = FixSuggestion(
            description: "Change permissions",
            command: "chmod 644 file.txt",
            riskLevel: .moderate
        )

        XCTAssertEqual(fix.description, "Change permissions")
        XCTAssertEqual(fix.command, "chmod 644 file.txt")
        XCTAssertEqual(fix.riskLevel, .moderate)
    }

    func testFixSuggestionDefaultRisk() {
        let fix = FixSuggestion(description: "List files", command: "ls")
        XCTAssertEqual(fix.riskLevel, .safe)
    }

    func testFixSuggestionEquality() {
        let a = FixSuggestion(description: "d", command: "c", riskLevel: .dangerous)
        let b = FixSuggestion(description: "d", command: "c", riskLevel: .dangerous)
        XCTAssertEqual(a, b)
    }
}

import Foundation

// MARK: - LLM Provider Types

/// Supported LLM provider backends for the "Explain This Error" / BYOAI feature.
public enum LLMProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic
    case ollama
    case custom

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        case .custom: return "Custom"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .ollama: return "http://localhost:11434/api/chat"
        case .custom: return ""
        }
    }

    /// Whether this provider requires an API key
    public var requiresAPIKey: Bool {
        switch self {
        case .openai, .anthropic, .custom: return true
        case .ollama: return false
        }
    }

    /// Default model for this provider
    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .ollama: return "llama3.2"
        case .custom: return ""
        }
    }
}

// MARK: - LLM Provider Configuration

/// Configuration for an LLM provider, including endpoint, model, and token limits.
/// API keys are stored separately in the Keychain (not serialized here).
public struct LLMProviderConfig: Codable, Equatable, Sendable {
    public var provider: LLMProviderType
    public var apiKey: String // Stored in Keychain, transient in memory — excluded from Codable
    public var endpoint: String
    public var model: String
    public var maxTokens: Int

    /// Exclude apiKey from serialization — it belongs in the Keychain.
    private enum CodingKeys: String, CodingKey {
        case provider, endpoint, model, maxTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(LLMProviderType.self, forKey: .provider)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.model = try container.decode(String.self, forKey: .model)
        self.maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        self.apiKey = "" // Must be loaded from Keychain separately
    }

    public init(provider: LLMProviderType, apiKey: String = "", endpoint: String? = nil, model: String? = nil, maxTokens: Int = 1024) {
        self.provider = provider
        self.apiKey = apiKey
        self.endpoint = endpoint ?? provider.defaultEndpoint
        self.model = model ?? provider.defaultModel
        self.maxTokens = maxTokens
    }

    /// Default configurations for each provider type
    public static var defaultConfigs: [LLMProviderType: LLMProviderConfig] {
        var configs: [LLMProviderType: LLMProviderConfig] = [:]
        for providerType in LLMProviderType.allCases {
            configs[providerType] = LLMProviderConfig(provider: providerType)
        }
        return configs
    }

    /// Keychain service identifier for this provider's API key
    public var keychainService: String {
        RuntimeIsolation.keychainServiceName(
            base: "com.chau7.llm.\(provider.rawValue).apikey"
        )
    }

    /// Validates that the configuration has the minimum required fields
    public var isValid: Bool {
        if provider.requiresAPIKey, apiKey.isEmpty { return false }
        if endpoint.isEmpty { return false }
        if model.isEmpty { return false }
        if maxTokens < 1 { return false }
        return true
    }
}

// MARK: - LLM Request

/// A request to send to an LLM provider.
public struct LLMRequest: Sendable {
    public let systemPrompt: String
    public let userMessage: String
    public let maxTokens: Int

    public init(systemPrompt: String, userMessage: String, maxTokens: Int = 1024) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.maxTokens = maxTokens
    }
}

// MARK: - LLM Response

/// A response received from an LLM provider.
public struct LLMResponse: Sendable {
    public let content: String
    public let tokensUsed: Int?
    public let model: String

    public init(content: String, tokensUsed: Int? = nil, model: String) {
        self.content = content
        self.tokensUsed = tokensUsed
        self.model = model
    }
}

// MARK: - Error Explanation Models

/// Confidence level for an error explanation
public enum ExplanationConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

/// Risk level for a suggested fix
public enum FixRiskLevel: String, Codable, Sendable {
    case safe // Read-only or reversible
    case moderate // Modifies files but recoverable
    case dangerous // Could cause data loss or system changes
}

/// Structured explanation of a terminal error
public struct ErrorExplanation: Equatable, Sendable {
    public let summary: String
    public let details: String
    public let suggestedFix: String?
    public let confidence: ExplanationConfidence

    public init(summary: String, details: String, suggestedFix: String? = nil, confidence: ExplanationConfidence = .medium) {
        self.summary = summary
        self.details = details
        self.suggestedFix = suggestedFix
        self.confidence = confidence
    }
}

/// A suggested fix for a terminal error
public struct FixSuggestion: Equatable, Sendable {
    public let description: String
    public let command: String
    public let riskLevel: FixRiskLevel

    public init(description: String, command: String, riskLevel: FixRiskLevel = .safe) {
        self.description = description
        self.command = command
        self.riskLevel = riskLevel
    }
}

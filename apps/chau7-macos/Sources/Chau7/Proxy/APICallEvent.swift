import Foundation
import Chau7Core

// MARK: - API Call Event

/// Represents a captured API call from the proxy server.
/// This model is used to track LLM API usage, costs, and performance metrics.
public struct APICallEvent: Identifiable, Codable, Equatable, Sendable {
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    public let id: UUID
    public let sessionId: String
    public let provider: Provider
    public let model: String
    public let endpoint: String
    public let observedInputTokens: Int?
    public let observedOutputTokens: Int?
    public let observedCacheCreationInputTokens: Int?
    public let observedCacheReadInputTokens: Int?
    public let observedReasoningOutputTokens: Int?
    public let latencyMs: Int
    public let statusCode: Int
    public let observedCostUSD: Double?
    public let pricingVersion: String?
    public let timestamp: Date
    public let errorMessage: String?
    public let projectPath: String?

    // MARK: - Computed Properties

    public var inputTokens: Int {
        observedInputTokens ?? 0
    }

    public var outputTokens: Int {
        observedOutputTokens ?? 0
    }

    public var cacheCreationInputTokens: Int {
        observedCacheCreationInputTokens ?? 0
    }

    public var cacheReadInputTokens: Int {
        observedCacheReadInputTokens ?? 0
    }

    public var reasoningOutputTokens: Int {
        observedReasoningOutputTokens ?? 0
    }

    public var costUSD: Double {
        observedCostUSD ?? 0
    }

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Total including cache and reasoning — actual billable usage.
    public var totalBillableTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens + reasoningOutputTokens
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cachedInputTokens: cacheCreationInputTokens + cacheReadInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens
        )
    }

    public var isSuccess: Bool {
        (200 ..< 300).contains(statusCode)
    }

    public var hasError: Bool {
        errorMessage != nil && !errorMessage!.isEmpty
    }

    public var formattedCost: String {
        LocalizedFormatters.formatCostPrecise(costUSD)
    }

    public var formattedLatency: String {
        if latencyMs < 1000 {
            return "\(latencyMs)ms"
        }
        return String(format: "%.1fs", Double(latencyMs) / 1000.0)
    }

    public var formattedTokens: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalTokens)) ?? "\(totalTokens)"
    }

    public var formattedHour: String {
        Self.hourFormatter.string(from: timestamp)
    }

    public var projectName: String? {
        guard let projectPath,
              !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        sessionId: String,
        provider: Provider,
        model: String,
        endpoint: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        latencyMs: Int,
        statusCode: Int,
        costUSD: Double? = nil,
        pricingVersion: String? = nil,
        timestamp: Date = Date(),
        errorMessage: String? = nil,
        projectPath: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.observedInputTokens = inputTokens
        self.observedOutputTokens = outputTokens
        self.observedCacheCreationInputTokens = cacheCreationInputTokens
        self.observedCacheReadInputTokens = cacheReadInputTokens
        self.observedReasoningOutputTokens = reasoningOutputTokens
        self.latencyMs = latencyMs
        self.statusCode = statusCode
        self.observedCostUSD = costUSD
        self.pricingVersion = pricingVersion
        self.timestamp = timestamp
        self.errorMessage = errorMessage
        self.projectPath = projectPath
    }

    // MARK: - AIEvent Conversion

    /// Convert to AIEvent for unified event handling in Chau7
    public func toAIEvent() -> AIEvent {
        let message = "\(model): \(formattedTokens) tokens (\(formattedCost))"
        return AIEvent(
            id: id,
            source: .apiProxy,
            type: isSuccess ? "api_call" : "api_error",
            tool: provider.displayName,
            message: message,
            ts: ISO8601DateFormatter().string(from: timestamp)
        )
    }
}

// MARK: - Provider Enum

public extension APICallEvent {
    /// Supported LLM API providers
    enum Provider: String, Codable, CaseIterable, Sendable {
        case anthropic
        case openai
        case gemini
        case unknown

        public var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            case .gemini: return "Google"
            case .unknown: return "Unknown"
            }
        }

        public var iconSystemName: String {
            switch self {
            case .anthropic: return "brain.head.profile"
            case .openai: return "sparkles"
            case .gemini: return "diamond"
            case .unknown: return "questionmark.circle"
            }
        }

        public var colorName: String {
            switch self {
            case .anthropic: return "purple"
            case .openai: return "green"
            case .gemini: return "blue"
            case .unknown: return "gray"
            }
        }

        /// Base URL for the provider's API
        public var apiBaseURL: String {
            switch self {
            case .anthropic: return "https://api.anthropic.com"
            case .openai: return "https://api.openai.com"
            case .gemini: return "https://generativelanguage.googleapis.com"
            case .unknown: return ""
            }
        }
    }
}

// Note: ProxyIPCMessage and ProxyIPCData types are defined in ProxyIPCServer.swift

// MARK: - Analytics Aggregation

/// Aggregated statistics for API calls
public struct APICallStats: Equatable, Sendable {
    public let callCount: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCacheCreationTokens: Int
    public let totalCacheReadTokens: Int
    public let totalReasoningTokens: Int
    public let totalCost: Double
    public let averageLatencyMs: Double

    public var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    /// All tokens including cache and reasoning.
    public var totalAllTokens: Int {
        totalInputTokens + totalOutputTokens + totalCacheCreationTokens + totalCacheReadTokens + totalReasoningTokens
    }

    public init(
        callCount: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalCacheCreationTokens: Int = 0,
        totalCacheReadTokens: Int = 0,
        totalReasoningTokens: Int = 0,
        totalCost: Double = 0,
        averageLatencyMs: Double = 0
    ) {
        self.callCount = callCount
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalReasoningTokens = totalReasoningTokens
        self.totalCost = totalCost
        self.averageLatencyMs = averageLatencyMs
    }

    /// Compute stats from a collection of events
    public static func from(_ events: [APICallEvent]) -> APICallStats {
        guard !events.isEmpty else { return APICallStats() }

        let totalInput = events.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = events.reduce(0) { $0 + $1.outputTokens }
        let totalCacheCreation = events.reduce(0) { $0 + $1.cacheCreationInputTokens }
        let totalCacheRead = events.reduce(0) { $0 + $1.cacheReadInputTokens }
        let totalReasoning = events.reduce(0) { $0 + $1.reasoningOutputTokens }
        let totalCost = events.reduce(0) { $0 + $1.costUSD }
        let avgLatency = Double(events.reduce(0) { $0 + $1.latencyMs }) / Double(events.count)

        return APICallStats(
            callCount: events.count,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCacheCreationTokens: totalCacheCreation,
            totalCacheReadTokens: totalCacheRead,
            totalReasoningTokens: totalReasoning,
            totalCost: totalCost,
            averageLatencyMs: avgLatency
        )
    }
}

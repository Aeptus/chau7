import Foundation
import Observation

enum TokenRateSource: String, Sendable, Equatable {
    case proxyStreamEstimate
    case proxyUsage
    case proxyRequestUsage
    case proxyEstimatedUsage
    case claudeTranscript
    case codexTranscript

    var isEstimated: Bool {
        return switch self {
        case .proxyUsage: false
        case .proxyStreamEstimate, .proxyRequestUsage, .proxyEstimatedUsage, .claudeTranscript, .codexTranscript: true
        }
    }

    var description: String {
        return switch self {
        case .proxyStreamEstimate: "Estimated from text deltas in the live API stream."
        case .proxyUsage: "Provider-reported output tokens divided by time from first response byte to completion."
        case .proxyRequestUsage: "Provider-reported output tokens divided by total non-streaming request time, including setup and prefill."
        case .proxyEstimatedUsage: "Proxy-estimated output tokens divided by generation time."
        case .claudeTranscript: "Estimated from Claude transcript usage and timestamps; includes tool and response delay."
        case .codexTranscript: "Estimated from Codex rollout usage and timestamps; includes tool and response delay."
        }
    }
}

struct TokenRateReading: Sendable, Equatable {
    let provider: String
    let tokensPerSecond: Double
    let outputTokens: Int
    let durationMs: Int
    let source: TokenRateSource
    let updatedAt: Date

    var formattedRate: String {
        let prefix = source.isEstimated ? "~" : ""
        return "\(prefix)\(Int(tokensPerSecond.rounded())) t/s"
    }

    var detail: String {
        "\(formattedRate) · \(provider) · \(outputTokens) output tokens in \(String(format: "%.1f", Double(durationMs) / 1000))s. \(source.description)"
    }
}

@Observable
@MainActor
final class TokenRateStore {
    static let shared = TokenRateStore()

    private(set) var readingsByTabID: [String: TokenRateReading] = [:]

    func reading(for tabID: String) -> TokenRateReading? {
        readingsByTabID[tabID]
    }

    func record(
        tabID: String,
        provider: String,
        outputTokens: Int,
        durationMs: Int,
        source: TokenRateSource,
        updatedAt: Date = Date()
    ) {
        guard !tabID.isEmpty, tabID != "default",
              outputTokens > 0, durationMs > 0 else { return }

        let tokensPerSecond = Double(outputTokens) * 1000 / Double(durationMs)
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        guard shouldReplaceReading(for: tabID, source: source, updatedAt: updatedAt) else { return }

        readingsByTabID[tabID] = TokenRateReading(
            provider: provider,
            tokensPerSecond: tokensPerSecond,
            outputTokens: outputTokens,
            durationMs: durationMs,
            source: source,
            updatedAt: updatedAt
        )

        if readingsByTabID.count > 512 {
            let retainedIDs = Set(readingsByTabID
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(384)
                .map { $0.key })
            readingsByTabID = readingsByTabID.filter { retainedIDs.contains($0.key) }
        }
    }

    func recordStreamEstimate(
        tabID: String,
        provider: String,
        outputTokens: Int,
        tokensPerSecond: Double,
        durationMs: Int,
        updatedAt: Date = Date()
    ) {
        guard !tabID.isEmpty, tabID != "default",
              outputTokens > 0, durationMs > 0,
              tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        guard shouldReplaceReading(for: tabID, source: .proxyStreamEstimate, updatedAt: updatedAt) else { return }

        readingsByTabID[tabID] = TokenRateReading(
            provider: provider,
            tokensPerSecond: tokensPerSecond,
            outputTokens: outputTokens,
            durationMs: durationMs,
            source: .proxyStreamEstimate,
            updatedAt: updatedAt
        )
    }

    private func shouldReplaceReading(for tabID: String, source: TokenRateSource, updatedAt: Date) -> Bool {
        guard let previous = readingsByTabID[tabID] else { return true }
        guard previous.updatedAt <= updatedAt else { return false }

        let isTranscriptEstimate = source == .claudeTranscript || source == .codexTranscript
        let previousIsProxyUsage = previous.source == .proxyUsage || previous.source == .proxyRequestUsage
        if isTranscriptEstimate, previousIsProxyUsage,
           updatedAt.timeIntervalSince(previous.updatedAt) < 5 {
            return false
        }
        return true
    }
}

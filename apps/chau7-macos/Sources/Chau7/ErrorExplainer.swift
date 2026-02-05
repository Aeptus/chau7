import Foundation
import Chau7Core

/// Service that uses a configured LLM provider to explain terminal errors.
/// Feeds the last N lines of terminal output to the LLM and returns
/// a structured explanation with suggested fixes.
@MainActor
final class ErrorExplainer: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var lastExplanation: ErrorExplanation?
    @Published private(set) var lastFixes: [FixSuggestion] = []
    @Published private(set) var lastError: String?

    private let client = LLMClient()

    /// Explain a terminal error using the configured LLM provider.
    /// - Parameters:
    ///   - output: The terminal output containing the error (last N lines)
    ///   - command: The command that produced the error (if known)
    ///   - config: The LLM provider configuration to use
    func explain(output: String, command: String?, config: LLMProviderConfig) async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil

        let systemPrompt = """
        You are a terminal expert. Analyze the following terminal output and explain the error concisely.
        Respond in this exact JSON format:
        {
          "summary": "One-line summary of the error",
          "details": "2-3 sentence explanation of what went wrong and why",
          "confidence": "high|medium|low",
          "fixes": [
            {"description": "What this fix does", "command": "the command to run", "risk": "safe|moderate|dangerous"}
          ]
        }
        Only suggest fixes you are confident about. Use "safe" for read-only commands, "moderate" for file modifications, "dangerous" for destructive operations.
        """

        var userMessage = "Terminal output:\n```\n\(output.suffix(2000))\n```"
        if let command = command {
            userMessage = "Command: \(command)\n\n" + userMessage
        }

        let request = LLMRequest(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: config.maxTokens
        )

        do {
            let response = try await client.send(request: request, config: config)
            parseExplanation(from: response.content)
            Log.info("ErrorExplainer: got explanation (\(response.tokensUsed ?? 0) tokens)")
        } catch {
            lastError = error.localizedDescription
            Log.error("ErrorExplainer: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Parse the LLM response into structured explanation and fixes.
    private func parseExplanation(from content: String) {
        // Extract the first balanced JSON object from the response
        let jsonString: String
        if let extracted = Self.extractFirstBalancedJSON(from: content) {
            jsonString = extracted
        } else {
            jsonString = content
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: use the raw content as the explanation
            lastExplanation = ErrorExplanation(
                summary: "Error explanation",
                details: content,
                confidence: .low
            )
            lastFixes = []
            return
        }

        let summary = json["summary"] as? String ?? "Unknown error"
        let details = json["details"] as? String ?? content
        let confidenceStr = json["confidence"] as? String ?? "medium"
        let confidence: ExplanationConfidence = {
            switch confidenceStr {
            case "high": return .high
            case "low": return .low
            default: return .medium
            }
        }()
        let suggestedFix = (json["fixes"] as? [[String: Any]])?.first.flatMap { fix -> String? in
            fix["command"] as? String
        }

        lastExplanation = ErrorExplanation(
            summary: summary,
            details: details,
            suggestedFix: suggestedFix,
            confidence: confidence
        )

        // Parse fix suggestions
        if let fixesArray = json["fixes"] as? [[String: Any]] {
            lastFixes = fixesArray.compactMap { fix -> FixSuggestion? in
                guard let desc = fix["description"] as? String,
                      let cmd = fix["command"] as? String else { return nil }
                let riskStr = fix["risk"] as? String ?? "safe"
                let risk: FixRiskLevel = {
                    switch riskStr {
                    case "moderate": return .moderate
                    case "dangerous": return .dangerous
                    default: return .safe
                    }
                }()
                return FixSuggestion(description: desc, command: cmd, riskLevel: risk)
            }
        } else {
            lastFixes = []
        }
    }

    /// Clear the current explanation state.
    func clear() {
        lastExplanation = nil
        lastFixes = []
        lastError = nil
    }

    /// Extracts the first balanced `{...}` JSON object from a string.
    /// Handles nested braces and strings with escaped quotes.
    static func extractFirstBalancedJSON(from text: String) -> String? {
        guard let openIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?

        for idx in text.indices[openIndex...] {
            let ch = text[idx]
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = idx
                    break
                }
            }
        }

        guard let end = endIndex else { return nil }
        return String(text[openIndex...end])
    }
}

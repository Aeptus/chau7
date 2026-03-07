import Foundation
import Chau7Core

/// HTTP client for sending requests to LLM providers (OpenAI, Anthropic, Ollama, Custom).
/// Handles provider-specific request/response formats and authentication.
final class LLMClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Send a request to the configured LLM provider.
    func send(request: LLMRequest, config: LLMProviderConfig) async throws -> LLMResponse {
        guard config.isValid else {
            throw LLMClientError.invalidConfig
        }

        guard let url = URL(string: config.endpoint) else {
            throw LLMClientError.invalidEndpoint(config.endpoint)
        }

        let (body, headers) = try buildRequest(request: request, config: config)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 30
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        Log.info("LLMClient: sending request to \(config.provider.displayName) (\(config.model))")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            Log.error("LLMClient: HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            throw LLMClientError.httpError(httpResponse.statusCode, body)
        }

        return try parseResponse(data: data, config: config)
    }

    // MARK: - Request Building

    private func buildRequest(request: LLMRequest, config: LLMProviderConfig) throws -> (Data, [String: String]) {
        switch config.provider {
        case .openai, .custom:
            return try buildOpenAIRequest(request: request, config: config)
        case .anthropic:
            return try buildAnthropicRequest(request: request, config: config)
        case .ollama:
            return try buildOllamaRequest(request: request, config: config)
        }
    }

    private func buildOpenAIRequest(request: LLMRequest, config: LLMProviderConfig) throws -> (Data, [String: String]) {
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userMessage]
            ],
            "max_tokens": request.maxTokens
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var headers = ["Content-Type": "application/json"]
        if !config.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(config.apiKey)"
        }
        return (data, headers)
    }

    private func buildAnthropicRequest(request: LLMRequest, config: LLMProviderConfig) throws -> (Data, [String: String]) {
        let body: [String: Any] = [
            "model": config.model,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userMessage]
            ],
            "max_tokens": request.maxTokens
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "x-api-key": config.apiKey,
            "anthropic-version": "2023-06-01"
        ]
        return (data, headers)
    }

    private func buildOllamaRequest(request: LLMRequest, config: LLMProviderConfig) throws -> (Data, [String: String]) {
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userMessage]
            ],
            "stream": false
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let headers = ["Content-Type": "application/json"]
        return (data, headers)
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data, config: LLMProviderConfig) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMClientError.parseFailed
        }

        switch config.provider {
        case .openai, .custom:
            return try parseOpenAIResponse(json: json, config: config)
        case .anthropic:
            return try parseAnthropicResponse(json: json, config: config)
        case .ollama:
            return try parseOllamaResponse(json: json, config: config)
        }
    }

    private func parseOpenAIResponse(json: [String: Any], config: LLMProviderConfig) throws -> LLMResponse {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMClientError.parseFailed
        }
        let usage = json["usage"] as? [String: Any]
        let tokens = usage?["total_tokens"] as? Int
        return LLMResponse(content: content, tokensUsed: tokens, model: config.model)
    }

    private func parseAnthropicResponse(json: [String: Any], config: LLMProviderConfig) throws -> LLMResponse {
        guard let contentArray = json["content"] as? [[String: Any]],
              let first = contentArray.first,
              let text = first["text"] as? String else {
            throw LLMClientError.parseFailed
        }
        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        return LLMResponse(content: text, tokensUsed: inputTokens + outputTokens, model: config.model)
    }

    private func parseOllamaResponse(json: [String: Any], config: LLMProviderConfig) throws -> LLMResponse {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMClientError.parseFailed
        }
        let evalCount = json["eval_count"] as? Int
        return LLMResponse(content: content, tokensUsed: evalCount, model: config.model)
    }
}

// MARK: - Errors

enum LLMClientError: LocalizedError {
    case invalidConfig
    case invalidEndpoint(String)
    case invalidResponse
    case httpError(Int, String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "LLM provider is not configured correctly"
        case .invalidEndpoint(let url): return "Invalid endpoint URL: \(url)"
        case .invalidResponse: return "Server returned an invalid response"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(100))"
        case .parseFailed: return "Failed to parse LLM response"
        }
    }
}

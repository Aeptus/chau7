package main

import (
	"net/http"
	"strings"
)

// Provider represents an LLM API provider
type Provider string

const (
	ProviderAnthropic Provider = "anthropic"
	ProviderOpenAI    Provider = "openai"
	ProviderGemini    Provider = "gemini"
	ProviderUnknown   Provider = "unknown"
)

// ProviderConfig holds the routing configuration for each provider
type ProviderConfig struct {
	BaseURL     string
	ContentType string
}

// ProviderConfigs maps providers to their configurations
var ProviderConfigs = map[Provider]ProviderConfig{
	ProviderAnthropic: {
		BaseURL:     "https://api.anthropic.com",
		ContentType: "application/json",
	},
	ProviderOpenAI: {
		BaseURL:     "https://api.openai.com",
		ContentType: "application/json",
	},
	ProviderGemini: {
		BaseURL:     "https://generativelanguage.googleapis.com",
		ContentType: "application/json",
	},
}

func isOpenAIPath(path string) bool {
	return strings.HasPrefix(path, "/v1/chat/completions") ||
		strings.HasPrefix(path, "/v1/completions") ||
		strings.HasPrefix(path, "/v1/embeddings") ||
		strings.HasPrefix(path, "/v1/responses") ||
		strings.HasPrefix(path, "/chat/completions") ||
		strings.HasPrefix(path, "/completions") ||
		strings.HasPrefix(path, "/embeddings") ||
		strings.HasPrefix(path, "/responses")
}

// DetectProvider determines which LLM provider the request is targeting
// based on the request path and headers.
//
// Detection logic:
// 1. Path-based detection (most reliable)
// 2. Header-based detection (fallback)
func DetectProvider(r *http.Request) Provider {
	path := r.URL.Path

	// Anthropic endpoints
	// - /v1/messages (main chat endpoint)
	// - /v1/complete (legacy completion)
	if strings.HasPrefix(path, "/v1/messages") {
		// Check for Anthropic-specific headers to disambiguate from OpenAI
		if r.Header.Get("anthropic-version") != "" || r.Header.Get("x-api-key") != "" {
			return ProviderAnthropic
		}
		// Could be OpenAI /v1/messages in future, but currently this is Anthropic
		return ProviderAnthropic
	}

	if strings.HasPrefix(path, "/v1/complete") {
		return ProviderAnthropic
	}

	// OpenAI endpoints
	// - /v1/chat/completions (chat)
	// - /v1/completions (legacy)
	// - /v1/embeddings
	// - /v1/responses (Codex CLI uses this)
	if isOpenAIPath(path) {
		return ProviderOpenAI
	}

	// Gemini endpoints
	// - /v1beta/models/*/generateContent
	// - /v1beta/models/*/streamGenerateContent
	// - /v1/models/*/generateContent
	// - /v1/models/*/countTokens
	if strings.Contains(path, "/models/") {
		if strings.Contains(path, "generateContent") ||
			strings.Contains(path, "streamGenerateContent") ||
			strings.Contains(path, "countTokens") {
			return ProviderGemini
		}
	}

	// Fallback: try to detect from headers
	if r.Header.Get("x-api-key") != "" && r.Header.Get("anthropic-version") != "" {
		return ProviderAnthropic
	}

	if r.Header.Get("x-goog-api-key") != "" {
		return ProviderGemini
	}

	// Default to OpenAI as it's the most common
	return ProviderOpenAI
}

// GetUpstreamURL constructs the full upstream URL for a request
func GetUpstreamURL(provider Provider, r *http.Request) string {
	cfg, ok := ProviderConfigs[provider]
	if !ok {
		cfg = ProviderConfigs[ProviderOpenAI]
	}

	path := r.URL.Path
	if provider == ProviderOpenAI && !strings.HasPrefix(path, "/v1/") {
		path = "/v1" + path
	}

	url := cfg.BaseURL + path
	if r.URL.RawQuery != "" {
		url += "?" + r.URL.RawQuery
	}

	return url
}

// IsStreamingRequest checks if the request expects a streaming response
func IsStreamingRequest(provider Provider, body []byte) bool {
	switch provider {
	case ProviderAnthropic:
		// Anthropic uses "stream": true in the request body
		return strings.Contains(string(body), `"stream":true`) ||
			strings.Contains(string(body), `"stream": true`)
	case ProviderOpenAI:
		// OpenAI also uses "stream": true
		return strings.Contains(string(body), `"stream":true`) ||
			strings.Contains(string(body), `"stream": true`)
	case ProviderGemini:
		// Gemini uses streamGenerateContent endpoint
		return false // Streaming is detected from the path, not body
	default:
		return false
	}
}

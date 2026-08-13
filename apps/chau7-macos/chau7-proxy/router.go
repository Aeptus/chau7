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

// IsTokenBillableEndpoint reports whether a path returns model output that
// costs tokens, and may therefore be estimated when a provider omits usage
// from an otherwise successful response.
//
// Estimation used to run on every 200. That silently wrecked cost analytics:
// /v1/models is a catalog listing with no model field and no usage, but Codex
// polls it every few seconds and its ~360 KB body estimated to ~90k output
// tokens per call — 99.8% of all recorded output tokens and most of the
// reported spend.
//
// This is an allowlist rather than a denylist of known-free routes, so it fails
// closed: an endpoint nobody has classified yet records no usage instead of
// inventing some. Genuine completion endpoints report real usage anyway, so the
// estimator only ever covered the fallback case.
func IsTokenBillableEndpoint(provider Provider, path string) bool {
	// Token counting prices nothing — it returns a count, not a completion.
	if strings.HasSuffix(path, "/count_tokens") || strings.Contains(path, "countTokens") {
		return false
	}

	switch provider {
	case ProviderAnthropic:
		return strings.HasPrefix(path, "/v1/messages") || strings.HasPrefix(path, "/v1/complete")
	case ProviderOpenAI:
		return isOpenAIPath(path)
	case ProviderGemini:
		// streamGenerateContent capitalizes the G, so one lowercase substring
		// check silently misses every streaming call. Mirror DetectProvider.
		return strings.Contains(path, "generateContent") ||
			strings.Contains(path, "streamGenerateContent")
	default:
		return false
	}
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

// GetUpstreamURL constructs the full upstream URL for a request.
// For OpenAI, it detects subscription (ChatGPT OAuth) vs API-key auth
// and routes to the correct backend.
func GetUpstreamURL(provider Provider, r *http.Request) string {
	cfg, ok := ProviderConfigs[provider]
	if !ok {
		cfg = ProviderConfigs[ProviderOpenAI]
	}

	path := r.URL.Path

	// Subscription-based Codex uses chatgpt.com, not api.openai.com.
	// Detect by checking the Authorization header: API keys start with "sk-",
	// while ChatGPT access tokens are opaque bearer tokens whose format may vary.
	if provider == ProviderOpenAI && isSubscriptionAuth(r) {
		// Rewrite /v1/<endpoint> → /backend-api/codex/<endpoint>
		trimmed := strings.TrimPrefix(path, "/v1")
		url := "https://chatgpt.com/backend-api/codex" + trimmed
		if r.URL.RawQuery != "" {
			url += "?" + r.URL.RawQuery
		}
		return url
	}

	if provider == ProviderOpenAI && !strings.HasPrefix(path, "/v1/") {
		path = "/v1" + path
	}

	url := cfg.BaseURL + path
	if r.URL.RawQuery != "" {
		url += "?" + r.URL.RawQuery
	}

	return url
}

// isSubscriptionAuth returns true if the request uses a ChatGPT subscription
// access token rather than an API key. API keys start with "sk-"; ChatGPT
// access tokens are opaque and must not be classified by a JWT-only prefix.
func isSubscriptionAuth(r *http.Request) bool {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return false
	}
	token := strings.TrimPrefix(auth, "Bearer ")
	if token == auth {
		return false // no "Bearer " prefix
	}
	// API keys start with "sk-"; all other bearer-token formats use the
	// subscription backend.
	return !strings.HasPrefix(token, "sk-")
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

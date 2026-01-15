package main

import (
	"net/http/httptest"
	"testing"
)

func TestDetectProvider_Anthropic(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		headers      map[string]string
		expectedProv Provider
	}{
		{
			name:         "Anthropic messages endpoint",
			path:         "/v1/messages",
			headers:      map[string]string{"anthropic-version": "2023-06-01"},
			expectedProv: ProviderAnthropic,
		},
		{
			name:         "Anthropic messages with x-api-key",
			path:         "/v1/messages",
			headers:      map[string]string{"x-api-key": "sk-ant-xxx"},
			expectedProv: ProviderAnthropic,
		},
		{
			name:         "Anthropic complete endpoint",
			path:         "/v1/complete",
			headers:      nil,
			expectedProv: ProviderAnthropic,
		},
		{
			name:         "Anthropic messages batches",
			path:         "/v1/messages/batches",
			headers:      map[string]string{"anthropic-version": "2023-06-01"},
			expectedProv: ProviderAnthropic,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", tc.path, nil)
			for k, v := range tc.headers {
				req.Header.Set(k, v)
			}

			provider := DetectProvider(req)
			if provider != tc.expectedProv {
				t.Errorf("Expected provider %s, got %s", tc.expectedProv, provider)
			}
		})
	}
}

func TestDetectProvider_OpenAI(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		expectedProv Provider
	}{
		{
			name:         "OpenAI chat completions",
			path:         "/v1/chat/completions",
			expectedProv: ProviderOpenAI,
		},
		{
			name:         "OpenAI completions",
			path:         "/v1/completions",
			expectedProv: ProviderOpenAI,
		},
		{
			name:         "OpenAI embeddings",
			path:         "/v1/embeddings",
			expectedProv: ProviderOpenAI,
		},
		{
			name:         "OpenAI responses (Codex)",
			path:         "/v1/responses",
			expectedProv: ProviderOpenAI,
		},
		{
			name:         "OpenAI responses (base /v1)",
			path:         "/responses",
			expectedProv: ProviderOpenAI,
		},
		{
			name:         "OpenAI chat completions (base /v1)",
			path:         "/chat/completions",
			expectedProv: ProviderOpenAI,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", tc.path, nil)
			provider := DetectProvider(req)
			if provider != tc.expectedProv {
				t.Errorf("Expected provider %s, got %s", tc.expectedProv, provider)
			}
		})
	}
}

func TestDetectProvider_Gemini(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		headers      map[string]string
		expectedProv Provider
	}{
		{
			name:         "Gemini generateContent",
			path:         "/v1beta/models/gemini-pro:generateContent",
			expectedProv: ProviderGemini,
		},
		{
			name:         "Gemini streamGenerateContent",
			path:         "/v1beta/models/gemini-pro:streamGenerateContent",
			expectedProv: ProviderGemini,
		},
		{
			name:         "Gemini countTokens",
			path:         "/v1/models/gemini-1.5-pro:countTokens",
			expectedProv: ProviderGemini,
		},
		{
			name:         "Gemini with API key header",
			path:         "/v1/models/gemini-2.0-flash:generateContent",
			headers:      map[string]string{"x-goog-api-key": "AIza..."},
			expectedProv: ProviderGemini,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", tc.path, nil)
			for k, v := range tc.headers {
				req.Header.Set(k, v)
			}

			provider := DetectProvider(req)
			if provider != tc.expectedProv {
				t.Errorf("Expected provider %s, got %s", tc.expectedProv, provider)
			}
		})
	}
}

func TestGetUpstreamURL(t *testing.T) {
	tests := []struct {
		name        string
		provider    Provider
		path        string
		query       string
		expectedURL string
	}{
		{
			name:        "Anthropic messages",
			provider:    ProviderAnthropic,
			path:        "/v1/messages",
			expectedURL: "https://api.anthropic.com/v1/messages",
		},
		{
			name:        "OpenAI with query params",
			provider:    ProviderOpenAI,
			path:        "/v1/chat/completions",
			query:       "api-version=2024-01-01",
			expectedURL: "https://api.openai.com/v1/chat/completions?api-version=2024-01-01",
		},
		{
			name:        "OpenAI base path without v1",
			provider:    ProviderOpenAI,
			path:        "/responses",
			expectedURL: "https://api.openai.com/v1/responses",
		},
		{
			name:        "Gemini generateContent",
			provider:    ProviderGemini,
			path:        "/v1beta/models/gemini-pro:generateContent",
			expectedURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", tc.path, nil)
			if tc.query != "" {
				req.URL.RawQuery = tc.query
			}

			url := GetUpstreamURL(tc.provider, req)
			if url != tc.expectedURL {
				t.Errorf("Expected URL %s, got %s", tc.expectedURL, url)
			}
		})
	}
}

func TestIsStreamingRequest(t *testing.T) {
	tests := []struct {
		name        string
		provider    Provider
		body        string
		isStreaming bool
	}{
		{
			name:        "Anthropic streaming",
			provider:    ProviderAnthropic,
			body:        `{"model":"claude-3-sonnet","messages":[],"stream":true}`,
			isStreaming: true,
		},
		{
			name:        "Anthropic not streaming",
			provider:    ProviderAnthropic,
			body:        `{"model":"claude-3-sonnet","messages":[],"stream":false}`,
			isStreaming: false,
		},
		{
			name:        "OpenAI streaming",
			provider:    ProviderOpenAI,
			body:        `{"model":"gpt-4","messages":[],"stream": true}`,
			isStreaming: true,
		},
		{
			name:        "OpenAI not streaming",
			provider:    ProviderOpenAI,
			body:        `{"model":"gpt-4","messages":[]}`,
			isStreaming: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := IsStreamingRequest(tc.provider, []byte(tc.body))
			if result != tc.isStreaming {
				t.Errorf("Expected streaming=%v, got %v", tc.isStreaming, result)
			}
		})
	}
}

func TestProviderConfigs(t *testing.T) {
	// Verify all known providers have configs
	providers := []Provider{ProviderAnthropic, ProviderOpenAI, ProviderGemini}

	for _, p := range providers {
		cfg, ok := ProviderConfigs[p]
		if !ok {
			t.Errorf("Missing config for provider %s", p)
			continue
		}
		if cfg.BaseURL == "" {
			t.Errorf("Empty BaseURL for provider %s", p)
		}
	}
}

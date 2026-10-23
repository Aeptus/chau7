package main

import (
	"net/http"
	"testing"
)

// TestIsTokenBillableEndpoint covers every endpoint observed in production
// logs, including the ones whose misclassification corrupted cost analytics.
func TestIsTokenBillableEndpoint(t *testing.T) {
	cases := []struct {
		name     string
		provider Provider
		path     string
		billable bool
	}{
		// The regression: a catalog listing polled every few seconds, whose
		// ~360 KB body was estimated at ~90k output tokens per call.
		{"openai models listing", ProviderOpenAI, "/v1/models", false},
		{"openai models listing unversioned", ProviderOpenAI, "/models", false},
		// Not a completion either; contributed phantom tokens at lower volume.
		{"openai alpha search", ProviderOpenAI, "/v1/alpha/search", false},
		// Counting tokens returns a count, not billable output.
		{"anthropic count_tokens", ProviderAnthropic, "/v1/messages/count_tokens", false},
		{"gemini countTokens", ProviderGemini, "/v1beta/models/gemini-2.0-flash:countTokens", false},

		// Genuine completion endpoints must keep their estimation fallback.
		{"anthropic messages", ProviderAnthropic, "/v1/messages", true},
		{"anthropic legacy complete", ProviderAnthropic, "/v1/complete", true},
		{"openai responses", ProviderOpenAI, "/v1/responses", true},
		{"openai chat completions", ProviderOpenAI, "/v1/chat/completions", true},
		{"openai completions", ProviderOpenAI, "/v1/completions", true},
		{"openai embeddings", ProviderOpenAI, "/v1/embeddings", true},
		{"gemini generateContent", ProviderGemini, "/v1beta/models/gemini-2.0-flash:generateContent", true},
		{"gemini streamGenerateContent", ProviderGemini, "/v1beta/models/gemini-2.0-flash:streamGenerateContent", true},

		// Unknown routes fail closed rather than inventing usage.
		{"unknown provider", ProviderUnknown, "/v1/messages", false},
		{"unrecognized openai route", ProviderOpenAI, "/v1/files", false},
		{"proxy internal route", ProviderOpenAI, "/api/hello", false},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := IsTokenBillableEndpoint(testCase.provider, testCase.path); got != testCase.billable {
				t.Errorf(
					"IsTokenBillableEndpoint(%q, %q) = %v, want %v",
					testCase.provider, testCase.path, got, testCase.billable,
				)
			}
		})
	}
}

// TestModelsEndpointDetectsAsOpenAI documents why the bug reached production:
// DetectProvider falls through to OpenAI for unrecognized paths, so /v1/models
// arrived at the estimator wearing a valid provider. Classification therefore
// cannot lean on provider detection alone.
func TestModelsEndpointDetectsAsOpenAI(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "https://127.0.0.1:18081/v1/models", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}

	if provider := DetectProvider(req); provider != ProviderOpenAI {
		t.Fatalf("DetectProvider(/v1/models) = %v, want %v", provider, ProviderOpenAI)
	}
	if IsTokenBillableEndpoint(ProviderOpenAI, "/v1/models") {
		t.Error("/v1/models must not be billable despite detecting as OpenAI")
	}
}

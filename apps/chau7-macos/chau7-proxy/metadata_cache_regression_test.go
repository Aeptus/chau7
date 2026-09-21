package main

import "testing"

func TestExtractResponseMetadataCapturesCacheReadAndCreationAcrossProviders(t *testing.T) {
	tests := []struct {
		name           string
		provider       Provider
		body           string
		expectCreation int
		expectRead     int
	}{
		{
			name: "Anthropic", provider: ProviderAnthropic,
			body:           `{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}`,
			expectCreation: 30, expectRead: 40,
		},
		{
			name: "OpenAI compatible", provider: ProviderOpenAI,
			body:           `{"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":40}}}`,
			expectCreation: 0, expectRead: 40,
		},
		{
			name: "Gemini", provider: ProviderGemini,
			body:           `{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"cachedContentTokenCount":40}}`,
			expectCreation: 0, expectRead: 40,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractResponseMetadata(tc.provider, []byte(tc.body))
			if meta.CacheCreationInputTokens != tc.expectCreation || meta.CacheReadInputTokens != tc.expectRead {
				t.Fatalf("cache metadata = creation:%d read:%d, want creation:%d read:%d", meta.CacheCreationInputTokens, meta.CacheReadInputTokens, tc.expectCreation, tc.expectRead)
			}
		})
	}
}

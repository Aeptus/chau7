package main

import (
	"testing"
)

func TestExtractAnthropicRequest(t *testing.T) {
	tests := []struct {
		name        string
		body        string
		expectModel string
		expectMsgs  int
		expectMax   int
	}{
		{
			name: "Full Anthropic request",
			body: `{
				"model": "claude-3-5-sonnet-20241022",
				"messages": [{"role": "user", "content": "Hello"}],
				"max_tokens": 1024
			}`,
			expectModel: "claude-3-5-sonnet-20241022",
			expectMsgs:  1,
			expectMax:   1024,
		},
		{
			name: "Multiple messages",
			body: `{
				"model": "claude-3-opus",
				"messages": [
					{"role": "user", "content": "Hi"},
					{"role": "assistant", "content": "Hello!"},
					{"role": "user", "content": "How are you?"}
				],
				"max_tokens": 2048
			}`,
			expectModel: "claude-3-opus",
			expectMsgs:  3,
			expectMax:   2048,
		},
		{
			name:        "Invalid JSON",
			body:        `not valid json`,
			expectModel: "",
			expectMsgs:  0,
			expectMax:   0,
		},
		{
			name:        "Empty body",
			body:        `{}`,
			expectModel: "",
			expectMsgs:  0,
			expectMax:   0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractRequestMetadata(ProviderAnthropic, []byte(tc.body))
			if meta.Model != tc.expectModel {
				t.Errorf("Expected model %q, got %q", tc.expectModel, meta.Model)
			}
			if meta.MessageCount != tc.expectMsgs {
				t.Errorf("Expected %d messages, got %d", tc.expectMsgs, meta.MessageCount)
			}
			if meta.MaxTokens != tc.expectMax {
				t.Errorf("Expected max_tokens %d, got %d", tc.expectMax, meta.MaxTokens)
			}
		})
	}
}

func TestExtractAnthropicResponse(t *testing.T) {
	tests := []struct {
		name         string
		body         string
		expectModel  string
		expectInput  int
		expectOutput int
		expectReason string
	}{
		{
			name: "Standard response",
			body: `{
				"model": "claude-3-5-sonnet-20241022",
				"usage": {
					"input_tokens": 50,
					"output_tokens": 150
				},
				"stop_reason": "end_turn"
			}`,
			expectModel:  "claude-3-5-sonnet-20241022",
			expectInput:  50,
			expectOutput: 150,
			expectReason: "end_turn",
		},
		{
			name: "Max tokens reached",
			body: `{
				"model": "claude-3-opus",
				"usage": {
					"input_tokens": 1000,
					"output_tokens": 4096
				},
				"stop_reason": "max_tokens"
			}`,
			expectModel:  "claude-3-opus",
			expectInput:  1000,
			expectOutput: 4096,
			expectReason: "max_tokens",
		},
		{
			name:         "Invalid JSON",
			body:         `invalid`,
			expectModel:  "",
			expectInput:  0,
			expectOutput: 0,
			expectReason: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractResponseMetadata(ProviderAnthropic, []byte(tc.body))
			if meta.Model != tc.expectModel {
				t.Errorf("Expected model %q, got %q", tc.expectModel, meta.Model)
			}
			if meta.InputTokens != tc.expectInput {
				t.Errorf("Expected input_tokens %d, got %d", tc.expectInput, meta.InputTokens)
			}
			if meta.OutputTokens != tc.expectOutput {
				t.Errorf("Expected output_tokens %d, got %d", tc.expectOutput, meta.OutputTokens)
			}
			if meta.FinishReason != tc.expectReason {
				t.Errorf("Expected finish_reason %q, got %q", tc.expectReason, meta.FinishReason)
			}
		})
	}
}

func TestExtractOpenAIRequest(t *testing.T) {
	tests := []struct {
		name        string
		body        string
		expectModel string
		expectMsgs  int
		expectMax   int
	}{
		{
			name: "GPT-4 request",
			body: `{
				"model": "gpt-4o",
				"messages": [{"role": "user", "content": "Hello"}],
				"max_tokens": 500
			}`,
			expectModel: "gpt-4o",
			expectMsgs:  1,
			expectMax:   500,
		},
		{
			name: "System message included",
			body: `{
				"model": "gpt-4-turbo",
				"messages": [
					{"role": "system", "content": "You are helpful."},
					{"role": "user", "content": "Hi"}
				],
				"max_tokens": 1000
			}`,
			expectModel: "gpt-4-turbo",
			expectMsgs:  2,
			expectMax:   1000,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractRequestMetadata(ProviderOpenAI, []byte(tc.body))
			if meta.Model != tc.expectModel {
				t.Errorf("Expected model %q, got %q", tc.expectModel, meta.Model)
			}
			if meta.MessageCount != tc.expectMsgs {
				t.Errorf("Expected %d messages, got %d", tc.expectMsgs, meta.MessageCount)
			}
			if meta.MaxTokens != tc.expectMax {
				t.Errorf("Expected max_tokens %d, got %d", tc.expectMax, meta.MaxTokens)
			}
		})
	}
}

func TestExtractOpenAIResponse(t *testing.T) {
	tests := []struct {
		name         string
		body         string
		expectModel  string
		expectInput  int
		expectOutput int
		expectReason string
	}{
		{
			name: "Standard completion",
			body: `{
				"model": "gpt-4o-2024-11-20",
				"usage": {
					"prompt_tokens": 25,
					"completion_tokens": 100
				},
				"choices": [{"finish_reason": "stop"}]
			}`,
			expectModel:  "gpt-4o-2024-11-20",
			expectInput:  25,
			expectOutput: 100,
			expectReason: "stop",
		},
		{
			name: "Length limit",
			body: `{
				"model": "gpt-4",
				"usage": {
					"prompt_tokens": 500,
					"completion_tokens": 4096
				},
				"choices": [{"finish_reason": "length"}]
			}`,
			expectModel:  "gpt-4",
			expectInput:  500,
			expectOutput: 4096,
			expectReason: "length",
		},
		{
			name: "No choices",
			body: `{
				"model": "gpt-4o",
				"usage": {"prompt_tokens": 10, "completion_tokens": 20},
				"choices": []
			}`,
			expectModel:  "gpt-4o",
			expectInput:  10,
			expectOutput: 20,
			expectReason: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractResponseMetadata(ProviderOpenAI, []byte(tc.body))
			if meta.Model != tc.expectModel {
				t.Errorf("Expected model %q, got %q", tc.expectModel, meta.Model)
			}
			if meta.InputTokens != tc.expectInput {
				t.Errorf("Expected prompt_tokens %d, got %d", tc.expectInput, meta.InputTokens)
			}
			if meta.OutputTokens != tc.expectOutput {
				t.Errorf("Expected completion_tokens %d, got %d", tc.expectOutput, meta.OutputTokens)
			}
			if meta.FinishReason != tc.expectReason {
				t.Errorf("Expected finish_reason %q, got %q", tc.expectReason, meta.FinishReason)
			}
		})
	}
}

func TestExtractGeminiRequest(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		expectMsgs int
		expectMax  int
	}{
		{
			name: "With generation config",
			body: `{
				"contents": [{"parts": [{"text": "Hello"}]}],
				"generationConfig": {"maxOutputTokens": 2000}
			}`,
			expectMsgs: 1,
			expectMax:  2000,
		},
		{
			name: "Multiple turns",
			body: `{
				"contents": [
					{"role": "user", "parts": [{"text": "Hi"}]},
					{"role": "model", "parts": [{"text": "Hello!"}]},
					{"role": "user", "parts": [{"text": "Question"}]}
				]
			}`,
			expectMsgs: 3,
			expectMax:  0,
		},
		{
			name: "No generation config",
			body: `{
				"contents": [{"parts": [{"text": "Hello"}]}]
			}`,
			expectMsgs: 1,
			expectMax:  0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractRequestMetadata(ProviderGemini, []byte(tc.body))
			// Gemini model is in URL path, not body
			if meta.Model != "" {
				t.Errorf("Expected empty model (from path), got %q", meta.Model)
			}
			if meta.MessageCount != tc.expectMsgs {
				t.Errorf("Expected %d contents, got %d", tc.expectMsgs, meta.MessageCount)
			}
			if meta.MaxTokens != tc.expectMax {
				t.Errorf("Expected maxOutputTokens %d, got %d", tc.expectMax, meta.MaxTokens)
			}
		})
	}
}

func TestExtractGeminiResponse(t *testing.T) {
	tests := []struct {
		name         string
		body         string
		expectModel  string
		expectInput  int
		expectOutput int
		expectReason string
	}{
		{
			name: "Standard response",
			body: `{
				"candidates": [{"finishReason": "STOP"}],
				"usageMetadata": {
					"promptTokenCount": 15,
					"candidatesTokenCount": 200,
					"totalTokenCount": 215
				},
				"modelVersion": "gemini-1.5-pro"
			}`,
			expectModel:  "gemini-1.5-pro",
			expectInput:  15,
			expectOutput: 200,
			expectReason: "STOP",
		},
		{
			name: "Max tokens",
			body: `{
				"candidates": [{"finishReason": "MAX_TOKENS"}],
				"usageMetadata": {
					"promptTokenCount": 100,
					"candidatesTokenCount": 1000,
					"totalTokenCount": 1100
				}
			}`,
			expectModel:  "",
			expectInput:  100,
			expectOutput: 1000,
			expectReason: "MAX_TOKENS",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ExtractResponseMetadata(ProviderGemini, []byte(tc.body))
			if meta.Model != tc.expectModel {
				t.Errorf("Expected model %q, got %q", tc.expectModel, meta.Model)
			}
			if meta.InputTokens != tc.expectInput {
				t.Errorf("Expected promptTokenCount %d, got %d", tc.expectInput, meta.InputTokens)
			}
			if meta.OutputTokens != tc.expectOutput {
				t.Errorf("Expected candidatesTokenCount %d, got %d", tc.expectOutput, meta.OutputTokens)
			}
			if meta.FinishReason != tc.expectReason {
				t.Errorf("Expected finishReason %q, got %q", tc.expectReason, meta.FinishReason)
			}
		})
	}
}

func TestExtractModelFromPath(t *testing.T) {
	tests := []struct {
		path   string
		expect string
	}{
		{"/v1beta/models/gemini-pro:generateContent", "gemini-pro"},
		{"/v1beta/models/gemini-1.5-pro:streamGenerateContent", "gemini-1.5-pro"},
		{"/v1/models/gemini-2.0-flash:countTokens", "gemini-2.0-flash"},
		{"/v1beta/models/gemini-pro-vision:generateContent", "gemini-pro-vision"},
		{"/v1/chat/completions", ""},
		{"/some/random/path", ""},
		{"", ""},
	}

	for _, tc := range tests {
		t.Run(tc.path, func(t *testing.T) {
			result := ExtractModelFromPath(tc.path)
			if result != tc.expect {
				t.Errorf("ExtractModelFromPath(%q) = %q, want %q", tc.path, result, tc.expect)
			}
		})
	}
}

func TestParseStreamingChunks(t *testing.T) {
	tests := []struct {
		name         string
		provider     Provider
		chunks       string
		expectInput  int
		expectOutput int
	}{
		{
			name:     "Anthropic streaming",
			provider: ProviderAnthropic,
			chunks: `data: {"type":"message_start"}
data: {"type":"content_block_delta"}
data: {"type":"message_delta","usage":{"output_tokens":50}}
data: {"model":"claude-3-sonnet","usage":{"input_tokens":25,"output_tokens":75},"stop_reason":"end_turn"}
`,
			expectInput:  25,
			expectOutput: 75,
		},
		{
			name:     "OpenAI streaming",
			provider: ProviderOpenAI,
			chunks: `data: {"id":"chatcmpl-1"}
data: {"id":"chatcmpl-2","choices":[{"delta":{"content":"Hello"}}]}
data: {"model":"gpt-4o","usage":{"prompt_tokens":10,"completion_tokens":20},"choices":[{"finish_reason":"stop"}]}
data: [DONE]
`,
			expectInput:  10,
			expectOutput: 20,
		},
		{
			name:         "Empty chunks",
			provider:     ProviderAnthropic,
			chunks:       "",
			expectInput:  0,
			expectOutput: 0,
		},
		{
			name:         "Only DONE marker",
			provider:     ProviderOpenAI,
			chunks:       "data: [DONE]\n",
			expectInput:  0,
			expectOutput: 0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := ParseStreamingChunks(tc.provider, []byte(tc.chunks))
			if meta.InputTokens != tc.expectInput {
				t.Errorf("Expected input_tokens %d, got %d", tc.expectInput, meta.InputTokens)
			}
			if meta.OutputTokens != tc.expectOutput {
				t.Errorf("Expected output_tokens %d, got %d", tc.expectOutput, meta.OutputTokens)
			}
		})
	}
}

func TestUnknownProvider(t *testing.T) {
	body := []byte(`{"model": "test", "messages": []}`)

	reqMeta := ExtractRequestMetadata(Provider("unknown"), body)
	if reqMeta.Model != "" || reqMeta.MessageCount != 0 {
		t.Errorf("Unknown provider should return empty metadata")
	}

	respMeta := ExtractResponseMetadata(Provider("unknown"), body)
	if respMeta.Model != "" || respMeta.InputTokens != 0 {
		t.Errorf("Unknown provider should return empty metadata")
	}
}

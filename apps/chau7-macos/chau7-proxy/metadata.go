package main

import (
	"encoding/json"
	"strings"
)

// RequestMetadata contains metadata extracted from the request
type RequestMetadata struct {
	Model        string
	MessageCount int
	MaxTokens    int
}

// ResponseMetadata contains metadata extracted from the response
type ResponseMetadata struct {
	Model        string
	InputTokens  int
	OutputTokens int
	FinishReason string
}

// ExtractRequestMetadata extracts metadata from a request body
func ExtractRequestMetadata(provider Provider, body []byte) RequestMetadata {
	switch provider {
	case ProviderAnthropic:
		return extractAnthropicRequest(body)
	case ProviderOpenAI:
		return extractOpenAIRequest(body)
	case ProviderGemini:
		return extractGeminiRequest(body)
	default:
		return RequestMetadata{}
	}
}

// ExtractResponseMetadata extracts metadata from a response body
// For streaming responses, this should be called on the final accumulated response
func ExtractResponseMetadata(provider Provider, body []byte) ResponseMetadata {
	switch provider {
	case ProviderAnthropic:
		return extractAnthropicResponse(body)
	case ProviderOpenAI:
		return extractOpenAIResponse(body)
	case ProviderGemini:
		return extractGeminiResponse(body)
	default:
		return ResponseMetadata{}
	}
}

// Anthropic request/response parsing
// Reference: https://docs.anthropic.com/en/api/messages

type anthropicRequest struct {
	Model     string `json:"model"`
	Messages  []any  `json:"messages"`
	MaxTokens int    `json:"max_tokens"`
}

type anthropicResponse struct {
	Model      string         `json:"model"`
	Usage      anthropicUsage `json:"usage"`
	StopReason string         `json:"stop_reason"`
}

type anthropicUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

func extractAnthropicRequest(body []byte) RequestMetadata {
	var req anthropicRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return RequestMetadata{}
	}
	return RequestMetadata{
		Model:        req.Model,
		MessageCount: len(req.Messages),
		MaxTokens:    req.MaxTokens,
	}
}

func extractAnthropicResponse(body []byte) ResponseMetadata {
	var resp anthropicResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return ResponseMetadata{}
	}
	return ResponseMetadata{
		Model:        resp.Model,
		InputTokens:  resp.Usage.InputTokens,
		OutputTokens: resp.Usage.OutputTokens,
		FinishReason: resp.StopReason,
	}
}

// OpenAI request/response parsing
// Reference: https://platform.openai.com/docs/api-reference/chat

type openAIRequest struct {
	Model     string `json:"model"`
	Messages  []any  `json:"messages"`
	MaxTokens int    `json:"max_tokens"`
}

type openAIResponse struct {
	Model   string         `json:"model"`
	Usage   openAIUsage    `json:"usage"`
	Choices []openAIChoice `json:"choices"`
}

type openAIUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

type openAIChoice struct {
	FinishReason string `json:"finish_reason"`
}

func extractOpenAIRequest(body []byte) RequestMetadata {
	var req openAIRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return RequestMetadata{}
	}
	return RequestMetadata{
		Model:        req.Model,
		MessageCount: len(req.Messages),
		MaxTokens:    req.MaxTokens,
	}
}

func extractOpenAIResponse(body []byte) ResponseMetadata {
	var resp openAIResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return ResponseMetadata{}
	}

	finishReason := ""
	if len(resp.Choices) > 0 {
		finishReason = resp.Choices[0].FinishReason
	}

	return ResponseMetadata{
		Model:        resp.Model,
		InputTokens:  resp.Usage.PromptTokens,
		OutputTokens: resp.Usage.CompletionTokens,
		FinishReason: finishReason,
	}
}

// Gemini request/response parsing
// Reference: https://ai.google.dev/api/generate-content

type geminiRequest struct {
	Contents         []any                   `json:"contents"`
	GenerationConfig *geminiGenerationConfig `json:"generationConfig"`
}

type geminiGenerationConfig struct {
	MaxOutputTokens int `json:"maxOutputTokens"`
}

type geminiResponse struct {
	Candidates    []geminiCandidate `json:"candidates"`
	UsageMetadata geminiUsage       `json:"usageMetadata"`
	ModelVersion  string            `json:"modelVersion"`
}

type geminiCandidate struct {
	FinishReason string `json:"finishReason"`
}

type geminiUsage struct {
	PromptTokenCount     int `json:"promptTokenCount"`
	CandidatesTokenCount int `json:"candidatesTokenCount"`
	TotalTokenCount      int `json:"totalTokenCount"`
}

func extractGeminiRequest(body []byte) RequestMetadata {
	var req geminiRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return RequestMetadata{}
	}

	maxTokens := 0
	if req.GenerationConfig != nil {
		maxTokens = req.GenerationConfig.MaxOutputTokens
	}

	return RequestMetadata{
		Model:        "", // Gemini model is in the URL path
		MessageCount: len(req.Contents),
		MaxTokens:    maxTokens,
	}
}

func extractGeminiResponse(body []byte) ResponseMetadata {
	var resp geminiResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return ResponseMetadata{}
	}

	finishReason := ""
	if len(resp.Candidates) > 0 {
		finishReason = resp.Candidates[0].FinishReason
	}

	return ResponseMetadata{
		Model:        resp.ModelVersion,
		InputTokens:  resp.UsageMetadata.PromptTokenCount,
		OutputTokens: resp.UsageMetadata.CandidatesTokenCount,
		FinishReason: finishReason,
	}
}

// ExtractModelFromPath extracts the model name from a Gemini API path
// e.g., /v1beta/models/gemini-pro:generateContent -> gemini-pro
func ExtractModelFromPath(path string) string {
	// Find "models/" in the path
	idx := strings.Index(path, "models/")
	if idx == -1 {
		return ""
	}

	// Extract the part after "models/"
	rest := path[idx+7:]

	// Find the end (either ":" or "/" or end of string)
	for i, c := range rest {
		if c == ':' || c == '/' {
			return rest[:i]
		}
	}

	return rest
}

// ParseStreamingChunks parses SSE streaming response to extract usage metadata.
// Providers embed usage info differently in streaming:
//   - Anthropic: message_start has model + input_tokens; message_delta has output_tokens
//   - OpenAI: final chunk has usage (prompt_tokens, completion_tokens) if stream_options.include_usage
//   - Gemini: usageMetadata appears in the final chunk
func ParseStreamingChunks(provider Provider, chunks []byte) ResponseMetadata {
	lines := strings.Split(string(chunks), "\n")

	var result ResponseMetadata

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			continue
		}

		switch provider {
		case ProviderAnthropic:
			// Anthropic streams as typed events:
			//   message_start → { message: { model, usage: { input_tokens } } }
			//   content_block_delta → { delta: { text } }  (no usage)
			//   message_delta → { usage: { output_tokens } }
			var envelope struct {
				Type    string `json:"type"`
				Message struct {
					Model string         `json:"model"`
					Usage anthropicUsage `json:"usage"`
				} `json:"message"`
				Usage anthropicUsage `json:"usage"`
			}
			if err := json.Unmarshal([]byte(data), &envelope); err != nil {
				continue
			}
			switch envelope.Type {
			case "message_start":
				result.Model = envelope.Message.Model
				result.InputTokens = envelope.Message.Usage.InputTokens
			case "message_delta":
				result.OutputTokens = envelope.Usage.OutputTokens
			}

		case ProviderOpenAI:
			// OpenAI puts usage in the final chunk (when stream_options.include_usage is set),
			// or the model in every chunk. Scan all chunks, keep the last non-zero values.
			var chunk openAIResponse
			if err := json.Unmarshal([]byte(data), &chunk); err != nil {
				continue
			}
			if chunk.Model != "" {
				result.Model = chunk.Model
			}
			if chunk.Usage.PromptTokens > 0 {
				result.InputTokens = chunk.Usage.PromptTokens
			}
			if chunk.Usage.CompletionTokens > 0 {
				result.OutputTokens = chunk.Usage.CompletionTokens
			}
			if len(chunk.Choices) > 0 && chunk.Choices[0].FinishReason != "" {
				result.FinishReason = chunk.Choices[0].FinishReason
			}

		case ProviderGemini:
			// Gemini non-streaming only (streaming detected by path, not here).
			// If called, fall back to full-response parser on last chunk.
			meta := extractGeminiResponse([]byte(data))
			if meta.InputTokens > 0 || meta.OutputTokens > 0 {
				result = meta
			}
		}
	}

	return result
}

package main

import (
	"strings"
	"unicode/utf8"
)

// TokenEstimator provides approximate token counts without a full BPE tokenizer.
// Calibrated per provider family based on empirical character-to-token ratios.
//
// Accuracy: typically within 10-20% of actual counts for English text and code.
// This is sufficient for pre-request cost estimation UI.

// EstimateTokens returns an approximate token count for the given text.
// The provider parameter selects the calibrated ratio for that model family.
func EstimateTokens(text string, provider Provider) int {
	if len(text) == 0 {
		return 0
	}

	charCount := utf8.RuneCountInString(text)
	ratio := charsPerToken(provider, text)

	tokens := float64(charCount) / ratio
	// Minimum 1 token for non-empty input
	if tokens < 1 {
		return 1
	}
	return int(tokens + 0.5) // round
}

// EstimateMessageTokens estimates the total token count for a list of messages.
// Adds per-message overhead for role/formatting tokens.
func EstimateMessageTokens(messages []map[string]interface{}, provider Provider) int {
	total := 0
	for _, msg := range messages {
		// Per-message overhead: role token + formatting (~4 tokens)
		total += 4
		if content, ok := msg["content"].(string); ok {
			total += EstimateTokens(content, provider)
		}
	}
	// Conversation framing overhead (~3 tokens for <|start|>, <|end|>, etc.)
	total += 3
	return total
}

// charsPerToken returns the calibrated characters-per-token ratio.
// Different providers use different tokenizers with different efficiencies.
// These ratios are empirically measured on mixed English/code corpora.
func charsPerToken(provider Provider, text string) float64 {
	// Detect content type: code tends to have more short tokens
	codeRatio := codeContentRatio(text)

	var baseRatio float64
	switch provider {
	case ProviderAnthropic:
		baseRatio = 3.8 // Claude tokenizer
	case ProviderOpenAI:
		baseRatio = 3.3 // tiktoken (cl100k_base / o200k_base)
	case ProviderGemini:
		baseRatio = 4.0 // SentencePiece
	default:
		baseRatio = 3.5 // conservative default
	}

	// Code typically produces more tokens per character (shorter tokens)
	// Adjust ratio down for code-heavy content
	if codeRatio > 0.5 {
		baseRatio *= 0.85 // ~15% more tokens for code
	}

	return baseRatio
}

// codeContentRatio estimates what fraction of the text is code.
// Uses simple heuristics: bracket density, indentation, semicolons.
func codeContentRatio(text string) float64 {
	if len(text) == 0 {
		return 0
	}

	codeSignals := 0
	lines := strings.Split(text, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if len(trimmed) == 0 {
			continue
		}
		// Lines starting with indentation (2+ spaces or tab)
		if strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "\t") {
			codeSignals++
		}
		// Lines with brackets, semicolons, or common code patterns
		if strings.ContainsAny(trimmed, "{}();[]") {
			codeSignals++
		}
	}

	if len(lines) == 0 {
		return 0
	}
	return float64(codeSignals) / float64(len(lines))
}

package main

import (
	"strings"
	"testing"
)

func TestEstimateTokens_Empty(t *testing.T) {
	if got := EstimateTokens("", ProviderAnthropic); got != 0 {
		t.Errorf("empty string: got %d, want 0", got)
	}
}

func TestEstimateTokens_SingleWord(t *testing.T) {
	got := EstimateTokens("hello", ProviderAnthropic)
	if got < 1 || got > 3 {
		t.Errorf("single word: got %d, want 1-3", got)
	}
}

func TestEstimateTokens_English(t *testing.T) {
	// ~100 chars of English text should be ~25-35 tokens
	text := "The quick brown fox jumps over the lazy dog. This is a sample sentence for testing token estimation."
	got := EstimateTokens(text, ProviderAnthropic)
	if got < 15 || got > 45 {
		t.Errorf("English text (%d chars): got %d tokens, want 15-45", len(text), got)
	}
}

func TestEstimateTokens_Code(t *testing.T) {
	code := `func main() {
	fmt.Println("hello world")
	for i := 0; i < 10; i++ {
		fmt.Printf("i = %d\n", i)
	}
}`
	got := EstimateTokens(code, ProviderOpenAI)
	// Code should produce more tokens than English for the same char count
	if got < 20 || got > 60 {
		t.Errorf("Go code (%d chars): got %d tokens, want 20-60", len(code), got)
	}
}

func TestEstimateTokens_ProviderDifference(t *testing.T) {
	text := strings.Repeat("This is a test sentence. ", 20)
	anthropic := EstimateTokens(text, ProviderAnthropic)
	openai := EstimateTokens(text, ProviderOpenAI)
	// OpenAI should estimate more tokens (smaller chars-per-token ratio)
	if openai <= anthropic {
		t.Errorf("OpenAI (%d) should estimate more tokens than Anthropic (%d)", openai, anthropic)
	}
}

func TestEstimateMessageTokens(t *testing.T) {
	messages := []map[string]interface{}{
		{"role": "user", "content": "What is 2+2?"},
		{"role": "assistant", "content": "4"},
	}
	got := EstimateMessageTokens(messages, ProviderAnthropic)
	// 2 messages * 4 overhead + content tokens + 3 framing = ~15-25
	if got < 10 || got > 30 {
		t.Errorf("2 messages: got %d tokens, want 10-30", got)
	}
}

func TestCodeContentRatio(t *testing.T) {
	plain := "This is just plain English text without any code."
	if ratio := codeContentRatio(plain); ratio > 0.3 {
		t.Errorf("plain text: ratio %.2f, want < 0.3", ratio)
	}

	code := "func foo() {\n\treturn bar();\n}"
	if ratio := codeContentRatio(code); ratio < 0.3 {
		t.Errorf("code: ratio %.2f, want > 0.3", ratio)
	}
}

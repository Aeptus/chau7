package main

import (
	"testing"
	"time"
)

func TestStreamingTextDeltaExtractsProviderText(t *testing.T) {
	tests := []struct {
		name     string
		provider Provider
		data     string
		want     string
	}{
		{
			name:     "Anthropic text delta",
			provider: ProviderAnthropic,
			data:     "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}",
			want:     "hello",
		},
		{
			name:     "OpenAI Responses text delta",
			provider: ProviderOpenAI,
			data:     "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}",
			want:     "hello",
		},
		{
			name:     "OpenAI chat text delta",
			provider: ProviderOpenAI,
			data:     "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}",
			want:     "hello",
		},
		{
			name:     "OpenAI chat text parts",
			provider: ProviderOpenAI,
			data:     "{\"choices\":[{\"delta\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}]}",
			want:     "hello",
		},
		{
			name:     "Gemini text delta",
			provider: ProviderGemini,
			data:     "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]}}]}",
			want:     "hello",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := streamingTextDelta(test.provider, []byte(test.data)); got != test.want {
				t.Fatalf("streamingTextDelta() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestStreamingTextDeltaIgnoresNonTextEvents(t *testing.T) {
	tests := []struct {
		name     string
		provider Provider
		data     string
	}{
		{
			name:     "Anthropic message start",
			provider: ProviderAnthropic,
			data:     "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}",
		},
		{
			name:     "OpenAI completed event",
			provider: ProviderOpenAI,
			data:     "{\"type\":\"response.completed\",\"response\":{}}",
		},
		{
			name:     "Gemini empty candidate",
			provider: ProviderGemini,
			data:     "{\"candidates\":[]}",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := streamingTextDelta(test.provider, []byte(test.data)); got != "" {
				t.Fatalf("streamingTextDelta() = %q, want empty", got)
			}
		})
	}
}

func TestStreamingRateObserverShortWindowRate(t *testing.T) {
	now := time.Unix(100, 0)
	observer := &streamingRateObserver{
		samples: []streamRateSample{
			{at: now.Add(-2 * time.Second), textRunes: 0},
			{at: now.Add(-time.Second), textRunes: 8},
			{at: now, textRunes: 12},
		},
		textRunes: 12,
	}

	rate, windowMs, windowTokens := observer.shortWindowRate(now)
	if rate != 1.5 || windowMs != 2000 || windowTokens != 3 {
		t.Fatalf("shortWindowRate() = (%v, %d, %d), want (1.5, 2000, 3)", rate, windowMs, windowTokens)
	}
}

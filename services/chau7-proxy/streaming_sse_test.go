package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStreamingMetadataAcrossReadBoundaries(t *testing.T) {
	tests := []struct {
		name     string
		provider Provider
		stream   string
		want     ResponseMetadata
	}{
		{"anthropic", ProviderAnthropic,
			"event: message_start\r\ndata: {\"message\":{\"model\":\"claude\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3}}}\r\n\r\n" +
				"data: malformed\ndata: {\"delta\":{\"text\":\"世界🙂\"}}\ndata: [DONE]\n" +
				"data: {\"usage\":{\"output_tokens\":7,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}",
			ResponseMetadata{Model: "claude", InputTokens: 10, OutputTokens: 7, CacheCreationReported: true, CacheReadReported: true}},
		{"responses", ProviderOpenAI,
			"data: {\"type\":\"response.output_text.delta\",\"delta\":\"世界🙂\"}\n\n" +
				"data: {\"type\":\"response.completed\",\"response\":{\"model\":\"gpt\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens_details\":{\"reasoning_tokens\":2}}}}",
			ResponseMetadata{Model: "gpt", InputTokens: 10, OutputTokens: 7, CacheReadReported: true, CacheReadInputTokens: 3, ReasoningOutputTokens: 2, FinishReason: "completed"}},
		{"chat", ProviderOpenAI,
			"data: {\"model\":\"gpt-chat\",\"choices\":[{\"delta\":{\"content\":\"世界🙂\"}}]}\n" +
				"data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":7}}\n\ndata: [DONE]\n",
			ResponseMetadata{Model: "gpt-chat", InputTokens: 10, OutputTokens: 7, FinishReason: "stop"}},
		{"gemini", ProviderGemini,
			"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"世界🙂\"}]}}]}\n" +
				"data: {\"modelVersion\":\"gemini\",\"candidates\":[{\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":7,\"cachedContentTokenCount\":3}}",
			ResponseMetadata{Model: "gemini", InputTokens: 10, OutputTokens: 7, CacheReadReported: true, CacheReadInputTokens: 3, FinishReason: "STOP"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			for _, size := range []int{1, 2, 7, 31, 32768} {
				observer := &streamingMetadataObserver{provider: tc.provider}
				input := []byte(tc.stream)
				for offset := 0; offset < len(input); offset += size {
					end := min(offset+size, len(input))
					n, err := observer.Write(input[offset:end])
					if err != nil || n != end-offset {
						t.Fatalf("short observer write: %d %v", n, err)
					}
				}
				if got := observer.finish(); got != tc.want {
					t.Fatalf("chunk size %d: got %+v, want %+v", size, got, tc.want)
				}
				if observer.totalBytes != len(input) {
					t.Fatalf("capture bytes=%d, want %d", observer.totalBytes, len(input))
				}
			}
		})
	}
}

func TestLargeCompletionEventStillAccountsUsage(t *testing.T) {
	// Responses completions may repeat all output before the usage object.
	// Avoid a new event-size cap that silently loses authoritative billing.
	input := `data: {"response":{"output":"` + strings.Repeat("x", 2<<20) + `","model":"gpt","usage":{"input_tokens":12,"output_tokens":34}}}` + "\n\n"
	observer := &streamingMetadataObserver{provider: ProviderOpenAI}
	data := []byte(input)
	for offset := 0; offset < len(data); offset += 4096 {
		_, _ = observer.Write(data[offset:min(offset+4096, len(data))])
	}
	want := ResponseMetadata{Model: "gpt", InputTokens: 12, OutputTokens: 34}
	if got := observer.finish(); got != want {
		t.Fatalf("large completion metadata=%+v, want %+v", got, want)
	}
	if cap(observer.lines.pending) > 64*1024 {
		t.Fatal("completed large event pinned its scratch buffer")
	}
}

func TestStreamingProxyPreservesFragmentedBytesAndUsage(t *testing.T) {
	proxy, db, _ := setupTestProxy(t)
	payload := []byte("event: message_start\ndata: {\"message\":{\"model\":\"claude-perflab\",\"usage\":{\"input_tokens\":12}}}\n\n" +
		"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"世界🙂\"}}\n\n" +
		"data: {\"usage\":{\"output_tokens\":34,\"cache_read_input_tokens\":0}}")
	parts := make([]io.Reader, 0, len(payload))
	for i := range payload {
		parts = append(parts, bytes.NewReader(payload[i:i+1]))
	}
	proxy.client.Transport = roundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/event-stream"}}, Body: io.NopCloser(io.MultiReader(parts...))}, nil
	})
	request := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(`{"model":"claude-perflab","stream":true}`))
	request.Header.Set("X-Chau7-Tab", "perflab")
	out := httptest.NewRecorder()
	proxy.ServeHTTP(out, request)
	if out.Code != 200 || !bytes.Equal(out.Body.Bytes(), payload) || !out.Flushed {
		t.Fatal("stream changed, failed, or was not flushed")
	}
	calls, err := db.GetRecentCalls(1)
	if err != nil || len(calls) != 1 {
		t.Fatalf("usage record missing: %v", err)
	}
	if IntValue(calls[0].InputTokens) != 12 || IntValue(calls[0].OutputTokens) != 34 || calls[0].CacheReadInputTokens == nil || *calls[0].CacheReadInputTokens != 0 {
		t.Fatalf("incorrect stream accounting: %+v", calls[0])
	}
}

func TestStreamingRateFragmentsPreserveUnicodeCounts(t *testing.T) {
	frame := "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"世界🙂\"}}\r\n\r\n"
	input := []byte(strings.Repeat(frame, 10) + "data: malformed\ndata: [DONE]\n")
	for _, size := range []int{1, 7, 32768} {
		ipc := NewIPCNotifier("")
		observer := &streamingRateObserver{provider: ProviderAnthropic, notifier: ipc}
		for offset := 0; offset < len(input); offset += size {
			_, _ = observer.Write(input[offset:min(offset+size, len(input))])
		}
		_ = ipc.Close()
		if observer.textRunes != 30 {
			t.Fatalf("chunk size %d counted %d text runes, want 30", size, observer.textRunes)
		}
	}
}

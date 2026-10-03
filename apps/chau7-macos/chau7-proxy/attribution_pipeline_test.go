package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCachePresenceAcrossStreamingAndNonStreamingProviders(t *testing.T) {
	cases := []struct {
		provider       Provider
		body           string
		creation, read bool
	}{
		{ProviderAnthropic, `{"usage":{"input_tokens":10,"output_tokens":5}}`, false, false},
		{ProviderAnthropic, `{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}`, true, true},
		{ProviderOpenAI, `{"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":0}}}`, false, true},
		{ProviderOpenAI, `{"usage":{"prompt_tokens":10,"completion_tokens":5}}`, false, false},
		{ProviderGemini, `{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"cachedContentTokenCount":0}}`, false, true},
	}
	for _, tc := range cases {
		for _, streaming := range []bool{false, true} {
			var meta ResponseMetadata
			if streaming {
				meta = ParseStreamingChunks(tc.provider, []byte("data: "+tc.body+"\n\n"))
			} else {
				meta = ExtractResponseMetadata(tc.provider, []byte(tc.body))
			}
			if meta.CacheCreationReported != tc.creation || meta.CacheReadReported != tc.read {
				t.Fatalf("provider %s streaming %v cache presence creation=%v read=%v", tc.provider, streaming, meta.CacheCreationReported, meta.CacheReadReported)
			}
		}
	}
}

func TestRepeatRequestCacheEvidencePersistsThroughAnalyticsAndIPC(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}`))
	}))
	defer upstream.Close()
	original := ProviderConfigs[ProviderAnthropic]
	updated := original
	updated.BaseURL = upstream.URL
	ProviderConfigs[ProviderAnthropic] = updated
	defer func() { ProviderConfigs[ProviderAnthropic] = original }()
	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()
	// Unix-domain paths have a short system limit; use a short temp root.
	root, err := os.MkdirTemp("/tmp", "c7-ipc-")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(root) }()
	socket := filepath.Join(root, "ipc.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	proxy.ipc = NewIPCNotifier(socket)
	received := make(chan IPCAPICallData, 2)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		scanner := bufio.NewScanner(conn)
		for scanner.Scan() {
			var message IPCMessage
			if json.Unmarshal(scanner.Bytes(), &message) == nil && message.Type == "api_call" {
				received <- message.Data
			}
		}
	}()
	ids := map[string]bool{}
	for i := 0; i < 2; i++ {
		request := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(`{"model":"claude-sonnet-4","messages":[]}`))
		request.Header.Set("anthropic-version", "2023-06-01")
		request.Header.Set("X-Chau7-Session", "session")
		request.Header.Set("X-Chau7-Tab", "tab")
		request.Header.Set("X-Chau7-Project", "/repo")
		response := httptest.NewRecorder()
		proxy.ServeHTTP(response, request)
		if response.Code != 200 {
			t.Fatalf("response=%d %s", response.Code, response.Body.String())
		}
		select {
		case data := <-received:
			if data.RequestID == "" || ids[data.RequestID] {
				t.Fatal("request identity missing or collapsed")
			}
			ids[data.RequestID] = true
			if data.CacheCreationInputTokens == nil || *data.CacheCreationInputTokens != 30 || data.CacheReadInputTokens == nil || *data.CacheReadInputTokens != 40 {
				t.Fatalf("cache counters missing from IPC: %+v", data)
			}
			var creation, read int
			var requestID string
			if err := db.db.QueryRow("SELECT request_id, cache_creation_input_tokens, cache_read_input_tokens FROM api_calls ORDER BY id DESC LIMIT 1").Scan(&requestID, &creation, &read); err != nil {
				t.Fatal(err)
			}
			if requestID != data.RequestID || creation != 30 || read != 40 {
				t.Fatal("analytics and IPC disagree")
			}
			want := CalculateFullCostForCall(ProviderAnthropic, "claude-sonnet-4", ResponseMetadata{InputTokens: 10, OutputTokens: 5, CacheCreationInputTokens: 30, CacheReadInputTokens: 40})
			if data.CostUSD == nil || *data.CostUSD != want {
				t.Fatal("cache-tier cost did not propagate")
			}
		case <-time.After(5 * time.Second):
			t.Fatal("IPC observation missing")
		}
	}
}

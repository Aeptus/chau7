package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// mockUpstream creates a mock upstream server for testing
func mockUpstream(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	return httptest.NewServer(handler)
}

func setupTestProxy(t *testing.T) (*ProxyHandler, *Database, string) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create test database: %v", err)
	}

	config := &Config{
		Port:          18080,
		DBPath:        dbPath,
		IPCSocketPath: "", // Disable IPC for tests
		LogLevel:      "info",
	}

	ipc := NewIPCNotifier("") // No-op notifier
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil) // No aethyme for tests
	mockup := NewMockupClient("", "")         // No mockup for tests
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, mockup)

	return proxy, db, tmpDir
}

func TestProxyHandler_BasicPassthrough(t *testing.T) {
	// Create mock upstream
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		// Verify request came through
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/v1/messages" {
			t.Errorf("Expected /v1/messages, got %s", r.URL.Path)
		}

		// Return mock response
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		response := map[string]interface{}{
			"model": "claude-3-5-sonnet",
			"usage": map[string]int{
				"input_tokens":  50,
				"output_tokens": 100,
			},
			"stop_reason": "end_turn",
			"content":     []map[string]string{{"text": "Hello!"}},
		}
		json.NewEncoder(w).Encode(response)
	})
	defer upstream.Close()

	// Override provider config for test
	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL: upstream.URL,
	}
	defer func() {
		ProviderConfigs[ProviderAnthropic] = originalConfig
	}()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	// Create test request
	reqBody := `{"model":"claude-3-5-sonnet","messages":[{"role":"user","content":"Hi"}],"max_tokens":100}`
	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(reqBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", "test-key-12345")
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("X-Chau7-Session", "test-session")

	// Execute
	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Verify response
	if w.Code != http.StatusOK {
		t.Errorf("Expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// Verify record was logged
	time.Sleep(10 * time.Millisecond) // Allow async logging
	records, _ := db.GetRecentCalls(1)
	if len(records) == 0 {
		t.Fatal("Expected record to be logged")
	}

	r := records[0]
	if r.SessionID != "test-session" {
		t.Errorf("Session mismatch: %s", r.SessionID)
	}
	if r.Provider != ProviderAnthropic {
		t.Errorf("Provider mismatch: %s", r.Provider)
	}
	if r.InputTokens != 50 || r.OutputTokens != 100 {
		t.Errorf("Token count mismatch: in=%d out=%d", r.InputTokens, r.OutputTokens)
	}
}

func TestProxyHandler_HeaderPassthrough(t *testing.T) {
	var capturedHeaders http.Header

	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		capturedHeaders = r.Header.Clone()
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"model":"gpt-4o","usage":{"prompt_tokens":10,"completion_tokens":20}}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{
		BaseURL: upstream.URL,
	}
	defer func() {
		ProviderConfigs[ProviderOpenAI] = originalConfig
	}()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewBufferString(`{"model":"gpt-4o"}`))
	req.Header.Set("Authorization", "Bearer sk-test-key-secret")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Custom-Header", "custom-value")

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Verify auth header was passed through
	if capturedHeaders.Get("Authorization") != "Bearer sk-test-key-secret" {
		t.Error("Authorization header not passed through")
	}
	if capturedHeaders.Get("Content-Type") != "application/json" {
		t.Error("Content-Type header not passed through")
	}
	if capturedHeaders.Get("X-Custom-Header") != "custom-value" {
		t.Error("Custom header not passed through")
	}
}

func TestProxyHandler_HopByHopHeadersFiltered(t *testing.T) {
	var capturedHeaders http.Header

	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		capturedHeaders = r.Header.Clone()
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewBufferString(`{}`))
	req.Header.Set("Connection", "keep-alive")
	req.Header.Set("Keep-Alive", "timeout=5")
	req.Header.Set("Transfer-Encoding", "chunked")
	req.Header.Set("Authorization", "Bearer test")

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Hop-by-hop headers should be filtered
	if capturedHeaders.Get("Connection") != "" {
		t.Error("Connection header should be filtered")
	}
	if capturedHeaders.Get("Keep-Alive") != "" {
		t.Error("Keep-Alive header should be filtered")
	}
	// But Authorization should pass through
	if capturedHeaders.Get("Authorization") == "" {
		t.Error("Authorization header should pass through")
	}
}

func TestProxyHandler_UpstreamError(t *testing.T) {
	// Create upstream that returns error
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"error":"internal server error"}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(`{"model":"claude"}`))
	req.Header.Set("anthropic-version", "2023-06-01")

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Should pass through the 500 status
	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected 500, got %d", w.Code)
	}
}

func TestProxyHandler_NoSessionHeader(t *testing.T) {
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"model":"gpt-4o","usage":{"prompt_tokens":5,"completion_tokens":10}}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewBufferString(`{}`))
	// No X-Chau7-Session header

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Should succeed
	if w.Code != http.StatusOK {
		t.Errorf("Expected 200, got %d", w.Code)
	}

	// Session should be "unknown"
	records, _ := db.GetRecentCalls(1)
	if len(records) > 0 && records[0].SessionID != "unknown" {
		t.Errorf("Expected session 'unknown', got %s", records[0].SessionID)
	}
}

func TestProxyHandler_GeminiPathExtraction(t *testing.T) {
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		response := `{
			"candidates": [{"finishReason": "STOP"}],
			"usageMetadata": {"promptTokenCount": 25, "candidatesTokenCount": 75},
			"modelVersion": "gemini-1.5-pro"
		}`
		w.Write([]byte(response))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderGemini]
	ProviderConfigs[ProviderGemini] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderGemini] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1beta/models/gemini-1.5-pro:generateContent",
		bytes.NewBufferString(`{"contents":[{"parts":[{"text":"Hi"}]}]}`))

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected 200, got %d", w.Code)
	}

	records, _ := db.GetRecentCalls(1)
	if len(records) == 0 {
		t.Fatal("Expected record")
	}

	// Model should be extracted from path or response
	if records[0].Model != "gemini-1.5-pro" {
		t.Errorf("Expected model gemini-1.5-pro, got %s", records[0].Model)
	}
	if records[0].Provider != ProviderGemini {
		t.Errorf("Expected provider gemini, got %s", records[0].Provider)
	}
}

func TestProxyHandler_StreamingResponse(t *testing.T) {
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)

		// Simulate SSE streaming
		chunks := []string{
			`data: {"type":"message_start"}`,
			`data: {"type":"content_block_delta"}`,
			`data: {"model":"claude-3-sonnet","usage":{"input_tokens":30,"output_tokens":60},"stop_reason":"end_turn"}`,
		}
		for _, chunk := range chunks {
			w.Write([]byte(chunk + "\n\n"))
		}
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	reqBody := `{"model":"claude-3-sonnet","messages":[],"stream":true}`
	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(reqBody))
	req.Header.Set("anthropic-version", "2023-06-01")

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected 200, got %d", w.Code)
	}

	// Verify response was streamed through
	body := w.Body.String()
	if !strings.Contains(body, "message_start") {
		t.Error("Expected streaming chunks in response")
	}
}

func TestProxyHandler_ResponseHeadersCopied(t *testing.T) {
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Request-Id", "req-12345")
		w.Header().Set("X-RateLimit-Remaining", "100")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewBufferString(`{}`))

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	// Response headers should be passed through
	if w.Header().Get("X-Request-Id") != "req-12345" {
		t.Error("X-Request-Id header not copied to response")
	}
	if w.Header().Get("X-RateLimit-Remaining") != "100" {
		t.Error("X-RateLimit-Remaining header not copied to response")
	}
}

func TestCopyHeaders(t *testing.T) {
	src := make(http.Header)
	dst := make(http.Header)

	src.Set("Authorization", "Bearer token")
	src.Set("Content-Type", "application/json")
	src.Set("Connection", "keep-alive") // hop-by-hop
	src.Set("X-Custom", "value")
	src.Add("X-Multi", "val1")
	src.Add("X-Multi", "val2")

	copyHeaders(src, dst)

	if dst.Get("Authorization") != "Bearer token" {
		t.Error("Authorization not copied")
	}
	if dst.Get("Content-Type") != "application/json" {
		t.Error("Content-Type not copied")
	}
	if dst.Get("Connection") != "" {
		t.Error("Connection should be filtered")
	}
	if dst.Get("X-Custom") != "value" {
		t.Error("X-Custom not copied")
	}

	multiValues := dst.Values("X-Multi")
	if len(multiValues) != 2 {
		t.Errorf("Expected 2 X-Multi values, got %d", len(multiValues))
	}
}

func TestIsHopByHopHeader(t *testing.T) {
	hopByHop := []string{
		"Connection",
		"Keep-Alive",
		"Proxy-Authenticate",
		"Proxy-Authorization",
		"Te",
		"Trailers",
		"Transfer-Encoding",
		"Upgrade",
	}

	for _, h := range hopByHop {
		if !isHopByHopHeader(h) {
			t.Errorf("%s should be hop-by-hop", h)
		}
	}

	notHopByHop := []string{
		"Authorization",
		"Content-Type",
		"X-Api-Key",
		"Accept",
		"User-Agent",
	}

	for _, h := range notHopByHop {
		if isHopByHopHeader(h) {
			t.Errorf("%s should NOT be hop-by-hop", h)
		}
	}
}

func TestProxyHandler_LargeRequestBody(t *testing.T) {
	// Create a large request body (simulating long conversation)
	messages := make([]map[string]string, 50)
	for i := 0; i < 50; i++ {
		messages[i] = map[string]string{
			"role":    "user",
			"content": strings.Repeat("This is a test message. ", 100),
		}
	}
	reqBody, _ := json.Marshal(map[string]interface{}{
		"model":    "claude-3-opus",
		"messages": messages,
	})

	var receivedBody []byte
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		receivedBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"model":"claude-3-opus","usage":{"input_tokens":5000,"output_tokens":1000}}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer db.Close()

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBuffer(reqBody))
	req.Header.Set("anthropic-version", "2023-06-01")

	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected 200, got %d", w.Code)
	}

	// Verify full body was passed through
	if len(receivedBody) != len(reqBody) {
		t.Errorf("Body size mismatch: sent %d, received %d", len(reqBody), len(receivedBody))
	}
}

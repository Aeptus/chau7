package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestUpstreamClientDoesNotCapInferenceDuration(t *testing.T) {
	client := newUpstreamHTTPClient()
	if client.Timeout != 0 {
		t.Fatalf("upstream client timeout = %s, want no total timeout", client.Timeout)
	}
}

func TestProxyServerDoesNotCapStreamDuration(t *testing.T) {
	server := newProxyHTTPServer("127.0.0.1:0", http.NewServeMux())
	if server.WriteTimeout != 0 {
		t.Fatalf("server write timeout = %s, want no total stream timeout", server.WriteTimeout)
	}
	if server.ReadTimeout != 30*time.Second {
		t.Fatalf("server read timeout = %s, want 30s", server.ReadTimeout)
	}
}

func TestProxyHandlerPropagatesClientCancellationUpstream(t *testing.T) {
	upstreamStarted := make(chan struct{})
	upstreamCancelled := make(chan struct{})

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()
	proxy.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(upstreamStarted)
		<-r.Context().Done()
		close(upstreamCancelled)
		return nil, r.Context().Err()
	})

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(`{"model":"claude-opus-5"}`)).WithContext(ctx)
	req.Header.Set("anthropic-version", "2023-06-01")
	recorder := httptest.NewRecorder()
	proxyDone := make(chan struct{})
	go func() {
		proxy.ServeHTTP(recorder, req)
		close(proxyDone)
	}()

	select {
	case <-upstreamStarted:
	case <-time.After(time.Second):
		t.Fatal("proxy did not start the upstream request")
	}
	cancel()

	select {
	case <-upstreamCancelled:
	case <-time.After(time.Second):
		t.Fatal("upstream request was not cancelled with the client request")
	}
	select {
	case <-proxyDone:
	case <-time.After(time.Second):
		t.Fatal("proxy handler did not return after cancellation")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestBuildWebSocketUpgradeRequestPreservesSubscriptionAuth(t *testing.T) {
	const projectPath = "/tmp/Codex Subscription/été"
	projectToken := base64.RawURLEncoding.EncodeToString([]byte(projectPath))
	req := httptest.NewRequest(
		"GET",
		projectCorrelationPathPrefix+projectToken+"/v1/responses?model=gpt-5",
		nil,
	)
	req.Header.Set("Authorization", "Bearer opaque-chatgpt-access-token")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Key", "test-websocket-key")
	req.Header.Set("Sec-WebSocket-Version", "13")

	if err := applyPathCorrelation(req); err != nil {
		t.Fatalf("apply correlation path: %v", err)
	}
	upstream, err := url.Parse(GetUpstreamURL(DetectProvider(req), req))
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	raw, err := buildWebSocketUpgradeRequest(req, upstream)
	if err != nil {
		t.Fatalf("build upgrade request: %v", err)
	}
	forwarded, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(raw)))
	if err != nil {
		t.Fatalf("parse forwarded request: %v", err)
	}

	if got, want := forwarded.Host, "chatgpt.com"; got != want {
		t.Errorf("host = %q, want %q", got, want)
	}
	if got, want := forwarded.URL.RequestURI(), "/backend-api/codex/responses?model=gpt-5"; got != want {
		t.Errorf("request URI = %q, want %q", got, want)
	}
	if got, want := forwarded.Header.Get("Authorization"), "Bearer opaque-chatgpt-access-token"; got != want {
		t.Errorf("authorization = %q, want %q", got, want)
	}
	if !isWebSocketUpgrade(forwarded) {
		t.Error("WebSocket negotiation headers were not preserved")
	}
	if got := forwarded.Header.Get(HeaderProject); got != "" {
		t.Errorf("internal project header leaked upstream: %q", got)
	}
}

func TestProxyHandler_StoresAnthropicProjectHeaderExactly(t *testing.T) {
	const projectPath = "/tmp/Claude Project/été"
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get(HeaderProject); got != "" {
			t.Errorf("internal project header leaked upstream: %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"model": "claude-sonnet-4",
			"usage": map[string]int{"input_tokens": 1, "output_tokens": 1},
		})
	})
	defer upstream.Close()

	original := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = original }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewBufferString(`{"model":"claude-sonnet-4"}`))
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set(HeaderProject, projectPath)
	recorder := httptest.NewRecorder()
	proxy.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("Anthropic call failed: %d: %s", recorder.Code, recorder.Body.String())
	}
	assertStoredProjectPath(t, db, ProviderAnthropic, projectPath)
}

func TestProxyHandler_StoresCodexPathProjectExactly(t *testing.T) {
	const projectPath = "/tmp/Codex Project/été"
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/responses" {
			t.Errorf("internal correlation prefix was not stripped: %q", r.URL.Path)
		}
		if got := r.Header.Get(HeaderProject); got != "" {
			t.Errorf("materialized project header leaked upstream: %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"model": "gpt-5",
			"usage": map[string]int{"input_tokens": 1, "output_tokens": 1},
		})
	})
	defer upstream.Close()

	original := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = original }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

	projectToken := base64.RawURLEncoding.EncodeToString([]byte(projectPath))
	path := projectCorrelationPathPrefix + projectToken + "/v1/responses"
	req := httptest.NewRequest("POST", path, bytes.NewBufferString(`{"model":"gpt-5"}`))
	req.Header.Set("Authorization", "Bearer sk-test")
	recorder := httptest.NewRecorder()
	proxy.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("OpenAI call failed: %d: %s", recorder.Code, recorder.Body.String())
	}
	assertStoredProjectPath(t, db, ProviderOpenAI, projectPath)
}

func assertStoredProjectPath(t *testing.T, db *Database, provider Provider, expected string) {
	t.Helper()
	var projectPath string
	err := db.db.QueryRow(
		"SELECT project_path FROM api_calls WHERE provider = ? ORDER BY id DESC LIMIT 1",
		string(provider),
	).Scan(&projectPath)
	if err != nil {
		t.Fatalf("read stored project path: %v", err)
	}
	if projectPath != expected {
		t.Fatalf("stored project path = %q, want %q", projectPath, expected)
	}
}

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
	mockup, err := NewMockupClient("", "")    // No mockup for tests
	if err != nil {
		t.Fatalf("Failed to create mockup client: %v", err)
	}
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, mockup, nil)

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
		_ = json.NewEncoder(w).Encode(response)
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
	defer func() { _ = db.Close() }()

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
	if IntValue(r.InputTokens) != 50 || IntValue(r.OutputTokens) != 100 {
		t.Errorf("Token count mismatch: in=%d out=%d", IntValue(r.InputTokens), IntValue(r.OutputTokens))
	}
}

func TestProxyHandler_HeaderPassthrough(t *testing.T) {
	var capturedHeaders http.Header

	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		capturedHeaders = r.Header.Clone()
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"model":"gpt-4o","usage":{"prompt_tokens":10,"completion_tokens":20}}`))
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
	defer func() { _ = db.Close() }()

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
		_, _ = w.Write([]byte(`{}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

	req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewBufferString(`{}`))
	req.Header.Set("Connection", "keep-alive")
	req.Header.Set("Keep-Alive", "timeout=5")
	req.Header.Set("Transfer-Encoding", "chunked")
	req.Header.Set("Authorization", "Bearer sk-test")

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
		_, _ = w.Write([]byte(`{"error":"internal server error"}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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
		_, _ = w.Write([]byte(`{"model":"gpt-4o","usage":{"prompt_tokens":5,"completion_tokens":10}}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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
		_, _ = w.Write([]byte(response))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderGemini]
	ProviderConfigs[ProviderGemini] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderGemini] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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
			_, _ = w.Write([]byte(chunk + "\n\n"))
		}
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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

func TestProxyHandlerFlushesStreamingChunkBeforeUpstreamCompletes(t *testing.T) {
	firstChunkWritten := make(chan struct{})
	releaseUpstream := make(chan struct{})
	var releaseOnce sync.Once
	release := func() {
		releaseOnce.Do(func() { close(releaseUpstream) })
	}
	defer release()

	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		close(firstChunkWritten)
		<-releaseUpstream
		_, _ = io.WriteString(w, "data: second\n\n")
		w.(http.Flusher).Flush()
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()
	downstream := httptest.NewServer(proxy)
	defer downstream.Close()

	req, err := http.NewRequest("POST", downstream.URL+"/v1/messages",
		bytes.NewBufferString(`{"model":"claude-opus-5","messages":[],"stream" : true}`))
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	req.Header.Set("anthropic-version", "2023-06-01")

	type responseResult struct {
		response *http.Response
		err      error
	}
	responseReady := make(chan responseResult, 1)
	go func() {
		response, requestErr := http.DefaultClient.Do(req)
		responseReady <- responseResult{response: response, err: requestErr}
	}()

	select {
	case <-firstChunkWritten:
	case <-time.After(time.Second):
		t.Fatal("upstream did not write its first streaming chunk")
	}

	var response *http.Response
	select {
	case result := <-responseReady:
		if result.err != nil {
			t.Fatalf("request proxy stream: %v", result.err)
		}
		response = result.response
	case <-time.After(time.Second):
		t.Fatal("proxy did not flush response headers with the first streaming chunk")
	}
	defer func() { _ = response.Body.Close() }()

	reader := bufio.NewReader(response.Body)
	firstLine := make(chan string, 1)
	go func() {
		line, _ := reader.ReadString('\n')
		firstLine <- line
	}()
	select {
	case line := <-firstLine:
		if line != "data: first\n" {
			t.Fatalf("first streamed line = %q, want first chunk", line)
		}
	case <-time.After(time.Second):
		t.Fatal("first streaming chunk remained buffered until upstream completion")
	}

	release()
	remainder, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read remainder of proxy stream: %v", err)
	}
	if !strings.Contains(string(remainder), "data: second\n") {
		t.Fatalf("stream remainder = %q, want second chunk", remainder)
	}
}

func TestProxyHandler_ResponseHeadersCopied(t *testing.T) {
	upstream := mockUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Request-Id", "req-12345")
		w.Header().Set("X-RateLimit-Remaining", "100")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderOpenAI]
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderOpenAI] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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
		_, _ = w.Write([]byte(`{"model":"claude-3-opus","usage":{"input_tokens":5000,"output_tokens":1000}}`))
	})
	defer upstream.Close()

	originalConfig := ProviderConfigs[ProviderAnthropic]
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{BaseURL: upstream.URL}
	defer func() { ProviderConfigs[ProviderAnthropic] = originalConfig }()

	proxy, db, _ := setupTestProxy(t)
	defer func() { _ = db.Close() }()

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

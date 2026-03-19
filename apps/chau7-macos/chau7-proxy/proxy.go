package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ProxyHandler handles incoming requests and forwards them to upstream providers
type ProxyHandler struct {
	config      *Config
	db          *Database
	ipc         *IPCNotifier
	taskManager *TaskManager
	baseline    *BaselineEstimator // v1.2
	mockup      *MockupClient      // v1.2
	client      *http.Client
}

// NewProxyHandler creates a new proxy handler
func NewProxyHandler(config *Config, db *Database, ipc *IPCNotifier, taskManager *TaskManager, baseline *BaselineEstimator, mockup *MockupClient) *ProxyHandler {
	return &ProxyHandler{
		config:      config,
		db:          db,
		ipc:         ipc,
		taskManager: taskManager,
		baseline:    baseline,
		mockup:      mockup,
		client: &http.Client{
			Timeout: 5 * time.Minute, // Long timeout for streaming responses
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 10,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}
}

// ServeHTTP handles incoming HTTP requests
func (p *ProxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// WebSocket upgrade: tunnel bidirectionally instead of request-response proxy.
	// Codex CLI uses WebSocket transport for the Responses API; stripping the
	// Upgrade header forces a fallback to HTTPS POST which may fail auth checks
	// for ChatGPT-OAuth tokens that lack api.responses.write scope.
	if isWebSocketUpgrade(r) {
		p.handleWebSocket(w, r)
		return
	}

	startTime := time.Now()

	// Extract correlation headers
	headers := ExtractCorrelationHeaders(r)

	// Read request body
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	// Extract prompt preview for task naming (first 500 chars)
	promptPreview := extractPromptPreview(bodyBytes, p.config.LogPrompts)

	// Process through task manager to get task ID
	taskID, _ := p.taskManager.ProcessAPICall(headers, promptPreview)

	// Handle candidate: prefix (provisional assignment during grace period)
	actualTaskID := taskID
	if strings.HasPrefix(taskID, "candidate:") {
		// During grace period, track the call for potential reassignment
		actualTaskID = "" // Will be updated when candidate is confirmed/dismissed
	}

	// Detect provider from request
	provider := DetectProvider(r)
	upstreamURL := GetUpstreamURL(provider, r)

	// Extract request metadata
	reqMeta := ExtractRequestMetadata(provider, bodyBytes)

	// For Gemini, model is in the path
	model := reqMeta.Model
	if model == "" && provider == ProviderGemini {
		model = ExtractModelFromPath(r.URL.Path)
	}

	// Log the request (if debug)
	if p.config.LogLevel == "debug" {
		log.Printf("[DEBUG] %s %s -> %s (provider: %s, model: %s, task: %s)",
			r.Method, r.URL.Path, upstreamURL, provider, model, taskID)
	}

	// Create upstream request
	upstream, err := http.NewRequest(r.Method, upstreamURL, bytes.NewReader(bodyBytes))
	if err != nil {
		p.logError(headers, provider, model, r.URL.Path, err.Error(), startTime)
		http.Error(w, "Failed to create upstream request", http.StatusInternalServerError)
		return
	}

	// Copy headers, but strip X-Chau7-* headers before forwarding
	copyHeadersFiltered(r.Header, upstream.Header)

	// Forward the request
	resp, err := p.client.Do(upstream)
	if err != nil {
		p.logError(headers, provider, model, r.URL.Path, err.Error(), startTime)
		http.Error(w, "Upstream request failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Copy response headers
	copyHeaders(resp.Header, w.Header())
	w.WriteHeader(resp.StatusCode)

	// Stream response while capturing for metadata extraction.
	// Wrap in firstByteReader to measure time-to-first-token (TTFT).
	var responseBuffer bytes.Buffer
	fbr := &firstByteReader{reader: resp.Body, start: startTime}
	tee := io.TeeReader(fbr, &responseBuffer)

	// Copy response body to client
	bytesWritten, err := io.Copy(w, tee)
	if err != nil {
		log.Printf("[WARN] Error copying response: %v", err)
	}

	// Calculate latencies
	latencyMs := time.Since(startTime).Milliseconds()
	ttftMs := fbr.ttftMs()

	// Extract response metadata
	respBody := responseBuffer.Bytes()
	var respMeta ResponseMetadata

	// Check if this was a streaming response
	isStreaming := IsStreamingRequest(provider, bodyBytes)
	if isStreaming {
		respMeta = ParseStreamingChunks(provider, respBody)
	} else {
		respMeta = ExtractResponseMetadata(provider, respBody)
	}

	// Use model from response if not already set
	if respMeta.Model != "" {
		model = respMeta.Model
	}

	// Calculate cost
	cost := CalculateCostForCall(provider, model, respMeta.InputTokens, respMeta.OutputTokens)

	// v1.2: Calculate baseline estimate
	var baseline *BaselineEstimate
	if p.baseline != nil && resp.StatusCode == 200 {
		// Extract context pack ID from headers if present
		contextPackID := r.Header.Get("X-Chau7-Context-Pack")

		baseline = p.baseline.EstimateBaseline(
			provider,
			model,
			promptPreview,
			respMeta.InputTokens,
			respMeta.OutputTokens,
			contextPackID,
		)

		// Record call for historical stats
		p.baseline.RecordCall(model, respMeta.OutputTokens)

		// Update database with output stats
		if p.db != nil {
			if err := p.db.UpdateModelOutputStats(model, respMeta.OutputTokens); err != nil {
				if p.config.LogLevel == "debug" {
					log.Printf("[DEBUG] Failed to update model stats: %v", err)
				}
			}
		}
	}

	// Create record
	record := &APICallRecord{
		SessionID:    headers.SessionID,
		Provider:     provider,
		Model:        model,
		Endpoint:     r.URL.Path,
		InputTokens:  respMeta.InputTokens,
		OutputTokens: respMeta.OutputTokens,
		LatencyMs:    latencyMs,
		TTFTMs:       ttftMs,
		StatusCode:   resp.StatusCode,
		CostUSD:      cost,
		Timestamp:    startTime,
	}

	// Log to database with task correlation and baseline (v1.2)
	var callID int64
	if baseline != nil {
		callID, err = p.db.InsertAPICallWithBaseline(record, actualTaskID, headers.TabID, headers.Project, baseline)
	} else {
		callID, err = p.db.InsertAPICallWithTask(record, actualTaskID, headers.TabID, headers.Project)
	}
	if err != nil {
		log.Printf("[WARN] Failed to log API call: %v", err)
	}

	// If this call was made during candidate grace period, track it for potential reassignment
	if strings.HasPrefix(taskID, "candidate:") && callID > 0 {
		p.taskManager.AddPendingCall(headers.TabID, strconv.FormatInt(callID, 10))
	}

	// Notify host application via IPC with task context
	if err := p.ipc.NotifyAPICallWithTask(record, actualTaskID, headers.TabID, headers.Project); err != nil {
		// Don't log IPC errors too frequently
		if p.config.LogLevel == "debug" {
			log.Printf("[DEBUG] IPC notification failed: %v", err)
		}
	}

	// v1.2: Forward event to Mockup analytics
	if p.mockup != nil {
		if err := p.mockup.SendAPICallEvent(record, actualTaskID, baseline, headers); err != nil {
			if p.config.LogLevel == "debug" {
				log.Printf("[DEBUG] Mockup forwarding failed: %v", err)
			}
		}
	}

	// Log summary
	savedInfo := ""
	if baseline != nil {
		savedInfo = fmt.Sprintf(" | saved:%d", baseline.TokensSaved)
	}
	log.Printf("[INFO] %s %s: %d | %s | in:%d out:%d | %dms (ttft:%dms) | $%.4f | task:%s%s",
		r.Method, r.URL.Path, resp.StatusCode, model,
		respMeta.InputTokens, respMeta.OutputTokens, latencyMs, ttftMs, cost, actualTaskID, savedInfo)

	_ = bytesWritten // Silence unused variable warning
}

// logError logs an error and stores it in the database
func (p *ProxyHandler) logError(headers *CorrelationHeaders, provider Provider, model, endpoint, errMsg string, startTime time.Time) {
	log.Printf("[ERROR] %s %s: %s", provider, endpoint, errMsg)

	record := &APICallRecord{
		SessionID:    headers.SessionID,
		Provider:     provider,
		Model:        model,
		Endpoint:     endpoint,
		StatusCode:   502,
		LatencyMs:    time.Since(startTime).Milliseconds(),
		Timestamp:    startTime,
		ErrorMessage: errMsg,
	}

	if _, err := p.db.InsertAPICallWithTask(record, "", headers.TabID, headers.Project); err != nil {
		log.Printf("[WARN] Failed to log error: %v", err)
	}
}

// copyHeaders copies headers from src to dst
// This preserves all headers including authentication
func copyHeaders(src, dst http.Header) {
	for key, values := range src {
		// Skip hop-by-hop headers
		if isHopByHopHeader(key) {
			continue
		}
		for _, v := range values {
			dst.Add(key, v)
		}
	}
}

// copyHeadersFiltered copies headers but strips X-Chau7-* correlation headers
func copyHeadersFiltered(src, dst http.Header) {
	for key, values := range src {
		// Skip hop-by-hop headers
		if isHopByHopHeader(key) {
			continue
		}
		// Skip Chau7 correlation headers
		if IsCorrelationHeader(key) {
			continue
		}
		for _, v := range values {
			dst.Add(key, v)
		}
	}
}

// isHopByHopHeader returns true for headers that should not be forwarded
func isHopByHopHeader(header string) bool {
	hopByHop := map[string]bool{
		"Connection":          true,
		"Keep-Alive":          true,
		"Proxy-Authenticate":  true,
		"Proxy-Authorization": true,
		"Te":                  true,
		"Trailers":            true,
		"Transfer-Encoding":   true,
		"Upgrade":             true,
	}
	return hopByHop[header]
}

// extractPromptPreview extracts the first N characters of the prompt for task naming
func extractPromptPreview(body []byte, verbose bool) string {
	// Try to parse as JSON and extract the prompt/messages
	type Message struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}
	type Request struct {
		Prompt   string    `json:"prompt"`
		Messages []Message `json:"messages"`
	}

	var req Request
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}

	var prompt string

	// Try prompt field (older API)
	if req.Prompt != "" {
		prompt = req.Prompt
	}

	// Try messages array (chat API)
	if len(req.Messages) > 0 {
		// Get the last user message
		for i := len(req.Messages) - 1; i >= 0; i-- {
			if req.Messages[i].Role == "user" {
				prompt = req.Messages[i].Content
				break
			}
		}
	}

	// Limit length
	maxLen := 500
	if !verbose {
		maxLen = 200
	}
	if len(prompt) > maxLen {
		prompt = prompt[:maxLen]
	}

	return prompt
}

// isWebSocketUpgrade returns true when the request is an HTTP/1.1 WebSocket handshake.
func isWebSocketUpgrade(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

// handleWebSocket tunnels a WebSocket upgrade request to the upstream provider.
// It hijacks the client connection, dials the upstream over TLS, replays the
// upgrade request verbatim, and then pipes bytes bidirectionally.
func (p *ProxyHandler) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	provider := DetectProvider(r)
	upstreamURL := GetUpstreamURL(provider, r)

	log.Printf("[INFO] WebSocket upgrade: %s -> %s", r.URL.Path, upstreamURL)

	// Parse upstream URL to get host:port for TLS dial
	upstreamParsed, err := url.Parse(upstreamURL)
	if err != nil {
		log.Printf("[ERROR] WebSocket: bad upstream URL: %v", err)
		http.Error(w, "Bad upstream URL", http.StatusBadGateway)
		return
	}

	host := upstreamParsed.Hostname()
	port := upstreamParsed.Port()
	if port == "" {
		if upstreamParsed.Scheme == "https" || upstreamParsed.Scheme == "wss" {
			port = "443"
		} else {
			port = "80"
		}
	}

	// Connect to upstream over TLS
	tlsConn, err := tls.Dial("tcp", host+":"+port, &tls.Config{ServerName: host})
	if err != nil {
		log.Printf("[ERROR] WebSocket: TLS dial failed: %v", err)
		http.Error(w, "Upstream connection failed", http.StatusBadGateway)
		return
	}
	defer tlsConn.Close()

	// Build the upgrade request to send to upstream.
	// Use the upstream path and forward all headers except X-Chau7-*.
	path := upstreamParsed.Path
	if upstreamParsed.RawQuery != "" {
		path += "?" + upstreamParsed.RawQuery
	}

	var reqBuf bytes.Buffer
	fmt.Fprintf(&reqBuf, "%s %s HTTP/1.1\r\n", r.Method, path)
	fmt.Fprintf(&reqBuf, "Host: %s\r\n", host)
	for key, values := range r.Header {
		if IsCorrelationHeader(key) {
			continue
		}
		for _, v := range values {
			fmt.Fprintf(&reqBuf, "%s: %s\r\n", key, v)
		}
	}
	reqBuf.WriteString("\r\n")

	if _, err := tlsConn.Write(reqBuf.Bytes()); err != nil {
		log.Printf("[ERROR] WebSocket: failed to write upgrade request: %v", err)
		http.Error(w, "Failed to send upgrade", http.StatusBadGateway)
		return
	}

	// Hijack the client connection
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		log.Printf("[ERROR] WebSocket: response writer does not support hijacking")
		http.Error(w, "WebSocket not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		log.Printf("[ERROR] WebSocket: hijack failed: %v", err)
		return
	}
	defer clientConn.Close()

	// Bidirectional pipe: client <-> upstream
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(clientConn, tlsConn)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(tlsConn, clientConn)
		done <- struct{}{}
	}()
	<-done
}

// firstByteReader wraps an io.Reader and records the timestamp of the first
// Read() call that returns data. This measures Time-to-First-Token (TTFT) —
// the latency between sending the request and receiving the first response byte.
type firstByteReader struct {
	reader    io.Reader
	start     time.Time
	firstByte time.Time
	gotFirst  bool
}

func (f *firstByteReader) Read(p []byte) (int, error) {
	n, err := f.reader.Read(p)
	if n > 0 && !f.gotFirst {
		f.firstByte = time.Now()
		f.gotFirst = true
	}
	return n, err
}

func (f *firstByteReader) ttftMs() int64 {
	if !f.gotFirst {
		return 0
	}
	return f.firstByte.Sub(f.start).Milliseconds()
}

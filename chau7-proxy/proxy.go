package main

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"time"
)

// ProxyHandler handles incoming requests and forwards them to upstream providers
type ProxyHandler struct {
	config   *Config
	db       *Database
	ipc      *IPCNotifier
	client   *http.Client
}

// NewProxyHandler creates a new proxy handler
func NewProxyHandler(config *Config, db *Database, ipc *IPCNotifier) *ProxyHandler {
	return &ProxyHandler{
		config: config,
		db:     db,
		ipc:    ipc,
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
	startTime := time.Now()

	// Get session ID from header (set by Chau7)
	sessionID := r.Header.Get("X-Chau7-Session")
	if sessionID == "" {
		sessionID = "unknown"
	}

	// Read request body
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body.Close()

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
		log.Printf("[DEBUG] %s %s -> %s (provider: %s, model: %s)",
			r.Method, r.URL.Path, upstreamURL, provider, model)
	}

	// Create upstream request
	upstream, err := http.NewRequest(r.Method, upstreamURL, bytes.NewReader(bodyBytes))
	if err != nil {
		p.logError(sessionID, provider, model, r.URL.Path, err.Error(), startTime)
		http.Error(w, "Failed to create upstream request", http.StatusInternalServerError)
		return
	}

	// Copy ALL headers unchanged (including auth headers)
	// This is critical - we pass through authentication as-is
	copyHeaders(r.Header, upstream.Header)

	// Forward the request
	resp, err := p.client.Do(upstream)
	if err != nil {
		p.logError(sessionID, provider, model, r.URL.Path, err.Error(), startTime)
		http.Error(w, "Upstream request failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Copy response headers
	copyHeaders(resp.Header, w.Header())
	w.WriteHeader(resp.StatusCode)

	// Stream response while capturing for metadata extraction
	var responseBuffer bytes.Buffer
	tee := io.TeeReader(resp.Body, &responseBuffer)

	// Copy response body to client
	bytesWritten, err := io.Copy(w, tee)
	if err != nil {
		log.Printf("[WARN] Error copying response: %v", err)
	}

	// Calculate latency
	latencyMs := time.Since(startTime).Milliseconds()

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

	// Create record
	record := &APICallRecord{
		SessionID:    sessionID,
		Provider:     provider,
		Model:        model,
		Endpoint:     r.URL.Path,
		InputTokens:  respMeta.InputTokens,
		OutputTokens: respMeta.OutputTokens,
		LatencyMs:    latencyMs,
		StatusCode:   resp.StatusCode,
		CostUSD:      cost,
		Timestamp:    startTime,
	}

	// Log to database
	if err := p.db.InsertAPICall(record); err != nil {
		log.Printf("[WARN] Failed to log API call: %v", err)
	}

	// Notify host application via IPC
	if err := p.ipc.NotifyAPICall(record); err != nil {
		// Don't log IPC errors too frequently
		if p.config.LogLevel == "debug" {
			log.Printf("[DEBUG] IPC notification failed: %v", err)
		}
	}

	// Log summary
	log.Printf("[INFO] %s %s: %d | %s | in:%d out:%d | %dms | $%.4f",
		r.Method, r.URL.Path, resp.StatusCode, model,
		respMeta.InputTokens, respMeta.OutputTokens, latencyMs, cost)

	_ = bytesWritten // Silence unused variable warning
}

// logError logs an error and stores it in the database
func (p *ProxyHandler) logError(sessionID string, provider Provider, model, endpoint, errMsg string, startTime time.Time) {
	log.Printf("[ERROR] %s %s: %s", provider, endpoint, errMsg)

	record := &APICallRecord{
		SessionID:    sessionID,
		Provider:     provider,
		Model:        model,
		Endpoint:     endpoint,
		StatusCode:   502,
		LatencyMs:    time.Since(startTime).Milliseconds(),
		Timestamp:    startTime,
		ErrorMessage: errMsg,
	}

	if err := p.db.InsertAPICall(record); err != nil {
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

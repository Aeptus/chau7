package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestNewMockupClient_NilOnEmptyURL(t *testing.T) {
	client, err := NewMockupClient("", "api-key")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if client != nil {
		t.Error("Expected nil client for empty URL")
	}
}

func TestMockupClient_SendEvent(t *testing.T) {
	var received []MockupEvent
	var mu sync.Mutex

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/events" {
			t.Errorf("Unexpected path: %s", r.URL.Path)
		}

		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}

		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("Missing or incorrect Authorization header")
		}

		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Events []MockupEvent `json:"events"`
		}
		_ = json.Unmarshal(body, &payload)

		mu.Lock()
		received = append(received, payload.Events...)
		mu.Unlock()

		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client, err := NewMockupClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	defer func() { _ = client.Close() }()

	event := &MockupEvent{
		SchemaVersion: "1.0.0",
		Type:          "test_event",
		Timestamp:     time.Now(),
		Tool:          "proxy",
		Origin:        "proxy",
		Data:          map[string]interface{}{"key": "value"},
	}

	err = client.SendEvent(event)
	if err != nil {
		t.Fatalf("SendEvent error: %v", err)
	}

	// Flush to send immediately
	err = client.Flush()
	if err != nil {
		t.Fatalf("Flush error: %v", err)
	}

	mu.Lock()
	if len(received) != 1 {
		t.Errorf("Expected 1 event, got %d", len(received))
	}
	mu.Unlock()
}

func TestMockupClient_SendAPICallEvent(t *testing.T) {
	var receivedEvent MockupEvent

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Events []MockupEvent `json:"events"`
		}
		_ = json.Unmarshal(body, &payload)
		if len(payload.Events) > 0 {
			receivedEvent = payload.Events[0]
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client, err := NewMockupClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	defer func() { _ = client.Close() }()

	record := &APICallRecord{
		SessionID:    "sess_123",
		Provider:     ProviderAnthropic,
		Model:        "claude-sonnet-4",
		Endpoint:     "/v1/messages",
		InputTokens:  IntPointer(1000),
		OutputTokens: IntPointer(500),
		LatencyMs:    250,
		StatusCode:   200,
		CostUSD:      FloatPointer(0.0075),
		Timestamp:    time.Now(),
	}

	baseline := &BaselineEstimate{
		InputTokens:  1500,
		OutputTokens: 800,
		TotalTokens:  2300,
		Method:       BaselineMethodHistoricalAvg,
		Version:      BaselineVersion,
		TokensSaved:  800,
	}

	headers := &CorrelationHeaders{
		SessionID: "sess_123",
		TabID:     "tab_456",
		TenantID:  "tenant_789",
	}

	err = client.SendAPICallEvent(record, "task_abc", baseline, headers)
	if err != nil {
		t.Fatalf("SendAPICallEvent error: %v", err)
	}

	_ = client.Flush()

	if receivedEvent.Type != "api_call" {
		t.Errorf("Event type = %q, want api_call", receivedEvent.Type)
	}

	if receivedEvent.TenantID != "tenant_789" {
		t.Errorf("TenantID = %q, want tenant_789", receivedEvent.TenantID)
	}

	data := receivedEvent.Data.(map[string]interface{})
	if data["tokens_saved"] != float64(800) { // JSON numbers are float64
		t.Errorf("tokens_saved = %v, want 800", data["tokens_saved"])
	}
}

func TestMockupClient_BatchFlush(t *testing.T) {
	flushCount := 0
	var mu sync.Mutex

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		flushCount++
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client, err := NewMockupClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	client.batchSize = 5 // Small batch for testing
	defer func() { _ = client.Close() }()

	// Send 10 events
	for i := 0; i < 10; i++ {
		_ = client.SendEvent(&MockupEvent{
			Type:      "test",
			Timestamp: time.Now(),
		})
	}

	// Wait for batch flush
	time.Sleep(100 * time.Millisecond)

	mu.Lock()
	if flushCount < 1 {
		t.Errorf("Expected at least 1 flush, got %d", flushCount)
	}
	mu.Unlock()
}

func TestMockupClient_Stats(t *testing.T) {
	client, err := NewMockupClient("https://example.com", "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	defer func() { _ = client.Close() }()

	// Send some events
	for i := 0; i < 5; i++ {
		_ = client.SendEvent(&MockupEvent{
			Type:      "test",
			Timestamp: time.Now(),
		})
	}

	stats := client.Stats()
	if stats == nil {
		t.Fatal("Expected non-nil stats")
	}

	queued := stats["queued_events"].(int)
	if queued != 5 {
		t.Errorf("queued_events = %d, want 5", queued)
	}
}

func TestMockupClient_Health(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	client, err := NewMockupClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	defer func() { _ = client.Close() }()

	err = client.Health()
	if err != nil {
		t.Errorf("Health check failed: %v", err)
	}
}

func TestMockupClient_NilClientMethods(t *testing.T) {
	var client *MockupClient

	// All methods should handle nil gracefully
	err := client.SendEvent(&MockupEvent{})
	if err != nil {
		t.Error("SendEvent on nil client should return nil")
	}

	err = client.Flush()
	if err != nil {
		t.Error("Flush on nil client should return nil")
	}

	err = client.Close()
	if err != nil {
		t.Error("Close on nil client should return nil")
	}

	err = client.Health()
	if err != nil {
		t.Error("Health on nil client should return nil")
	}

	stats := client.Stats()
	if stats != nil {
		t.Error("Stats on nil client should return nil")
	}
}

func TestMockupClient_TaskEvent(t *testing.T) {
	var receivedEvent MockupEvent

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Events []MockupEvent `json:"events"`
		}
		_ = json.Unmarshal(body, &payload)
		if len(payload.Events) > 0 {
			receivedEvent = payload.Events[0]
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client, err := NewMockupClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}
	defer func() { _ = client.Close() }()

	task := &Task{
		ID:          "task_123",
		TabID:       "tab_456",
		SessionID:   "sess_789",
		ProjectPath: "/path/to/repo",
		Name:        "Fix critical bug",
		State:       TaskStateActive,
		Trigger:     TriggerManual,
		StartMethod: StartMethodManual,
	}

	headers := &CorrelationHeaders{
		TenantID: "tenant_abc",
		OrgID:    "org_def",
		UserID:   "user_ghi",
	}

	extra := map[string]interface{}{
		"custom_field": "custom_value",
	}

	err = client.SendTaskEvent("task_started", task, headers, extra)
	if err != nil {
		t.Fatalf("SendTaskEvent error: %v", err)
	}

	_ = client.Flush()

	if receivedEvent.Type != "task_started" {
		t.Errorf("Event type = %q, want task_started", receivedEvent.Type)
	}

	if receivedEvent.TenantID != "tenant_abc" {
		t.Errorf("TenantID = %q, want tenant_abc", receivedEvent.TenantID)
	}

	data := receivedEvent.Data.(map[string]interface{})
	if data["task_id"] != "task_123" {
		t.Errorf("task_id = %v, want task_123", data["task_id"])
	}

	if data["custom_field"] != "custom_value" {
		t.Errorf("custom_field = %v, want custom_value", data["custom_field"])
	}
}

func TestNewMockupClient_InvalidBaseURL(t *testing.T) {
	client, err := NewMockupClient("http://example.com", "api-key")
	if err == nil {
		t.Fatal("Expected error for non-loopback http URL")
	}
	if client != nil {
		t.Fatal("Expected nil client for invalid URL")
	}
}

func TestNewMockupClient_AllowsHTTPSPathPrefix(t *testing.T) {
	client, err := NewMockupClient("https://api.example.com/mockup/", "api-key")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if client == nil {
		t.Fatal("Expected client")
	}
	if client.baseURL != "https://api.example.com/mockup" {
		t.Fatalf("Got baseURL %q", client.baseURL)
	}
}

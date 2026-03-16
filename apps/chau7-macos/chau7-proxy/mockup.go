package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// MockupEvent represents an event to be forwarded to Mockup
type MockupEvent struct {
	SchemaVersion string      `json:"schema_version"`
	Type          string      `json:"type"`
	Timestamp     time.Time   `json:"ts"`
	Tool          string      `json:"tool"`
	Origin        string      `json:"origin"`
	TenantID      string      `json:"tenant_id,omitempty"`
	OrgID         string      `json:"org_id,omitempty"`
	UserID        string      `json:"user_id,omitempty"`
	Data          interface{} `json:"data"`
}

// MockupClient handles event forwarding to the Mockup SaaS analytics service
type MockupClient struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client

	// Batching configuration
	batchSize     int
	flushInterval time.Duration

	// Internal state
	mu        sync.Mutex
	batch     []*MockupEvent
	lastFlush time.Time

	// Background flushing
	ctx       context.Context
	cancel    context.CancelFunc
	flushChan chan struct{}
	doneChan  chan struct{}
}

// NewMockupClient creates a new Mockup event forwarding client
func NewMockupClient(baseURL, apiKey string) (*MockupClient, error) {
	if baseURL == "" {
		return nil, nil // Mockup is optional
	}

	normalizedBaseURL, err := normalizeServiceBaseURL(baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid Mockup base URL: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	client := &MockupClient{
		baseURL:       normalizedBaseURL,
		apiKey:        apiKey,
		httpClient:    newRestrictedHTTPClient(30 * time.Second),
		batchSize:     100,
		flushInterval: 5 * time.Second,
		batch:         make([]*MockupEvent, 0, 100),
		lastFlush:     time.Now(),
		ctx:           ctx,
		cancel:        cancel,
		flushChan:     make(chan struct{}, 1),
		doneChan:      make(chan struct{}),
	}

	// Start background flusher
	go client.backgroundFlush()

	return client, nil
}

// SendEvent queues an event for forwarding to Mockup
func (c *MockupClient) SendEvent(event *MockupEvent) error {
	if c == nil {
		return nil // Mockup is optional
	}

	c.mu.Lock()
	c.batch = append(c.batch, event)
	shouldFlush := len(c.batch) >= c.batchSize
	c.mu.Unlock()

	if shouldFlush {
		select {
		case c.flushChan <- struct{}{}:
		default:
			// Flush already pending
		}
	}

	return nil
}

// SendAPICallEvent creates and sends an API call event
func (c *MockupClient) SendAPICallEvent(record *APICallRecord, taskID string, baseline *BaselineEstimate, headers *CorrelationHeaders) error {
	if c == nil {
		return nil
	}

	data := map[string]interface{}{
		"call_id":       fmt.Sprintf("call_%d", time.Now().UnixNano()),
		"provider":      string(record.Provider),
		"model":         record.Model,
		"endpoint":      record.Endpoint,
		"input_tokens":  record.InputTokens,
		"output_tokens": record.OutputTokens,
		"total_tokens":  record.InputTokens + record.OutputTokens,
		"latency_ms":    record.LatencyMs,
		"status_code":   record.StatusCode,
		"cost_usd":      record.CostUSD,
		"session_id":    record.SessionID,
		"task_id":       taskID,
	}

	// Add baseline data if available
	if baseline != nil {
		data["baseline_total_tokens"] = baseline.TotalTokens
		data["baseline_method"] = string(baseline.Method)
		data["baseline_version"] = baseline.Version
		data["tokens_saved"] = baseline.TokensSaved
	}

	if record.ErrorMessage != "" {
		data["error_message"] = record.ErrorMessage
	}

	event := &MockupEvent{
		SchemaVersion: "1.0.0",
		Type:          "api_call",
		Timestamp:     record.Timestamp,
		Tool:          "proxy",
		Origin:        "proxy",
		TenantID:      headers.TenantID,
		OrgID:         headers.OrgID,
		UserID:        headers.UserID,
		Data:          data,
	}

	return c.SendEvent(event)
}

// SendTaskEvent creates and sends a task lifecycle event
func (c *MockupClient) SendTaskEvent(eventType string, task *Task, headers *CorrelationHeaders, extra map[string]interface{}) error {
	if c == nil {
		return nil
	}

	data := map[string]interface{}{
		"task_id":      task.ID,
		"tab_id":       task.TabID,
		"session_id":   task.SessionID,
		"project_path": task.ProjectPath,
		"task_name":    task.Name,
		"state":        string(task.State),
		"trigger":      string(task.Trigger),
		"start_method": string(task.StartMethod),
	}

	// Merge extra data
	for k, v := range extra {
		data[k] = v
	}

	event := &MockupEvent{
		SchemaVersion: "1.0.0",
		Type:          eventType,
		Timestamp:     time.Now(),
		Tool:          "proxy",
		Origin:        "proxy",
		TenantID:      headers.TenantID,
		OrgID:         headers.OrgID,
		UserID:        headers.UserID,
		Data:          data,
	}

	return c.SendEvent(event)
}

// SendTaskAssessmentEvent sends a task assessment event
func (c *MockupClient) SendTaskAssessmentEvent(assessment *TaskAssessment, task *Task, baseline *BaselineEstimate, headers *CorrelationHeaders) error {
	if c == nil {
		return nil
	}

	data := map[string]interface{}{
		"task_id":          assessment.TaskID,
		"approved":         assessment.Approved,
		"note":             assessment.Note,
		"total_api_calls":  assessment.TotalAPICalls,
		"total_tokens":     assessment.TotalTokens,
		"total_cost_usd":   assessment.TotalCostUSD,
		"duration_seconds": assessment.DurationSeconds,
	}

	if baseline != nil {
		data["tokens_saved"] = baseline.TokensSaved
		data["baseline_method"] = string(baseline.Method)
	}

	if task != nil {
		data["tab_id"] = task.TabID
		data["session_id"] = task.SessionID
		data["project_path"] = task.ProjectPath
		data["task_name"] = task.Name
	}

	event := &MockupEvent{
		SchemaVersion: "1.0.0",
		Type:          "task_assessment",
		Timestamp:     assessment.AssessedAt,
		Tool:          "proxy",
		Origin:        "proxy",
		TenantID:      headers.TenantID,
		OrgID:         headers.OrgID,
		UserID:        headers.UserID,
		Data:          data,
	}

	return c.SendEvent(event)
}

// Flush immediately sends all queued events
func (c *MockupClient) Flush() error {
	if c == nil {
		return nil
	}

	c.mu.Lock()
	if len(c.batch) == 0 {
		c.mu.Unlock()
		return nil
	}

	events := c.batch
	c.batch = make([]*MockupEvent, 0, c.batchSize)
	c.mu.Unlock()

	err := c.sendBatch(events)

	c.mu.Lock()
	if err != nil {
		// On failure, prepend events back to batch for retry
		// Limit to avoid unbounded growth (keep most recent if over limit)
		maxRetainedEvents := c.batchSize * 10
		if len(c.batch)+len(events) > maxRetainedEvents {
			// Drop oldest events (from failed batch) to make room
			keepFromFailed := maxRetainedEvents - len(c.batch)
			if keepFromFailed > 0 {
				c.batch = append(events[len(events)-keepFromFailed:], c.batch...)
			}
		} else {
			c.batch = append(events, c.batch...)
		}
	}
	c.lastFlush = time.Now()
	c.mu.Unlock()

	return err
}

// sendBatch sends a batch of events to Mockup
func (c *MockupClient) sendBatch(events []*MockupEvent) error {
	if len(events) == 0 {
		return nil
	}

	payload := map[string]interface{}{
		"events": events,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("mockup: failed to marshal events: %w", err)
	}

	req, err := http.NewRequest("POST", buildServiceURL(c.baseURL, "/api/v1/events"), bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("mockup: failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("mockup: failed to send events: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("mockup: server returned %d: %s", resp.StatusCode, string(respBody))
	}

	return nil
}

// backgroundFlush periodically flushes queued events
func (c *MockupClient) backgroundFlush() {
	ticker := time.NewTicker(c.flushInterval)
	defer ticker.Stop()
	defer close(c.doneChan)

	for {
		select {
		case <-c.ctx.Done():
			// Final flush on shutdown
			if err := c.Flush(); err != nil {
				log.Printf("[WARN] Mockup final flush failed: %v", err)
			}
			return

		case <-ticker.C:
			if err := c.Flush(); err != nil {
				log.Printf("[WARN] Mockup periodic flush failed: %v", err)
			}

		case <-c.flushChan:
			if err := c.Flush(); err != nil {
				log.Printf("[WARN] Mockup batch flush failed: %v", err)
			}
		}
	}
}

// Close shuts down the client and flushes remaining events
func (c *MockupClient) Close() error {
	if c == nil {
		return nil
	}

	c.cancel()
	<-c.doneChan

	return nil
}

// Health checks if the Mockup service is available
func (c *MockupClient) Health() error {
	if c == nil {
		return nil // Mockup is optional
	}

	resp, err := c.httpClient.Get(buildServiceURL(c.baseURL, "/health"))
	if err != nil {
		return fmt.Errorf("mockup: health check failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("mockup: health check returned %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// Stats returns current client statistics
func (c *MockupClient) Stats() map[string]interface{} {
	if c == nil {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	return map[string]interface{}{
		"queued_events": len(c.batch),
		"last_flush":    c.lastFlush,
	}
}

package main

import (
	"encoding/json"
	"net"
	"sync"
	"time"
)

// Schema version for all events
const SchemaVersion = "1.0.0"

// IPCNotifier handles notifications to the host application via Unix socket
type IPCNotifier struct {
	socketPath string
	conn       net.Conn
	mu         sync.Mutex
	retryDelay time.Duration
	db         *Database // For storing events
}

// NewIPCNotifier creates a new IPC notifier
// If socketPath is empty, notifications are disabled (no-op)
func NewIPCNotifier(socketPath string) *IPCNotifier {
	return &IPCNotifier{
		socketPath: socketPath,
		retryDelay: 5 * time.Second,
	}
}

// SetDatabase sets the database reference for event storage
func (n *IPCNotifier) SetDatabase(db *Database) {
	n.db = db
}

// NotifyAPICall sends an API call completion notification to the host app
func (n *IPCNotifier) NotifyAPICall(record *APICallRecord) error {
	return n.NotifyAPICallWithTask(record, "", "", "")
}

// NotifyAPICallWithTask sends an API call notification with task context
func (n *IPCNotifier) NotifyAPICallWithTask(record *APICallRecord, taskID, tabID, projectPath string) error {
	if n.socketPath == "" {
		return nil // IPC disabled
	}

	msg := &IPCEventMessage{
		SchemaVersion: SchemaVersion,
		Type:          "api_call",
		Tool:          "proxy",
		Origin:        "proxy",
		Timestamp:     record.Timestamp.UTC().Format(time.RFC3339),
		Data: IPCAPICallData{
			SessionID:                record.SessionID,
			Provider:                 string(record.Provider),
			Model:                    record.Model,
			Endpoint:                 record.Endpoint,
			InputTokens:              record.InputTokens,
			OutputTokens:             record.OutputTokens,
			CacheCreationInputTokens: record.CacheCreationInputTokens,
			CacheReadInputTokens:     record.CacheReadInputTokens,
			ReasoningOutputTokens:    record.ReasoningOutputTokens,
			LatencyMs:                record.LatencyMs,
			TTFTMs:                   record.TTFTMs,
			StatusCode:               record.StatusCode,
			CostUSD:                  record.CostUSD,
			PricingVersion:           record.PricingVersion,
			Timestamp:                record.Timestamp.UTC().Format(time.RFC3339),
			ErrorMessage:             record.ErrorMessage,
			TaskID:                   taskID,
			TabID:                    tabID,
			ProjectPath:              projectPath,
		},
	}

	return n.sendEvent(msg)
}

// NotifyTaskCandidate sends a task candidate notification
func (n *IPCNotifier) NotifyTaskCandidate(candidate *TaskCandidate) error {
	if n.socketPath == "" {
		return nil
	}

	msg := &IPCEventMessage{
		SchemaVersion: SchemaVersion,
		Type:          "task_candidate",
		Tool:          "proxy",
		Origin:        "proxy",
		Timestamp:     candidate.CreatedAt.UTC().Format(time.RFC3339),
		Data: IPCTaskCandidateData{
			CandidateID:        candidate.ID,
			TabID:              candidate.TabID,
			SessionID:          candidate.SessionID,
			ProjectPath:        candidate.ProjectPath,
			SuggestedName:      candidate.SuggestedName,
			Trigger:            string(candidate.Trigger),
			Confidence:         candidate.Confidence,
			GracePeriodSeconds: int64(time.Until(candidate.GracePeriodEnd).Seconds()),
		},
	}

	return n.sendEvent(msg)
}

// NotifyTaskStarted sends a task started notification
func (n *IPCNotifier) NotifyTaskStarted(task *Task) error {
	if n.socketPath == "" {
		return nil
	}

	msg := &IPCEventMessage{
		SchemaVersion: SchemaVersion,
		Type:          "task_started",
		Tool:          "proxy",
		Origin:        "proxy",
		Timestamp:     task.StartedAt.UTC().Format(time.RFC3339),
		Data: IPCTaskStartedData{
			TaskID:      task.ID,
			CandidateID: task.CandidateID,
			TabID:       task.TabID,
			SessionID:   task.SessionID,
			ProjectPath: task.ProjectPath,
			TaskName:    task.Name,
			StartMethod: string(task.StartMethod),
			Trigger:     string(task.Trigger),
		},
	}

	return n.sendEvent(msg)
}

// NotifyTaskCandidateDismissed sends a candidate dismissed notification
func (n *IPCNotifier) NotifyTaskCandidateDismissed(candidate *TaskCandidate, dismissMethod string) error {
	if n.socketPath == "" {
		return nil
	}

	msg := &IPCEventMessage{
		SchemaVersion: SchemaVersion,
		Type:          "task_candidate_dismissed",
		Tool:          "proxy",
		Origin:        "proxy",
		Timestamp:     time.Now().UTC().Format(time.RFC3339),
		Data: IPCTaskDismissedData{
			CandidateID:   candidate.ID,
			TabID:         candidate.TabID,
			DismissMethod: dismissMethod,
			Reason:        "user_dismissed",
		},
	}

	return n.sendEvent(msg)
}

// NotifyTaskAssessment sends a task assessment notification (legacy, without baseline)
func (n *IPCNotifier) NotifyTaskAssessment(task *Task, assessment *TaskAssessment) error {
	return n.NotifyTaskAssessmentWithBaseline(task, assessment, nil)
}

// NotifyTaskAssessmentWithBaseline sends a task assessment notification with baseline metrics
func (n *IPCNotifier) NotifyTaskAssessmentWithBaseline(task *Task, assessment *TaskAssessment, baseline *TaskBaselineMetrics) error {
	if n.socketPath == "" {
		return nil
	}

	// v1.2: Include tokens saved from baseline metrics
	var tokensSaved *int
	if baseline != nil && baseline.BaselineCallCount > 0 {
		tokensSaved = &baseline.TokensSaved
	}

	msg := &IPCEventMessage{
		SchemaVersion: SchemaVersion,
		Type:          "task_assessment",
		Tool:          "proxy",
		Origin:        "proxy",
		Timestamp:     assessment.AssessedAt.UTC().Format(time.RFC3339),
		Data: IPCTaskAssessmentData{
			TaskID:          task.ID,
			TabID:           task.TabID,
			SessionID:       task.SessionID,
			Approved:        assessment.Approved,
			Note:            assessment.Note,
			TotalAPICalls:   assessment.TotalAPICalls,
			TotalTokens:     assessment.TotalTokens,
			TotalCostUSD:    assessment.TotalCostUSD,
			TokensSaved:     tokensSaved,
			DurationSeconds: assessment.DurationSeconds,
		},
	}

	return n.sendEvent(msg)
}

// sendEvent sends an event message to the host application and optionally stores it
func (n *IPCNotifier) sendEvent(msg *IPCEventMessage) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	// Store event in database if available
	if n.db != nil {
		_ = n.db.InsertEvent(msg.Type, data)
	}

	// Send via socket
	return n.sendBytes(data)
}

// sendBytes sends raw bytes to the Unix socket with a single retry on failure.
// This handles stale sockets after the app restarts without blocking on repeated failures.
func (n *IPCNotifier) sendBytes(data []byte) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	msg := append(data, '\n')
	for attempt := 0; attempt < 2; attempt++ {
		if n.conn == nil {
			conn, err := net.DialTimeout("unix", n.socketPath, 2*time.Second)
			if err != nil {
				return err
			}
			n.conn = conn
		}

		_ = n.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if _, err := n.conn.Write(msg); err != nil {
			_ = n.conn.Close()
			n.conn = nil
			if attempt == 0 {
				continue // retry once with a fresh connection
			}
			return err
		}
		return nil
	}
	return nil
}

// Close closes the IPC connection
func (n *IPCNotifier) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.conn != nil {
		err := n.conn.Close()
		n.conn = nil
		return err
	}
	return nil
}

// --- Message Types ---

// IPCMessage is the legacy message format (kept for backward compatibility)
type IPCMessage struct {
	Type string         `json:"type"`
	Data IPCAPICallData `json:"data"`
}

// IPCEventMessage is the new v1.0 event format with schema versioning
type IPCEventMessage struct {
	SchemaVersion string      `json:"schema_version"`
	Type          string      `json:"type"`
	Tool          string      `json:"tool"`
	Origin        string      `json:"origin"`
	Timestamp     string      `json:"ts"`
	Data          interface{} `json:"data"`
}

// IPCAPICallData contains the data for an API call notification
type IPCAPICallData struct {
	SessionID                string   `json:"session_id"`
	Provider                 string   `json:"provider"`
	Model                    string   `json:"model"`
	Endpoint                 string   `json:"endpoint"`
	InputTokens              *int     `json:"input_tokens"`
	OutputTokens             *int     `json:"output_tokens"`
	CacheCreationInputTokens *int     `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     *int     `json:"cache_read_input_tokens"`
	ReasoningOutputTokens    *int     `json:"reasoning_output_tokens"`
	LatencyMs                int64    `json:"latency_ms"`
	TTFTMs                   int64    `json:"ttft_ms"`
	StatusCode               int      `json:"status_code"`
	CostUSD                  *float64 `json:"cost_usd"`
	PricingVersion           string   `json:"pricing_version,omitempty"`
	Timestamp                string   `json:"timestamp"`
	ErrorMessage             string   `json:"error_message,omitempty"`
	TaskID                   string   `json:"task_id,omitempty"`
	TabID                    string   `json:"tab_id,omitempty"`
	ProjectPath              string   `json:"project_path,omitempty"`
}

// IPCTaskCandidateData contains data for a task candidate notification
type IPCTaskCandidateData struct {
	CandidateID        string  `json:"candidate_id"`
	TabID              string  `json:"tab_id"`
	SessionID          string  `json:"session_id"`
	ProjectPath        string  `json:"project_path"`
	SuggestedName      string  `json:"suggested_name"`
	Trigger            string  `json:"trigger"`
	Confidence         float64 `json:"confidence"`
	GracePeriodSeconds int64   `json:"grace_period_seconds"`
}

// IPCTaskStartedData contains data for a task started notification
type IPCTaskStartedData struct {
	TaskID      string `json:"task_id"`
	CandidateID string `json:"candidate_id,omitempty"`
	TabID       string `json:"tab_id"`
	SessionID   string `json:"session_id"`
	ProjectPath string `json:"project_path"`
	TaskName    string `json:"task_name"`
	StartMethod string `json:"start_method"`
	Trigger     string `json:"trigger"`
}

// IPCTaskDismissedData contains data for a candidate dismissed notification
type IPCTaskDismissedData struct {
	CandidateID   string `json:"candidate_id"`
	TabID         string `json:"tab_id"`
	DismissMethod string `json:"dismiss_method"`
	Reason        string `json:"reason"`
}

// IPCTaskAssessmentData contains data for a task assessment notification
type IPCTaskAssessmentData struct {
	TaskID          string  `json:"task_id"`
	TabID           string  `json:"tab_id"`
	SessionID       string  `json:"session_id"`
	Approved        bool    `json:"approved"`
	Note            string  `json:"note,omitempty"`
	TotalAPICalls   int     `json:"total_api_calls"`
	TotalTokens     int     `json:"total_tokens"`
	TotalCostUSD    float64 `json:"total_cost_usd"`
	TokensSaved     *int    `json:"tokens_saved"` // null until v1.2
	DurationSeconds int64   `json:"duration_seconds"`
}

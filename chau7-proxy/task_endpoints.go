package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

// TaskEndpoints handles HTTP endpoints for task management
type TaskEndpoints struct {
	tm *TaskManager
	db *Database
}

// NewTaskEndpoints creates a new task endpoints handler
func NewTaskEndpoints(tm *TaskManager, db *Database) *TaskEndpoints {
	return &TaskEndpoints{tm: tm, db: db}
}

// --- Request/Response Types ---

// CandidateResponse is returned by GET /task/candidate
type CandidateResponse struct {
	HasCandidate     bool    `json:"has_candidate"`
	CandidateID      string  `json:"candidate_id,omitempty"`
	SuggestedName    string  `json:"suggested_name,omitempty"`
	Trigger          string  `json:"trigger,omitempty"`
	GraceRemainingMs int64   `json:"grace_remaining_ms,omitempty"`
	Confidence       float64 `json:"confidence,omitempty"`
}

// StartTaskRequest is the body for POST /task/start
type StartTaskRequest struct {
	TabID       string `json:"tab_id"`
	TaskName    string `json:"task_name,omitempty"`
	CandidateID string `json:"candidate_id,omitempty"` // Optional: confirm specific candidate
}

// StartTaskResponse is returned by POST /task/start
type StartTaskResponse struct {
	TaskID   string `json:"task_id"`
	TaskName string `json:"task_name"`
}

// DismissRequest is the body for POST /task/dismiss
type DismissRequest struct {
	TabID       string `json:"tab_id"`
	CandidateID string `json:"candidate_id"`
}

// DismissResponse is returned by POST /task/dismiss
type DismissResponse struct {
	Dismissed       bool `json:"dismissed"`
	ReassignedCalls int  `json:"reassigned_calls"` // Number of calls moved to previous task
}

// AssessRequest is the body for POST /task/assess
type AssessRequest struct {
	TaskID   string `json:"task_id"`
	Approved bool   `json:"approved"`
	Note     string `json:"note,omitempty"`
}

// AssessResponse is returned by POST /task/assess
type AssessResponse struct {
	Success bool `json:"success"`
}

// CurrentTaskResponse is returned by GET /task/current
type CurrentTaskResponse struct {
	HasTask      bool    `json:"has_task"`
	TaskID       string  `json:"task_id,omitempty"`
	TaskName     string  `json:"task_name,omitempty"`
	State        string  `json:"state,omitempty"`
	TotalCalls   int     `json:"total_calls,omitempty"`
	TotalTokens  int     `json:"total_tokens,omitempty"`
	TotalCostUSD float64 `json:"total_cost_usd,omitempty"`
	DurationSec  int64   `json:"duration_sec,omitempty"`
	StartMethod  string  `json:"start_method,omitempty"`
	Trigger      string  `json:"trigger,omitempty"`
	ProjectPath  string  `json:"project_path,omitempty"`
}

// UpdateNameRequest is the body for PUT /task/name
type UpdateNameRequest struct {
	TaskID  string `json:"task_id"`
	NewName string `json:"new_name"`
}

// ErrorResponse is returned on errors
type ErrorResponse struct {
	Error string `json:"error"`
	Code  string `json:"code,omitempty"` // e.g., "no_candidate", "task_not_found"
}

// EventsResponse is returned by GET /events
type EventsResponse struct {
	Events     []Event `json:"events"`
	TotalCount int     `json:"total_count"`
	Offset     int     `json:"offset"`
	Limit      int     `json:"limit"`
}

// Event represents a generic event for the events endpoint
type Event struct {
	Type      string      `json:"type"`
	Timestamp string      `json:"timestamp"`
	Data      interface{} `json:"data"`
}

// --- HTTP Handlers ---

// HandleGetCandidate handles GET /task/candidate
func (te *TaskEndpoints) HandleGetCandidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	tabID := r.URL.Query().Get("tab_id")
	if tabID == "" {
		tabID = "default"
	}

	candidate := te.tm.GetCandidate(tabID)
	if candidate == nil {
		writeJSON(w, CandidateResponse{HasCandidate: false})
		return
	}

	graceRemaining := time.Until(candidate.GracePeriodEnd).Milliseconds()
	if graceRemaining < 0 {
		graceRemaining = 0
	}

	writeJSON(w, CandidateResponse{
		HasCandidate:     true,
		CandidateID:      candidate.ID,
		SuggestedName:    candidate.SuggestedName,
		Trigger:          string(candidate.Trigger),
		GraceRemainingMs: graceRemaining,
		Confidence:       candidate.Confidence,
	})
}

// HandleStartTask handles POST /task/start
func (te *TaskEndpoints) HandleStartTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	var req StartTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", "invalid_body", http.StatusBadRequest)
		return
	}

	if req.TabID == "" {
		req.TabID = "default"
	}

	task, err := te.tm.StartTask(req.TabID, req.TaskName, req.CandidateID)
	if err != nil {
		writeError(w, err.Error(), "start_failed", http.StatusBadRequest)
		return
	}

	writeJSON(w, StartTaskResponse{
		TaskID:   task.ID,
		TaskName: task.Name,
	})
}

// HandleDismissCandidate handles POST /task/dismiss
func (te *TaskEndpoints) HandleDismissCandidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	var req DismissRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", "invalid_body", http.StatusBadRequest)
		return
	}

	if req.TabID == "" {
		req.TabID = "default"
	}

	dismissed, reassigned := te.tm.DismissCandidate(req.TabID, req.CandidateID, "endpoint")
	writeJSON(w, DismissResponse{
		Dismissed:       dismissed,
		ReassignedCalls: reassigned,
	})
}

// HandleAssessTask handles POST /task/assess
func (te *TaskEndpoints) HandleAssessTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	var req AssessRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", "invalid_body", http.StatusBadRequest)
		return
	}

	if req.TaskID == "" {
		writeError(w, "task_id is required", "missing_task_id", http.StatusBadRequest)
		return
	}

	if err := te.tm.AssessTask(req.TaskID, req.Approved, req.Note); err != nil {
		writeError(w, err.Error(), "assess_failed", http.StatusBadRequest)
		return
	}

	writeJSON(w, AssessResponse{Success: true})
}

// HandleGetCurrentTask handles GET /task/current
func (te *TaskEndpoints) HandleGetCurrentTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	tabID := r.URL.Query().Get("tab_id")
	if tabID == "" {
		tabID = "default"
	}

	task := te.tm.GetCurrentTask(tabID)
	if task == nil || task.State != TaskStateActive {
		writeJSON(w, CurrentTaskResponse{HasTask: false})
		return
	}

	durationSec := int64(time.Since(task.StartedAt).Seconds())

	writeJSON(w, CurrentTaskResponse{
		HasTask:      true,
		TaskID:       task.ID,
		TaskName:     task.Name,
		State:        string(task.State),
		TotalCalls:   task.TotalAPICalls,
		TotalTokens:  task.TotalTokens,
		TotalCostUSD: task.TotalCostUSD,
		DurationSec:  durationSec,
		StartMethod:  string(task.StartMethod),
		Trigger:      string(task.Trigger),
		ProjectPath:  task.ProjectPath,
	})
}

// HandleUpdateTaskName handles PUT /task/name
func (te *TaskEndpoints) HandleUpdateTaskName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut && r.Method != http.MethodPost {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	var req UpdateNameRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", "invalid_body", http.StatusBadRequest)
		return
	}

	if err := te.tm.UpdateTaskName(req.TaskID, req.NewName); err != nil {
		writeError(w, err.Error(), "update_failed", http.StatusBadRequest)
		return
	}

	writeJSON(w, map[string]bool{"success": true})
}

// HandleGetEvents handles GET /events
func (te *TaskEndpoints) HandleGetEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse pagination params
	limit := 50
	offset := 0
	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 && parsed <= 200 {
			limit = parsed
		}
	}
	if o := r.URL.Query().Get("offset"); o != "" {
		if parsed, err := strconv.Atoi(o); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	// Get events from database
	events, total, err := te.db.GetEvents(limit, offset)
	if err != nil {
		writeError(w, "failed to get events", "db_error", http.StatusInternalServerError)
		return
	}

	writeJSON(w, EventsResponse{
		Events:     events,
		TotalCount: total,
		Offset:     offset,
		Limit:      limit,
	})
}

// --- Helper Functions ---

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, message, code string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{Error: message, Code: code})
}

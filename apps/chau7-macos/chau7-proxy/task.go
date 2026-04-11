package main

import (
	"crypto/rand"
	"encoding/hex"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

// TaskState represents the current state of a task
type TaskState string

const (
	TaskStateNone      TaskState = "none"
	TaskStateCandidate TaskState = "candidate"
	TaskStateActive    TaskState = "active"
	TaskStateCompleted TaskState = "completed"
	TaskStateAbandoned TaskState = "abandoned"
)

// TaskTrigger describes what caused a task to be created
type TaskTrigger string

const (
	TriggerManual     TaskTrigger = "manual"      // X-Chau7-New-Task: true
	TriggerNewSession TaskTrigger = "new_session" // New session ID detected
	TriggerIdleGap    TaskTrigger = "idle_gap"    // Idle timeout exceeded
	TriggerRepoSwitch TaskTrigger = "repo_switch" // Project path changed
)

// TaskStartMethod describes how a task was started
type TaskStartMethod string

const (
	StartMethodManual        TaskStartMethod = "manual"         // Via X-Chau7-New-Task header
	StartMethodAutoConfirmed TaskStartMethod = "auto_confirmed" // Candidate auto-confirmed after grace period
	StartMethodUserConfirmed TaskStartMethod = "user_confirmed" // User explicitly confirmed candidate
)

// Task represents a unit of work being tracked
type Task struct {
	ID             string          `json:"id"`
	CandidateID    string          `json:"candidate_id,omitempty"`
	TabID          string          `json:"tab_id"`
	SessionID      string          `json:"session_id"`
	ProjectPath    string          `json:"project_path"`
	Name           string          `json:"name"`
	State          TaskState       `json:"state"`
	StartMethod    TaskStartMethod `json:"start_method,omitempty"`
	Trigger        TaskTrigger     `json:"trigger,omitempty"`
	StartedAt      time.Time       `json:"started_at"`
	CompletedAt    *time.Time      `json:"completed_at,omitempty"`
	GracePeriodEnd *time.Time      `json:"grace_period_end,omitempty"`

	// Metrics (computed)
	TotalAPICalls int     `json:"total_api_calls"`
	TotalTokens   int     `json:"total_tokens"`
	TotalCostUSD  float64 `json:"total_cost_usd"`
}

// TaskCandidate represents a pending task that may be confirmed
type TaskCandidate struct {
	ID             string      `json:"candidate_id"`
	TabID          string      `json:"tab_id"`
	SessionID      string      `json:"session_id"`
	ProjectPath    string      `json:"project_path"`
	SuggestedName  string      `json:"suggested_name"`
	Trigger        TaskTrigger `json:"trigger"`
	Confidence     float64     `json:"confidence"`
	GracePeriodEnd time.Time   `json:"grace_period_end"`
	CreatedAt      time.Time   `json:"created_at"`

	// Calls made during candidate grace period (for potential reassignment)
	PendingCallIDs []string `json:"-"`
}

// TaskManager manages task lifecycle across all tabs
type TaskManager struct {
	mu sync.RWMutex

	// Current active task per tab
	tasks map[string]*Task // tabID -> current task

	// Pending candidates per tab (only one candidate per tab at a time)
	candidates map[string]*TaskCandidate // tabID -> pending candidate

	// Track last activity per tab for idle detection
	lastActivity map[string]time.Time // tabID -> last activity timestamp

	// Track last project per tab for repo switch detection
	lastProject map[string]string // tabID -> last project path

	// Track last session per tab for new session detection
	lastSession map[string]string // tabID -> last session ID

	// Configuration
	gracePeriod time.Duration
	idleTimeout time.Duration

	// Dependencies
	db     *Database
	ipc    *IPCNotifier
	mockup *MockupClient // v1.2: for analytics forwarding
}

// NewTaskManager creates a new task manager
func NewTaskManager(db *Database, ipc *IPCNotifier, gracePeriod, idleTimeout time.Duration) *TaskManager {
	tm := &TaskManager{
		tasks:        make(map[string]*Task),
		candidates:   make(map[string]*TaskCandidate),
		lastActivity: make(map[string]time.Time),
		lastProject:  make(map[string]string),
		lastSession:  make(map[string]string),
		gracePeriod:  gracePeriod,
		idleTimeout:  idleTimeout,
		db:           db,
		ipc:          ipc,
	}

	// Start background goroutine for auto-confirming candidates
	go tm.runGracePeriodChecker()

	return tm
}

// SetMockupClient sets the mockup client for analytics forwarding
func (tm *TaskManager) SetMockupClient(mockup *MockupClient) {
	tm.mockup = mockup
}

// ProcessAPICall handles task lifecycle for an incoming API call
// Returns the task ID to associate with this call
func (tm *TaskManager) ProcessAPICall(headers *CorrelationHeaders, promptPreview string) (string, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	tabID := headers.TabID
	now := time.Now()

	// Handle dismiss candidate header
	if headers.DismissCandidate != "" {
		tm.dismissCandidateLocked(tabID, headers.DismissCandidate, "header")
	}

	// Check for triggers in priority order
	trigger := tm.detectTrigger(headers, now)

	// Handle manual trigger - bypasses candidate state
	if headers.NewTask {
		task := tm.createTaskLocked(tabID, headers, TriggerManual, StartMethodManual, promptPreview)
		return task.ID, nil
	}

	// If there's a trigger, create or update candidate
	if trigger != "" {
		tm.createCandidateLocked(tabID, headers, trigger, promptPreview)
	}

	// Update tracking state
	tm.lastActivity[tabID] = now
	tm.lastProject[tabID] = headers.Project
	tm.lastSession[tabID] = headers.SessionID

	// Return current task ID (may be from candidate or active task)
	if candidate := tm.candidates[tabID]; candidate != nil {
		// During grace period, calls are provisionally assigned to candidate
		// They'll be reassigned if candidate is dismissed
		return "candidate:" + candidate.ID, nil
	}

	if task := tm.tasks[tabID]; task != nil && task.State == TaskStateActive {
		return task.ID, nil
	}

	return "", nil // No active task
}

// detectTrigger checks if any trigger condition is met
func (tm *TaskManager) detectTrigger(headers *CorrelationHeaders, now time.Time) TaskTrigger {
	tabID := headers.TabID

	// Check for new session (only if there's no current task)
	if lastSession, exists := tm.lastSession[tabID]; exists {
		if headers.SessionID != lastSession && tm.tasks[tabID] == nil {
			return TriggerNewSession
		}
	} else if tm.tasks[tabID] == nil {
		// First call on this tab
		return TriggerNewSession
	}

	// Check for idle gap
	if lastActivity, exists := tm.lastActivity[tabID]; exists {
		if now.Sub(lastActivity) > tm.idleTimeout {
			return TriggerIdleGap
		}
	}

	// Check for repo switch
	if lastProject, exists := tm.lastProject[tabID]; exists {
		if headers.Project != "" && headers.Project != lastProject {
			return TriggerRepoSwitch
		}
	}

	return ""
}

// createCandidateLocked creates a new task candidate (must hold lock)
func (tm *TaskManager) createCandidateLocked(tabID string, headers *CorrelationHeaders, trigger TaskTrigger, promptPreview string) *TaskCandidate {
	// Don't create new candidate if one already exists
	if tm.candidates[tabID] != nil {
		return tm.candidates[tabID]
	}

	now := time.Now()
	candidate := &TaskCandidate{
		ID:             generateID("cand"),
		TabID:          tabID,
		SessionID:      headers.SessionID,
		ProjectPath:    headers.Project,
		SuggestedName:  deriveTaskName(promptPreview, headers.TaskName),
		Trigger:        trigger,
		Confidence:     calculateConfidence(trigger),
		GracePeriodEnd: now.Add(tm.gracePeriod),
		CreatedAt:      now,
		PendingCallIDs: []string{},
	}

	tm.candidates[tabID] = candidate

	// Emit task_candidate event
	_ = tm.ipc.NotifyTaskCandidate(candidate)

	return candidate
}

// createTaskLocked creates a new active task (must hold lock)
func (tm *TaskManager) createTaskLocked(tabID string, headers *CorrelationHeaders, trigger TaskTrigger, startMethod TaskStartMethod, promptPreview string) *Task {
	now := time.Now()

	// Complete any existing task
	if existingTask := tm.tasks[tabID]; existingTask != nil && existingTask.State == TaskStateActive {
		existingTask.State = TaskStateAbandoned
		existingTask.CompletedAt = &now
		_ = tm.db.UpdateTask(existingTask)
	}

	// Clear any pending candidate
	delete(tm.candidates, tabID)

	taskName := deriveTaskName(promptPreview, headers.TaskName)
	task := &Task{
		ID:          generateID("task"),
		TabID:       tabID,
		SessionID:   headers.SessionID,
		ProjectPath: headers.Project,
		Name:        taskName,
		State:       TaskStateActive,
		StartMethod: startMethod,
		Trigger:     trigger,
		StartedAt:   now,
	}

	tm.tasks[tabID] = task

	// Save to database
	_ = tm.db.InsertTask(task)

	// Emit task_started event
	_ = tm.ipc.NotifyTaskStarted(task)

	return task
}

// confirmCandidate confirms a pending candidate and creates an active task
func (tm *TaskManager) confirmCandidate(tabID string, candidateID string, startMethod TaskStartMethod) (*Task, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	candidate := tm.candidates[tabID]
	if candidate == nil || (candidateID != "" && candidate.ID != candidateID) {
		return nil, ErrNoCandidateFound
	}

	// Create task from candidate
	task := &Task{
		ID:          generateID("task"),
		CandidateID: candidate.ID,
		TabID:       tabID,
		SessionID:   candidate.SessionID,
		ProjectPath: candidate.ProjectPath,
		Name:        candidate.SuggestedName,
		State:       TaskStateActive,
		StartMethod: startMethod,
		Trigger:     candidate.Trigger,
		StartedAt:   time.Now(),
	}

	// Update any pending calls to point to this task
	for _, callID := range candidate.PendingCallIDs {
		_ = tm.db.UpdateCallTaskID(callID, task.ID)
	}

	// Complete any existing task
	now := time.Now()
	if existingTask := tm.tasks[tabID]; existingTask != nil && existingTask.State == TaskStateActive {
		existingTask.State = TaskStateAbandoned
		existingTask.CompletedAt = &now
		_ = tm.db.UpdateTask(existingTask)
	}

	tm.tasks[tabID] = task
	delete(tm.candidates, tabID)

	// Save to database
	_ = tm.db.InsertTask(task)

	// Emit task_started event
	_ = tm.ipc.NotifyTaskStarted(task)

	return task, nil
}

// dismissCandidateLocked dismisses a pending candidate (must hold lock)
func (tm *TaskManager) dismissCandidateLocked(tabID, candidateID, method string) int {
	candidate := tm.candidates[tabID]
	if candidate == nil || (candidateID != "" && candidate.ID != candidateID) {
		return 0
	}

	// Reassign pending calls to previous task (or leave task-less)
	reassigned := len(candidate.PendingCallIDs)
	if prevTask := tm.tasks[tabID]; prevTask != nil && prevTask.State == TaskStateActive {
		for _, callID := range candidate.PendingCallIDs {
			_ = tm.db.UpdateCallTaskID(callID, prevTask.ID)
		}
	}

	// Emit dismissed event
	_ = tm.ipc.NotifyTaskCandidateDismissed(candidate, method)

	delete(tm.candidates, tabID)
	return reassigned
}

// DismissCandidate dismisses a pending candidate by ID
func (tm *TaskManager) DismissCandidate(tabID, candidateID, method string) (bool, int) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	// Check if candidate exists before dismissing
	candidate := tm.candidates[tabID]
	if candidate == nil || (candidateID != "" && candidate.ID != candidateID) {
		return false, 0
	}

	reassigned := tm.dismissCandidateLocked(tabID, candidateID, method)
	return true, reassigned
}

// AssessTask records the outcome of a task
func (tm *TaskManager) AssessTask(taskID string, approved bool, note string) error {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	// Find task by ID across all tabs
	var task *Task
	for _, t := range tm.tasks {
		if t.ID == taskID {
			task = t
			break
		}
	}

	if task == nil {
		return ErrTaskNotFound
	}

	now := time.Now()
	task.State = TaskStateCompleted
	task.CompletedAt = &now

	// Get task metrics from database
	metrics, _ := tm.db.GetTaskMetrics(taskID)
	if metrics != nil {
		task.TotalAPICalls = metrics.TotalCalls
		task.TotalTokens = metrics.TotalTokens
		task.TotalCostUSD = metrics.TotalCost
	}

	// Save assessment
	assessment := &TaskAssessment{
		TaskID:          taskID,
		Approved:        approved,
		Note:            note,
		TotalAPICalls:   task.TotalAPICalls,
		TotalTokens:     task.TotalTokens,
		TotalCostUSD:    task.TotalCostUSD,
		DurationSeconds: int64(now.Sub(task.StartedAt).Seconds()),
		AssessedAt:      now,
	}

	// v1.2: Get baseline metrics and save with assessment
	baselineMetrics, _ := tm.db.GetTaskBaselineMetrics(taskID)
	_ = tm.db.InsertTaskAssessmentWithBaseline(assessment, baselineMetrics)
	_ = tm.db.UpdateTask(task)

	// Emit assessment event via IPC
	_ = tm.ipc.NotifyTaskAssessmentWithBaseline(task, assessment, baselineMetrics)

	// v1.2: Forward to Mockup analytics
	if tm.mockup != nil && baselineMetrics != nil {
		// Convert TaskBaselineMetrics to BaselineEstimate for Mockup
		baseline := &BaselineEstimate{
			TotalTokens: baselineMetrics.BaselineTotalTokens,
			TokensSaved: baselineMetrics.TokensSaved,
			Method:      BaselineMethodHistoricalAvg, // aggregated from multiple calls
		}
		// Construct correlation headers from task
		headers := &CorrelationHeaders{
			SessionID: task.SessionID,
			TabID:     task.TabID,
			Project:   task.ProjectPath,
		}
		_ = tm.mockup.SendTaskAssessmentEvent(assessment, task, baseline, headers)
	}

	return nil
}

// GetCurrentTask returns the current task for a tab
func (tm *TaskManager) GetCurrentTask(tabID string) *Task {
	tm.mu.RLock()
	defer tm.mu.RUnlock()

	task := tm.tasks[tabID]
	if task != nil && task.State == TaskStateActive {
		// Update metrics
		metrics, _ := tm.db.GetTaskMetrics(task.ID)
		if metrics != nil {
			task.TotalAPICalls = metrics.TotalCalls
			task.TotalTokens = metrics.TotalTokens
			task.TotalCostUSD = metrics.TotalCost
		}
	}
	return task
}

// GetCandidate returns any pending candidate for a tab
func (tm *TaskManager) GetCandidate(tabID string) *TaskCandidate {
	tm.mu.RLock()
	defer tm.mu.RUnlock()

	return tm.candidates[tabID]
}

// StartTask starts a new task immediately (manual start)
func (tm *TaskManager) StartTask(tabID, taskName string, candidateID string) (*Task, error) {
	// If candidateID is provided, confirm that candidate
	if candidateID != "" {
		return tm.confirmCandidate(tabID, candidateID, StartMethodUserConfirmed)
	}

	tm.mu.Lock()
	defer tm.mu.Unlock()

	headers := &CorrelationHeaders{
		TabID:    tabID,
		TaskName: taskName,
	}

	// Get session from existing task or use default
	if existingTask := tm.tasks[tabID]; existingTask != nil {
		headers.SessionID = existingTask.SessionID
		headers.Project = existingTask.ProjectPath
	}

	task := tm.createTaskLocked(tabID, headers, TriggerManual, StartMethodManual, taskName)
	return task, nil
}

// UpdateTaskName updates the name of a task
func (tm *TaskManager) UpdateTaskName(taskID, newName string) error {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	for _, task := range tm.tasks {
		if task.ID == taskID {
			task.Name = newName
			return tm.db.UpdateTask(task)
		}
	}
	return ErrTaskNotFound
}

// runGracePeriodChecker periodically checks for candidates that should be auto-confirmed
func (tm *TaskManager) runGracePeriodChecker() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for range ticker.C {
		tm.checkGracePeriods()
	}
}

// checkGracePeriods auto-confirms candidates whose grace period has expired
func (tm *TaskManager) checkGracePeriods() {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	now := time.Now()
	for tabID, candidate := range tm.candidates {
		if now.After(candidate.GracePeriodEnd) {
			// Auto-confirm the candidate
			task := &Task{
				ID:          generateID("task"),
				CandidateID: candidate.ID,
				TabID:       tabID,
				SessionID:   candidate.SessionID,
				ProjectPath: candidate.ProjectPath,
				Name:        candidate.SuggestedName,
				State:       TaskStateActive,
				StartMethod: StartMethodAutoConfirmed,
				Trigger:     candidate.Trigger,
				StartedAt:   now,
			}

			// Update pending calls
			for _, callID := range candidate.PendingCallIDs {
				_ = tm.db.UpdateCallTaskID(callID, task.ID)
			}

			// Complete existing task
			if existingTask := tm.tasks[tabID]; existingTask != nil && existingTask.State == TaskStateActive {
				existingTask.State = TaskStateAbandoned
				existingTask.CompletedAt = &now
				_ = tm.db.UpdateTask(existingTask)
			}

			tm.tasks[tabID] = task
			delete(tm.candidates, tabID)

			// Save and notify
			_ = tm.db.InsertTask(task)
			_ = tm.ipc.NotifyTaskStarted(task)
		}
	}
}

// AddPendingCall associates an API call with a pending candidate
func (tm *TaskManager) AddPendingCall(tabID, callID string) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	if candidate := tm.candidates[tabID]; candidate != nil {
		candidate.PendingCallIDs = append(candidate.PendingCallIDs, callID)
	}
}

// TaskAssessment records the outcome of a task
type TaskAssessment struct {
	TaskID          string    `json:"task_id"`
	Approved        bool      `json:"approved"`
	Note            string    `json:"note,omitempty"`
	TotalAPICalls   int       `json:"total_api_calls"`
	TotalTokens     int       `json:"total_tokens"`
	TotalCostUSD    float64   `json:"total_cost_usd"`
	DurationSeconds int64     `json:"duration_seconds"`
	AssessedAt      time.Time `json:"assessed_at"`
}

// TaskMetrics contains aggregated metrics for a task
type TaskMetrics struct {
	TotalCalls  int
	TotalTokens int
	TotalCost   float64
}

// Helper functions

// generateID creates a unique ID with a prefix
func generateID(prefix string) string {
	bytes := make([]byte, 8)
	rand.Read(bytes)
	return prefix + "_" + hex.EncodeToString(bytes)
}

// deriveTaskName extracts a task name from prompt content
func deriveTaskName(promptPreview, override string) string {
	if override != "" {
		return override
	}

	if promptPreview == "" {
		return "Task " + time.Now().Format("2006-01-02 15:04")
	}

	// Try to extract a verb phrase or first meaningful words
	name := extractVerbPhrase(promptPreview)
	if name != "" {
		return name
	}

	// Fall back to first N words
	words := strings.Fields(promptPreview)
	if len(words) > 8 {
		words = words[:8]
	}
	name = strings.Join(words, " ")
	if len(name) > 60 {
		name = name[:57] + "..."
	}
	return name
}

// extractVerbPhrase tries to find a verb phrase at the start of the prompt
func extractVerbPhrase(prompt string) string {
	// Common task verbs
	verbPatterns := []string{
		`^(fix|add|create|implement|update|refactor|remove|delete|debug|test|write|build|deploy|configure|setup|install|migrate|convert|optimize|improve|review|analyze|check|verify)`,
	}

	prompt = strings.TrimSpace(strings.ToLower(prompt))

	for _, pattern := range verbPatterns {
		re := regexp.MustCompile(pattern + `\s+[\w\s]{2,50}`)
		match := re.FindString(prompt)
		if match != "" {
			// Capitalize first letter
			match = strings.TrimSpace(match)
			runes := []rune(match)
			runes[0] = unicode.ToUpper(runes[0])
			return string(runes)
		}
	}

	return ""
}

// calculateConfidence returns a confidence score for a trigger
func calculateConfidence(trigger TaskTrigger) float64 {
	switch trigger {
	case TriggerManual:
		return 1.0
	case TriggerNewSession:
		return 0.9
	case TriggerIdleGap:
		return 0.85
	case TriggerRepoSwitch:
		return 0.8
	default:
		return 0.5
	}
}

// Errors
var (
	ErrNoCandidateFound = &TaskError{Message: "no pending candidate found"}
	ErrTaskNotFound     = &TaskError{Message: "task not found"}
)

type TaskError struct {
	Message string
}

func (e *TaskError) Error() string {
	return e.Message
}

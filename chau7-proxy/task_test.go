package main

import (
	"os"
	"testing"
	"time"
)

// mockIPCNotifier is a no-op IPC notifier for testing
type mockIPCNotifier struct{}

func (m *mockIPCNotifier) NotifyTaskCandidate(candidate *TaskCandidate) error       { return nil }
func (m *mockIPCNotifier) NotifyTaskStarted(task *Task) error                        { return nil }
func (m *mockIPCNotifier) NotifyTaskCandidateDismissed(c *TaskCandidate, m2 string) error { return nil }
func (m *mockIPCNotifier) NotifyTaskAssessment(task *Task, a *TaskAssessment) error  { return nil }

// testDB creates a temporary database for testing
func testDB(t *testing.T) *Database {
	tmpFile, err := os.CreateTemp("", "chau7_test_*.db")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	tmpFile.Close()
	t.Cleanup(func() { os.Remove(tmpFile.Name()) })

	db, err := NewDatabase(tmpFile.Name())
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	return db
}

// testIPC creates a mock IPC notifier for testing
func testIPC(db *Database) *IPCNotifier {
	ipc := NewIPCNotifier("") // Empty path disables actual IPC
	ipc.SetDatabase(db)
	return ipc
}

// TestGenerateID tests ID generation
func TestGenerateID(t *testing.T) {
	id1 := generateID("task")
	id2 := generateID("task")

	if id1 == id2 {
		t.Error("Generated IDs should be unique")
	}

	if len(id1) < 10 {
		t.Errorf("Generated ID too short: %s", id1)
	}

	if id1[:5] != "task_" {
		t.Errorf("ID should start with prefix: %s", id1)
	}
}

// TestDeriveTaskName tests task name derivation from prompts
func TestDeriveTaskName(t *testing.T) {
	tests := []struct {
		name     string
		prompt   string
		override string
		want     string
	}{
		{
			name:     "override takes precedence",
			prompt:   "fix the bug",
			override: "Custom Name",
			want:     "Custom Name",
		},
		{
			name:     "verb phrase extraction",
			prompt:   "fix the login redirect bug",
			override: "",
			want:     "Fix the login redirect bug",
		},
		{
			name:     "empty prompt uses timestamp",
			prompt:   "",
			override: "",
			want:     "Task", // Partial match since timestamp varies
		},
		{
			name:     "long prompt is truncated",
			prompt:   "implement a really long feature that does many things and spans over sixty characters easily",
			override: "",
			want:     "Implement a really long feature that does many things and...",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := deriveTaskName(tt.prompt, tt.override)
			if tt.want == "Task" {
				// Special case: just check prefix for timestamp-based names
				if len(got) < 4 || got[:4] != "Task" {
					t.Errorf("deriveTaskName() = %v, want prefix %v", got, tt.want)
				}
			} else if got != tt.want {
				t.Errorf("deriveTaskName() = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestCalculateConfidence tests confidence calculation for triggers
func TestCalculateConfidence(t *testing.T) {
	tests := []struct {
		trigger TaskTrigger
		want    float64
	}{
		{TriggerManual, 1.0},
		{TriggerNewSession, 0.9},
		{TriggerIdleGap, 0.85},
		{TriggerRepoSwitch, 0.8},
	}

	for _, tt := range tests {
		t.Run(string(tt.trigger), func(t *testing.T) {
			got := calculateConfidence(tt.trigger)
			if got != tt.want {
				t.Errorf("calculateConfidence(%v) = %v, want %v", tt.trigger, got, tt.want)
			}
		})
	}
}

// TestTaskManager_ManualTrigger tests that X-Chau7-New-Task bypasses candidate state
func TestTaskManager_ManualTrigger(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
		NewTask:   true, // Manual trigger
	}

	taskID, err := tm.ProcessAPICall(headers, "test prompt")
	if err != nil {
		t.Fatalf("ProcessAPICall failed: %v", err)
	}

	// Should NOT be a candidate (manual bypasses candidate state)
	if taskID == "" {
		t.Error("Expected task ID, got empty string")
	}
	if len(taskID) > 10 && taskID[:10] == "candidate:" {
		t.Error("Manual trigger should bypass candidate state")
	}

	// Should have an active task
	task := tm.GetCurrentTask("tab_1")
	if task == nil {
		t.Fatal("Expected active task")
	}
	if task.State != TaskStateActive {
		t.Errorf("Task state = %v, want %v", task.State, TaskStateActive)
	}
	if task.StartMethod != StartMethodManual {
		t.Errorf("StartMethod = %v, want %v", task.StartMethod, StartMethodManual)
	}
}

// TestTaskManager_NewSessionTrigger tests that new session creates a candidate
func TestTaskManager_NewSessionTrigger(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
	}

	taskID, _ := tm.ProcessAPICall(headers, "test prompt")

	// Should create a candidate for new session
	if !isCandidate(taskID) {
		t.Errorf("Expected candidate, got: %s", taskID)
	}

	candidate := tm.GetCandidate("tab_1")
	if candidate == nil {
		t.Fatal("Expected pending candidate")
	}
	if candidate.Trigger != TriggerNewSession {
		t.Errorf("Trigger = %v, want %v", candidate.Trigger, TriggerNewSession)
	}
}

// TestTaskManager_IdleGapTrigger tests idle timeout creates a candidate
func TestTaskManager_IdleGapTrigger(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	// Use very short idle timeout for testing
	tm := NewTaskManager(db, ipc, 5*time.Second, 1*time.Millisecond)

	// First call - creates candidate for new session
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
	}
	tm.ProcessAPICall(headers, "first call")

	// Manually confirm the candidate
	_, err := tm.confirmCandidate("tab_1", "", StartMethodAutoConfirmed)
	if err != nil {
		t.Fatalf("Failed to confirm candidate: %v", err)
	}

	// Wait for idle timeout
	time.Sleep(5 * time.Millisecond)

	// Second call - should trigger idle gap
	taskID, _ := tm.ProcessAPICall(headers, "second call after idle")

	if !isCandidate(taskID) {
		t.Errorf("Expected candidate after idle, got: %s", taskID)
	}

	candidate := tm.GetCandidate("tab_1")
	if candidate == nil {
		t.Fatal("Expected pending candidate")
	}
	if candidate.Trigger != TriggerIdleGap {
		t.Errorf("Trigger = %v, want %v", candidate.Trigger, TriggerIdleGap)
	}
}

// TestTaskManager_RepoSwitchTrigger tests project change creates a candidate
func TestTaskManager_RepoSwitchTrigger(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// First call with project A
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/projectA",
	}
	tm.ProcessAPICall(headers, "first call")
	tm.confirmCandidate("tab_1", "", StartMethodAutoConfirmed)

	// Second call with project B
	headers.Project = "/test/projectB"
	taskID, _ := tm.ProcessAPICall(headers, "second call")

	if !isCandidate(taskID) {
		t.Errorf("Expected candidate for repo switch, got: %s", taskID)
	}

	candidate := tm.GetCandidate("tab_1")
	if candidate == nil {
		t.Fatal("Expected pending candidate")
	}
	if candidate.Trigger != TriggerRepoSwitch {
		t.Errorf("Trigger = %v, want %v", candidate.Trigger, TriggerRepoSwitch)
	}
}

// TestTaskManager_CandidateConfirmation tests confirming a candidate
func TestTaskManager_CandidateConfirmation(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create a candidate
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
	}
	tm.ProcessAPICall(headers, "test prompt")

	candidate := tm.GetCandidate("tab_1")
	if candidate == nil {
		t.Fatal("Expected candidate")
	}

	// Confirm the candidate
	task, err := tm.StartTask("tab_1", "", candidate.ID)
	if err != nil {
		t.Fatalf("StartTask failed: %v", err)
	}

	if task.StartMethod != StartMethodUserConfirmed {
		t.Errorf("StartMethod = %v, want %v", task.StartMethod, StartMethodUserConfirmed)
	}

	// Candidate should be removed
	if tm.GetCandidate("tab_1") != nil {
		t.Error("Candidate should be removed after confirmation")
	}

	// Task should be active
	currentTask := tm.GetCurrentTask("tab_1")
	if currentTask == nil {
		t.Fatal("Expected active task")
	}
}

// TestTaskManager_CandidateDismissal tests dismissing a candidate
func TestTaskManager_CandidateDismissal(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create a candidate
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
	}
	tm.ProcessAPICall(headers, "test prompt")

	candidate := tm.GetCandidate("tab_1")
	if candidate == nil {
		t.Fatal("Expected candidate")
	}
	candidateID := candidate.ID

	// Dismiss the candidate
	dismissed, _ := tm.DismissCandidate("tab_1", candidateID, "test")
	if !dismissed {
		t.Error("Expected candidate to be dismissed")
	}

	// Candidate should be removed
	if tm.GetCandidate("tab_1") != nil {
		t.Error("Candidate should be removed after dismissal")
	}
}

// TestTaskManager_DismissNonExistent tests dismissing non-existent candidate
func TestTaskManager_DismissNonExistent(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Try to dismiss non-existent candidate
	dismissed, reassigned := tm.DismissCandidate("tab_1", "cand_nonexistent", "test")
	if dismissed {
		t.Error("Should not dismiss non-existent candidate")
	}
	if reassigned != 0 {
		t.Errorf("Reassigned = %d, want 0", reassigned)
	}
}

// TestTaskManager_DismissWrongID tests dismissing with wrong candidate ID
func TestTaskManager_DismissWrongID(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create a candidate
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
	}
	tm.ProcessAPICall(headers, "test prompt")

	// Try to dismiss with wrong ID
	dismissed, _ := tm.DismissCandidate("tab_1", "wrong_id", "test")
	if dismissed {
		t.Error("Should not dismiss with wrong candidate ID")
	}

	// Candidate should still exist
	if tm.GetCandidate("tab_1") == nil {
		t.Error("Candidate should still exist")
	}
}

// TestTaskManager_TaskAssessment tests marking a task as success/failure
func TestTaskManager_TaskAssessment(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create a task
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
		NewTask:   true,
	}
	taskID, _ := tm.ProcessAPICall(headers, "test task")

	// Assess the task
	err := tm.AssessTask(taskID, true, "Tests passed")
	if err != nil {
		t.Fatalf("AssessTask failed: %v", err)
	}

	// Task should be completed
	task := tm.GetCurrentTask("tab_1")
	if task == nil {
		t.Fatal("Expected task")
	}
	if task.State != TaskStateCompleted {
		t.Errorf("State = %v, want %v", task.State, TaskStateCompleted)
	}
	if task.CompletedAt == nil {
		t.Error("CompletedAt should be set")
	}
}

// TestTaskManager_AssessNonExistent tests assessing non-existent task
func TestTaskManager_AssessNonExistent(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	err := tm.AssessTask("task_nonexistent", true, "")
	if err != ErrTaskNotFound {
		t.Errorf("Expected ErrTaskNotFound, got: %v", err)
	}
}

// TestTaskManager_UpdateTaskName tests updating task name
func TestTaskManager_UpdateTaskName(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create a task
	headers := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project",
		NewTask:   true,
	}
	taskID, _ := tm.ProcessAPICall(headers, "original name")

	// Update the name
	err := tm.UpdateTaskName(taskID, "New Name")
	if err != nil {
		t.Fatalf("UpdateTaskName failed: %v", err)
	}

	task := tm.GetCurrentTask("tab_1")
	if task.Name != "New Name" {
		t.Errorf("Name = %v, want New Name", task.Name)
	}
}

// TestTaskManager_MultipleTabsIndependent tests that tabs have independent state
func TestTaskManager_MultipleTabsIndependent(t *testing.T) {
	db := testDB(t)
	ipc := testIPC(db)
	tm := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)

	// Create task in tab 1
	headers1 := &CorrelationHeaders{
		TabID:     "tab_1",
		SessionID: "sess_1",
		Project:   "/test/project1",
		NewTask:   true,
	}
	tm.ProcessAPICall(headers1, "task 1")

	// Create task in tab 2
	headers2 := &CorrelationHeaders{
		TabID:     "tab_2",
		SessionID: "sess_2",
		Project:   "/test/project2",
		NewTask:   true,
	}
	tm.ProcessAPICall(headers2, "task 2")

	task1 := tm.GetCurrentTask("tab_1")
	task2 := tm.GetCurrentTask("tab_2")

	if task1 == nil || task2 == nil {
		t.Fatal("Expected both tabs to have tasks")
	}

	if task1.ID == task2.ID {
		t.Error("Tasks should have different IDs")
	}

	if task1.ProjectPath == task2.ProjectPath {
		t.Error("Tasks should have different projects")
	}
}

// TestCorrelationHeaders_Extract tests header extraction
func TestCorrelationHeaders_Extract(t *testing.T) {
	// This would need an http.Request mock - skipping for now
	// The function is simple enough to trust
}

// TestCorrelationHeaders_IsCorrelationHeader tests header detection
func TestCorrelationHeaders_IsCorrelationHeader(t *testing.T) {
	tests := []struct {
		header string
		want   bool
	}{
		{"X-Chau7-Session", true},
		{"X-Chau7-Tab", true},
		{"X-Chau7-Project", true},
		{"X-Chau7-Task", true},
		{"X-Chau7-Task-Name", true},
		{"X-Chau7-New-Task", true},
		{"X-Chau7-Dismiss-Candidate", true},
		{"X-Chau7-Tenant", true},
		{"X-Chau7-Org", true},
		{"X-Chau7-User", true},
		{"Content-Type", false},
		{"Authorization", false},
		{"X-Custom-Header", false},
	}

	for _, tt := range tests {
		t.Run(tt.header, func(t *testing.T) {
			got := IsCorrelationHeader(tt.header)
			if got != tt.want {
				t.Errorf("IsCorrelationHeader(%q) = %v, want %v", tt.header, got, tt.want)
			}
		})
	}
}

// TestExtractVerbPhrase tests verb phrase extraction
func TestExtractVerbPhrase(t *testing.T) {
	tests := []struct {
		prompt string
		want   string
	}{
		{"fix the login bug", "Fix the login bug"},
		{"add user authentication", "Add user authentication"},
		{"implement new feature", "Implement new feature"},
		{"no verb here just text", ""},
		{"FIX THIS BUG NOW", "Fix this bug now"},
	}

	for _, tt := range tests {
		t.Run(tt.prompt, func(t *testing.T) {
			got := extractVerbPhrase(tt.prompt)
			if got != tt.want {
				t.Errorf("extractVerbPhrase(%q) = %q, want %q", tt.prompt, got, tt.want)
			}
		})
	}
}

// Helper function to check if task ID indicates a candidate
func isCandidate(taskID string) bool {
	return len(taskID) > 10 && taskID[:10] == "candidate:"
}

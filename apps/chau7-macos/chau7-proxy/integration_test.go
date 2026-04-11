package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

// saveAndRestoreProviderConfigs saves the current provider configs and returns a restore function
func saveAndRestoreProviderConfigs(t *testing.T) func() {
	original := make(map[Provider]ProviderConfig)
	for k, v := range ProviderConfigs {
		original[k] = v
	}
	return func() {
		ProviderConfigs = original
	}
}

// TestIntegration_FullTaskLifecycle tests the complete flow:
// 1. API call through proxy creates task candidate
// 2. Candidate can be confirmed to start a task
// 3. Task can be assessed
// 4. All data is persisted to database
func TestIntegration_FullTaskLifecycle(t *testing.T) {
	// Setup test environment
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "integration_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Create mock upstream Anthropic server
	mockAnthropic := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify correlation headers are stripped before forwarding
		if r.Header.Get("X-Chau7-Tab") != "" {
			t.Error("Correlation headers should be stripped before forwarding")
		}

		// Return mock response
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    "msg_123",
			"type":  "message",
			"model": "claude-sonnet-4-20250514",
			"usage": map[string]int{
				"input_tokens":  100,
				"output_tokens": 250,
			},
			"content": []map[string]string{
				{"type": "text", "text": "Hello! I can help with that."},
			},
			"stop_reason": "end_turn",
		})
	}))
	defer mockAnthropic.Close()

	// Override provider config to use mock server
	restore := saveAndRestoreProviderConfigs(t)
	defer restore()
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL:     mockAnthropic.URL,
		ContentType: "application/json",
	}

	config := &Config{
		Port:     0, // Not used in test
		DBPath:   dbPath,
		LogLevel: "debug",
	}

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil)
	mockup, err := NewMockupClient("", "")
	if err != nil {
		t.Fatalf("Failed to create mockup client: %v", err)
	}
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, mockup)
	taskEndpoints := NewTaskEndpoints(taskManager, db)

	// === Step 1: Make API call with correlation headers ===
	t.Run("Step1_APICallCreatesCandidate", func(t *testing.T) {
		reqBody := map[string]interface{}{
			"model":      "claude-sonnet-4-20250514",
			"max_tokens": 1024,
			"messages": []map[string]string{
				{"role": "user", "content": "Fix the login redirect bug in auth.go"},
			},
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer sk-test-key")
		req.Header.Set("X-Chau7-Tab", "tab_integration_test")
		req.Header.Set("X-Chau7-Project", "/test/project")
		req.Header.Set("anthropic-version", "2023-06-01")

		rr := httptest.NewRecorder()
		proxy.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("API call failed: %d - %s", rr.Code, rr.Body.String())
		}

		// Verify candidate was created
		candidate := taskManager.GetCandidate("tab_integration_test")
		if candidate == nil {
			t.Fatal("Expected candidate to be created")
		}
		if candidate.SuggestedName == "" {
			t.Error("Candidate should have a suggested name")
		}
		t.Logf("Candidate created: %s - %s", candidate.ID, candidate.SuggestedName)
	})

	// === Step 2: Confirm candidate to start task ===
	var taskID string
	t.Run("Step2_ConfirmCandidateStartsTask", func(t *testing.T) {
		candidate := taskManager.GetCandidate("tab_integration_test")
		if candidate == nil {
			t.Skip("No candidate available")
		}

		reqBody := StartTaskRequest{
			TabID:       "tab_integration_test",
			CandidateID: candidate.ID,
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/task/start", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		taskEndpoints.HandleStartTask(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("Start task failed: %d - %s", rr.Code, rr.Body.String())
		}

		var resp StartTaskResponse
		_ = json.NewDecoder(rr.Body).Decode(&resp)
		taskID = resp.TaskID
		t.Logf("Task started: %s - %s", resp.TaskID, resp.TaskName)

		// Verify task is now active
		task := taskManager.GetCurrentTask("tab_integration_test")
		if task == nil {
			t.Fatal("Expected active task")
		}
		if task.State != TaskStateActive {
			t.Errorf("Task state = %v, want active", task.State)
		}
	})

	// === Step 3: Make another API call that gets assigned to the task ===
	t.Run("Step3_SubsequentCallsAssignedToTask", func(t *testing.T) {
		reqBody := map[string]interface{}{
			"model":      "claude-sonnet-4-20250514",
			"max_tokens": 1024,
			"messages": []map[string]string{
				{"role": "user", "content": "Now add unit tests for the fix"},
			},
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer sk-test-key")
		req.Header.Set("X-Chau7-Tab", "tab_integration_test")
		req.Header.Set("X-Chau7-Project", "/test/project")
		req.Header.Set("anthropic-version", "2023-06-01")

		rr := httptest.NewRecorder()
		proxy.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("Second API call failed: %d", rr.Code)
		}

		// Verify task metrics updated
		task := taskManager.GetCurrentTask("tab_integration_test")
		if task == nil {
			t.Fatal("Task should still be active")
		}
		if task.TotalAPICalls < 2 {
			t.Errorf("Task should have at least 2 API calls, got %d", task.TotalAPICalls)
		}
		t.Logf("Task now has %d API calls, %d tokens", task.TotalAPICalls, task.TotalTokens)
	})

	// === Step 4: Get current task via endpoint ===
	t.Run("Step4_GetCurrentTaskEndpoint", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/task/current?tab_id=tab_integration_test", nil)
		rr := httptest.NewRecorder()
		taskEndpoints.HandleGetCurrentTask(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("Get current task failed: %d", rr.Code)
		}

		var resp CurrentTaskResponse
		_ = json.NewDecoder(rr.Body).Decode(&resp)
		if !resp.HasTask {
			t.Fatal("Expected has_task=true")
		}
		if resp.TaskID != taskID {
			t.Errorf("Task ID mismatch: %s vs %s", resp.TaskID, taskID)
		}
		t.Logf("Current task: %s, calls=%d, tokens=%d, cost=$%.4f",
			resp.TaskName, resp.TotalCalls, resp.TotalTokens, resp.TotalCostUSD)
	})

	// === Step 5: Assess the task ===
	t.Run("Step5_AssessTask", func(t *testing.T) {
		reqBody := AssessRequest{
			TaskID:   taskID,
			Approved: true,
			Note:     "Great work on the fix!",
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/task/assess", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		taskEndpoints.HandleAssessTask(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("Assess task failed: %d - %s", rr.Code, rr.Body.String())
		}

		var resp AssessResponse
		_ = json.NewDecoder(rr.Body).Decode(&resp)
		if !resp.Success {
			t.Error("Expected success=true")
		}
		t.Logf("Task assessed, tokens saved: %d", resp.TokensSaved)
	})

	// === Step 6: Verify task is completed ===
	t.Run("Step6_TaskIsCompleted", func(t *testing.T) {
		// After assessment, there should be no active task
		req := httptest.NewRequest("GET", "/task/current?tab_id=tab_integration_test", nil)
		rr := httptest.NewRecorder()
		taskEndpoints.HandleGetCurrentTask(rr, req)

		var resp CurrentTaskResponse
		_ = json.NewDecoder(rr.Body).Decode(&resp)
		if resp.HasTask {
			t.Error("Expected no active task after assessment")
		}
	})

	// === Step 7: Verify database persistence ===
	t.Run("Step7_DatabasePersistence", func(t *testing.T) {
		// Check API calls were recorded
		calls, err := db.GetRecentCalls(10)
		if err != nil {
			t.Fatalf("Failed to get recent calls: %v", err)
		}
		if len(calls) < 2 {
			t.Errorf("Expected at least 2 API calls in DB, got %d", len(calls))
		}

		// Check events were recorded (optional - depends on IPC setup)
		events, total, err := db.GetEvents(10, 0)
		if err != nil {
			t.Fatalf("Failed to get events: %v", err)
		}
		t.Logf("Database has %d events (events are stored via IPC, may require full setup)", total)
		for _, e := range events {
			t.Logf("  - %s: %s", e.Type, e.Timestamp)
		}
	})
}

// TestIntegration_ManualTaskTrigger tests X-Chau7-New-Task header
func TestIntegration_ManualTaskTrigger(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "manual_trigger_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	mockAnthropic := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    "msg_456",
			"type":  "message",
			"model": "claude-sonnet-4-20250514",
			"usage": map[string]int{"input_tokens": 50, "output_tokens": 100},
			"content": []map[string]string{
				{"type": "text", "text": "Done!"},
			},
			"stop_reason": "end_turn",
		})
	}))
	defer mockAnthropic.Close()

	restore := saveAndRestoreProviderConfigs(t)
	defer restore()
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL:     mockAnthropic.URL,
		ContentType: "application/json",
	}

	config := &Config{
		Port:     0,
		DBPath:   dbPath,
		LogLevel: "debug",
	}

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil)
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, nil)

	// Make API call with X-Chau7-New-Task header
	reqBody := map[string]interface{}{
		"model":      "claude-sonnet-4-20250514",
		"max_tokens": 512,
		"messages": []map[string]string{
			{"role": "user", "content": "Create a new feature"},
		},
	}
	body, _ := json.Marshal(reqBody)

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sk-test-key")
	req.Header.Set("X-Chau7-Tab", "tab_manual")
	req.Header.Set("X-Chau7-Project", "/test/project")
	req.Header.Set("X-Chau7-New-Task", "true") // Force new task immediately
	req.Header.Set("anthropic-version", "2023-06-01")

	rr := httptest.NewRecorder()
	proxy.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("API call failed: %d", rr.Code)
	}

	// With X-Chau7-New-Task, task should be immediately active (no candidate)
	task := taskManager.GetCurrentTask("tab_manual")
	if task == nil {
		t.Fatal("Expected immediate task creation with X-Chau7-New-Task")
	}
	if task.StartMethod != StartMethodManual {
		t.Errorf("StartMethod = %v, want manual", task.StartMethod)
	}
	if task.State != TaskStateActive {
		t.Errorf("Task state = %v, want active", task.State)
	}
	t.Logf("Manual task created: %s - %s", task.ID, task.Name)
}

// TestIntegration_CandidateDismissal tests dismissing a candidate
func TestIntegration_CandidateDismissal(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "dismiss_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	mockAnthropic := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    "msg_789",
			"type":  "message",
			"model": "claude-sonnet-4-20250514",
			"usage": map[string]int{"input_tokens": 30, "output_tokens": 80},
			"content": []map[string]string{
				{"type": "text", "text": "Sure thing!"},
			},
			"stop_reason": "end_turn",
		})
	}))
	defer mockAnthropic.Close()

	restore := saveAndRestoreProviderConfigs(t)
	defer restore()
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL:     mockAnthropic.URL,
		ContentType: "application/json",
	}

	config := &Config{
		Port:     0,
		DBPath:   dbPath,
		LogLevel: "debug",
	}

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil)
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, nil)
	taskEndpoints := NewTaskEndpoints(taskManager, db)

	// Step 1: Create candidate via API call
	reqBody := map[string]interface{}{
		"model":      "claude-sonnet-4-20250514",
		"max_tokens": 256,
		"messages": []map[string]string{
			{"role": "user", "content": "Quick question about Go"},
		},
	}
	body, _ := json.Marshal(reqBody)

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sk-test-key")
	req.Header.Set("X-Chau7-Tab", "tab_dismiss")
	req.Header.Set("X-Chau7-Project", "/test/project")
	req.Header.Set("anthropic-version", "2023-06-01")

	rr := httptest.NewRecorder()
	proxy.ServeHTTP(rr, req)

	candidate := taskManager.GetCandidate("tab_dismiss")
	if candidate == nil {
		t.Fatal("Expected candidate to be created")
	}

	// Step 2: Dismiss the candidate
	dismissReq := DismissRequest{
		TabID:       "tab_dismiss",
		CandidateID: candidate.ID,
	}
	body, _ = json.Marshal(dismissReq)

	req = httptest.NewRequest("POST", "/task/dismiss", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr = httptest.NewRecorder()
	taskEndpoints.HandleDismissCandidate(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("Dismiss failed: %d", rr.Code)
	}

	var resp DismissResponse
	_ = json.NewDecoder(rr.Body).Decode(&resp)
	if !resp.Dismissed {
		t.Error("Expected dismissed=true")
	}

	// Step 3: Verify candidate is gone
	candidate = taskManager.GetCandidate("tab_dismiss")
	if candidate != nil {
		t.Error("Candidate should be dismissed")
	}

	// Step 4: Verify no active task
	task := taskManager.GetCurrentTask("tab_dismiss")
	if task != nil && task.State == TaskStateActive {
		t.Error("Should not have an active task after dismiss")
	}

	t.Logf("Candidate dismissed, reassigned calls: %d", resp.ReassignedCalls)
}

// TestIntegration_HeaderBasedDismiss tests X-Chau7-Dismiss-Candidate header
func TestIntegration_HeaderBasedDismiss(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "header_dismiss_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	callCount := 0
	mockAnthropic := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    fmt.Sprintf("msg_%d", callCount),
			"type":  "message",
			"model": "claude-sonnet-4-20250514",
			"usage": map[string]int{"input_tokens": 20, "output_tokens": 50},
			"content": []map[string]string{
				{"type": "text", "text": "Response"},
			},
			"stop_reason": "end_turn",
		})
	}))
	defer mockAnthropic.Close()

	restore := saveAndRestoreProviderConfigs(t)
	defer restore()
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL:     mockAnthropic.URL,
		ContentType: "application/json",
	}

	config := &Config{
		Port:     0,
		DBPath:   dbPath,
		LogLevel: "debug",
	}

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil)
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, nil)

	// Step 1: First call creates candidate
	reqBody := map[string]interface{}{
		"model":      "claude-sonnet-4-20250514",
		"max_tokens": 128,
		"messages": []map[string]string{
			{"role": "user", "content": "Hello"},
		},
	}
	body, _ := json.Marshal(reqBody)

	req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sk-test-key")
	req.Header.Set("X-Chau7-Tab", "tab_header_dismiss")
	req.Header.Set("X-Chau7-Project", "/test/project")
	req.Header.Set("anthropic-version", "2023-06-01")

	rr := httptest.NewRecorder()
	proxy.ServeHTTP(rr, req)

	candidate := taskManager.GetCandidate("tab_header_dismiss")
	if candidate == nil {
		t.Fatal("Expected candidate")
	}
	candidateID := candidate.ID

	// Step 2: Second call with dismiss header
	body, _ = json.Marshal(reqBody)
	req = httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sk-test-key")
	req.Header.Set("X-Chau7-Tab", "tab_header_dismiss")
	req.Header.Set("X-Chau7-Project", "/test/project")
	req.Header.Set("X-Chau7-Dismiss-Candidate", candidateID) // Dismiss via header
	req.Header.Set("anthropic-version", "2023-06-01")

	rr = httptest.NewRecorder()
	proxy.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("Second call failed: %d", rr.Code)
	}

	// Candidate should be dismissed
	candidate = taskManager.GetCandidate("tab_header_dismiss")
	if candidate != nil && candidate.ID == candidateID {
		t.Error("Candidate should have been dismissed via header")
	}

	t.Log("Header-based dismiss successful")
}

// TestIntegration_MultipleProviders tests routing to different providers
func TestIntegration_MultipleProviders(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "multi_provider_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Mock Anthropic
	mockAnthropic := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    "anthropic_msg",
			"type":  "message",
			"model": "claude-sonnet-4-20250514",
			"usage": map[string]int{"input_tokens": 100, "output_tokens": 200},
			"content": []map[string]string{
				{"type": "text", "text": "Anthropic response"},
			},
			"stop_reason": "end_turn",
		})
	}))
	defer mockAnthropic.Close()

	// Mock OpenAI
	mockOpenAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id":    "openai_msg",
			"model": "gpt-4o",
			"choices": []map[string]interface{}{
				{
					"message":       map[string]string{"role": "assistant", "content": "OpenAI response"},
					"finish_reason": "stop",
				},
			},
			"usage": map[string]int{
				"prompt_tokens":     80,
				"completion_tokens": 150,
				"total_tokens":      230,
			},
		})
	}))
	defer mockOpenAI.Close()

	restore := saveAndRestoreProviderConfigs(t)
	defer restore()
	ProviderConfigs[ProviderAnthropic] = ProviderConfig{
		BaseURL:     mockAnthropic.URL,
		ContentType: "application/json",
	}
	ProviderConfigs[ProviderOpenAI] = ProviderConfig{
		BaseURL:     mockOpenAI.URL,
		ContentType: "application/json",
	}

	config := &Config{
		Port:     0,
		DBPath:   dbPath,
		LogLevel: "debug",
	}

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	baseline := NewBaselineEstimator(db, nil)
	proxy := NewProxyHandler(config, db, ipc, taskManager, baseline, nil)

	// Test Anthropic
	t.Run("Anthropic", func(t *testing.T) {
		reqBody := map[string]interface{}{
			"model":      "claude-sonnet-4-20250514",
			"max_tokens": 512,
			"messages":   []map[string]string{{"role": "user", "content": "Hello Claude"}},
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer sk-ant-test")
		req.Header.Set("X-Chau7-Tab", "tab_anthropic")
		req.Header.Set("anthropic-version", "2023-06-01")

		rr := httptest.NewRecorder()
		proxy.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("Anthropic call failed: %d", rr.Code)
		}
	})

	// Test OpenAI
	t.Run("OpenAI", func(t *testing.T) {
		reqBody := map[string]interface{}{
			"model":    "gpt-4o",
			"messages": []map[string]string{{"role": "user", "content": "Hello GPT"}},
		}
		body, _ := json.Marshal(reqBody)

		req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer sk-openai-test")
		req.Header.Set("X-Chau7-Tab", "tab_openai")

		rr := httptest.NewRecorder()
		proxy.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("OpenAI call failed: %d - %s", rr.Code, rr.Body.String())
		}
	})

	// Verify both calls were recorded
	calls, err := db.GetRecentCalls(10)
	if err != nil {
		t.Fatalf("Failed to get calls: %v", err)
	}
	if len(calls) < 2 {
		t.Errorf("Expected at least 2 calls recorded, got %d", len(calls))
	}

	// Check providers
	providers := make(map[Provider]bool)
	for _, call := range calls {
		providers[call.Provider] = true
	}
	if !providers[ProviderAnthropic] {
		t.Error("Missing Anthropic call in DB")
	}
	if !providers[ProviderOpenAI] {
		t.Error("Missing OpenAI call in DB")
	}
}

// TestIntegration_EventsEndpoint tests the /events endpoint
func TestIntegration_EventsEndpoint(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "events_test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	taskManager := NewTaskManager(db, ipc, 5*time.Second, 30*time.Second)
	taskEndpoints := NewTaskEndpoints(taskManager, db)

	// Create some events by starting a task
	task, err := taskManager.StartTask("tab_events", "Test Events Task", "")
	if err != nil {
		t.Fatalf("Failed to start task: %v", err)
	}
	_ = task

	// Give time for events to be recorded
	time.Sleep(100 * time.Millisecond)

	// Query events endpoint
	req := httptest.NewRequest("GET", "/events?limit=10", nil)
	rr := httptest.NewRecorder()
	taskEndpoints.HandleGetEvents(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("Events endpoint failed: %d", rr.Code)
	}

	var resp EventsResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	t.Logf("Events response: total=%d, returned=%d", resp.TotalCount, len(resp.Events))
	for i, e := range resp.Events {
		t.Logf("  [%d] %s at %s", i, e.Type, e.Timestamp)
	}
}

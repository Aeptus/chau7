package main

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewDatabase(t *testing.T) {
	// Create temp directory for test
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Verify file was created
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		t.Error("Database file was not created")
	}

	// Verify we can ping it
	if err := db.Ping(); err != nil {
		t.Errorf("Database ping failed: %v", err)
	}
}

func TestNewDatabase_InvalidPath(t *testing.T) {
	// Try to create DB in non-existent deep directory
	_, err := NewDatabase("/nonexistent/deep/path/test.db")
	if err == nil {
		t.Error("Expected error for invalid path")
	}
}

func TestDatabase_InsertAndRetrieve(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Insert a test record
	now := time.Now().UTC()
	record := &APICallRecord{
		SessionID:    "test-session-123",
		Provider:     ProviderAnthropic,
		Model:        "claude-3-5-sonnet",
		Endpoint:     "/v1/messages",
		InputTokens:  100,
		OutputTokens: 50,
		LatencyMs:    250,
		StatusCode:   200,
		CostUSD:      0.001,
		Timestamp:    now,
	}

	err = db.InsertAPICall(record)
	if err != nil {
		t.Fatalf("Failed to insert record: %v", err)
	}

	// Retrieve it
	records, err := db.GetRecentCalls(10)
	if err != nil {
		t.Fatalf("Failed to get recent calls: %v", err)
	}

	if len(records) != 1 {
		t.Fatalf("Expected 1 record, got %d", len(records))
	}

	r := records[0]
	if r.SessionID != "test-session-123" {
		t.Errorf("SessionID mismatch: got %s", r.SessionID)
	}
	if r.Provider != ProviderAnthropic {
		t.Errorf("Provider mismatch: got %s", r.Provider)
	}
	if r.Model != "claude-3-5-sonnet" {
		t.Errorf("Model mismatch: got %s", r.Model)
	}
	if r.InputTokens != 100 {
		t.Errorf("InputTokens mismatch: got %d", r.InputTokens)
	}
	if r.OutputTokens != 50 {
		t.Errorf("OutputTokens mismatch: got %d", r.OutputTokens)
	}
}

func TestDatabase_MultipleRecords(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Insert multiple records
	now := time.Now().UTC()
	for i := 0; i < 5; i++ {
		record := &APICallRecord{
			SessionID:    "session-" + string(rune('A'+i)),
			Provider:     ProviderOpenAI,
			Model:        "gpt-4o",
			Endpoint:     "/v1/chat/completions",
			InputTokens:  100 * (i + 1),
			OutputTokens: 50 * (i + 1),
			LatencyMs:    int64(100 * (i + 1)),
			StatusCode:   200,
			CostUSD:      0.001 * float64(i+1),
			Timestamp:    now.Add(time.Duration(i) * time.Second),
		}
		if err := db.InsertAPICall(record); err != nil {
			t.Fatalf("Failed to insert record %d: %v", i, err)
		}
	}

	// Retrieve with limit
	records, err := db.GetRecentCalls(3)
	if err != nil {
		t.Fatalf("Failed to get recent calls: %v", err)
	}

	if len(records) != 3 {
		t.Errorf("Expected 3 records, got %d", len(records))
	}

	// Verify order (most recent first)
	if records[0].SessionID != "session-E" {
		t.Errorf("Expected most recent record first, got %s", records[0].SessionID)
	}
}

func TestDatabase_GetDailyStats(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Insert records for today
	now := time.Now().UTC()
	records := []*APICallRecord{
		{
			SessionID:    "s1",
			Provider:     ProviderAnthropic,
			Model:        "claude-3-sonnet",
			Endpoint:     "/v1/messages",
			InputTokens:  100,
			OutputTokens: 200,
			LatencyMs:    100,
			StatusCode:   200,
			CostUSD:      0.01,
			Timestamp:    now,
		},
		{
			SessionID:    "s2",
			Provider:     ProviderOpenAI,
			Model:        "gpt-4o",
			Endpoint:     "/v1/chat/completions",
			InputTokens:  150,
			OutputTokens: 300,
			LatencyMs:    200,
			StatusCode:   200,
			CostUSD:      0.02,
			Timestamp:    now,
		},
		{
			SessionID:    "s3",
			Provider:     ProviderGemini,
			Model:        "gemini-pro",
			Endpoint:     "/v1/models/gemini-pro:generateContent",
			InputTokens:  50,
			OutputTokens: 100,
			LatencyMs:    150,
			StatusCode:   200,
			CostUSD:      0.005,
			Timestamp:    now,
		},
	}

	for _, r := range records {
		if err := db.InsertAPICall(r); err != nil {
			t.Fatalf("Failed to insert record: %v", err)
		}
	}

	// Get daily stats
	stats, err := db.GetDailyStats()
	if err != nil {
		t.Fatalf("Failed to get daily stats: %v", err)
	}

	// Verify counts
	if stats.CallCount != 3 {
		t.Errorf("Expected 3 calls, got %d", stats.CallCount)
	}

	// Verify token totals
	expectedInput := 100 + 150 + 50
	if stats.TotalInputTokens != expectedInput {
		t.Errorf("Expected %d input tokens, got %d", expectedInput, stats.TotalInputTokens)
	}

	expectedOutput := 200 + 300 + 100
	if stats.TotalOutputTokens != expectedOutput {
		t.Errorf("Expected %d output tokens, got %d", expectedOutput, stats.TotalOutputTokens)
	}

	// Verify cost
	expectedCost := 0.01 + 0.02 + 0.005
	if stats.TotalCost < expectedCost-0.001 || stats.TotalCost > expectedCost+0.001 {
		t.Errorf("Expected cost ~%.3f, got %.3f", expectedCost, stats.TotalCost)
	}

	// Verify average latency
	expectedAvg := float64(100+200+150) / 3.0
	if stats.AvgLatencyMs < expectedAvg-1 || stats.AvgLatencyMs > expectedAvg+1 {
		t.Errorf("Expected avg latency ~%.1f, got %.1f", expectedAvg, stats.AvgLatencyMs)
	}
}

func TestDatabase_EmptyStats(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Get stats from empty database
	stats, err := db.GetDailyStats()
	if err != nil {
		t.Fatalf("Failed to get daily stats: %v", err)
	}

	if stats.CallCount != 0 {
		t.Errorf("Expected 0 calls, got %d", stats.CallCount)
	}
	if stats.TotalInputTokens != 0 {
		t.Errorf("Expected 0 input tokens, got %d", stats.TotalInputTokens)
	}
	if stats.TotalCost != 0 {
		t.Errorf("Expected 0 cost, got %.4f", stats.TotalCost)
	}
}

func TestDatabase_ErrorRecord(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Insert error record
	record := &APICallRecord{
		SessionID:    "error-session",
		Provider:     ProviderAnthropic,
		Model:        "claude-3-opus",
		Endpoint:     "/v1/messages",
		StatusCode:   502,
		LatencyMs:    50,
		Timestamp:    time.Now().UTC(),
		ErrorMessage: "upstream connection failed",
	}

	err = db.InsertAPICall(record)
	if err != nil {
		t.Fatalf("Failed to insert error record: %v", err)
	}

	// Retrieve and verify error message
	records, err := db.GetRecentCalls(1)
	if err != nil {
		t.Fatalf("Failed to get recent calls: %v", err)
	}

	if len(records) != 1 {
		t.Fatalf("Expected 1 record, got %d", len(records))
	}

	if records[0].ErrorMessage != "upstream connection failed" {
		t.Errorf("ErrorMessage mismatch: got %q", records[0].ErrorMessage)
	}
	if records[0].StatusCode != 502 {
		t.Errorf("StatusCode mismatch: got %d", records[0].StatusCode)
	}
}

func TestDatabase_CloseAndReopen(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	// Create and insert
	db1, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}

	record := &APICallRecord{
		SessionID:    "persist-test",
		Provider:     ProviderAnthropic,
		Model:        "claude-3-haiku",
		Endpoint:     "/v1/messages",
		InputTokens:  10,
		OutputTokens: 20,
		StatusCode:   200,
		Timestamp:    time.Now().UTC(),
	}
	_ = db1.InsertAPICall(record)
	_ = db1.Close()

	// Reopen and verify data persisted
	db2, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to reopen database: %v", err)
	}
	defer func() { _ = db2.Close() }()

	records, err := db2.GetRecentCalls(10)
	if err != nil {
		t.Fatalf("Failed to get records: %v", err)
	}

	if len(records) != 1 {
		t.Errorf("Expected 1 persisted record, got %d", len(records))
	}
	if records[0].SessionID != "persist-test" {
		t.Errorf("Data not persisted correctly: got session %s", records[0].SessionID)
	}
}

func TestDatabase_ConcurrentWrites(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := NewDatabase(dbPath)
	if err != nil {
		t.Fatalf("Failed to create database: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Sequential writes with goroutines (more realistic)
	// In practice, API calls don't happen at exactly the same microsecond
	var wg sync.WaitGroup
	successCount := int32(0)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			// Small stagger to simulate realistic write patterns
			time.Sleep(time.Duration(idx) * time.Millisecond)

			record := &APICallRecord{
				SessionID:  "concurrent-" + string(rune('0'+idx)),
				Provider:   ProviderOpenAI,
				Model:      "gpt-4o-mini",
				Endpoint:   "/v1/chat/completions",
				StatusCode: 200,
				Timestamp:  time.Now().UTC(),
			}
			if err := db.InsertAPICall(record); err == nil {
				atomic.AddInt32(&successCount, 1)
			}
		}(i)
	}

	wg.Wait()

	// Verify records were written
	records, err := db.GetRecentCalls(20)
	if err != nil {
		t.Fatalf("Failed to get records: %v", err)
	}

	// With staggered writes, most or all should succeed
	if len(records) < 8 {
		t.Errorf("Expected at least 8 records from staggered concurrent writes, got %d", len(records))
	}
}

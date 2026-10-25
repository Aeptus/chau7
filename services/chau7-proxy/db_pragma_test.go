package main

import (
	"path/filepath"
	"testing"
)

// TestBusyTimeoutIsAppliedToPooledConnections verifies the DSN pragma actually
// reaches SQLite. The setting is expressed as a driver-specific query parameter
// (`_pragma=busy_timeout(...)`), so a typo or an unsupported form fails silently
// -- the database opens fine and every connection simply keeps SQLite's default
// of no waiting, surfacing later as dropped writes under contention rather than
// as a startup error.
func TestBusyTimeoutIsAppliedToPooledConnections(t *testing.T) {
	db, err := NewDatabase(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer func() { _ = db.Close() }()

	var timeoutMs int
	if err := db.db.QueryRow("PRAGMA busy_timeout").Scan(&timeoutMs); err != nil {
		t.Fatalf("read busy_timeout: %v", err)
	}

	if timeoutMs == 0 {
		t.Fatal("busy_timeout is 0: the DSN pragma is not being applied, so writes fail immediately under contention")
	}
	if want := 5000; timeoutMs != want {
		t.Errorf("busy_timeout = %d ms, want %d", timeoutMs, want)
	}
}

// TestJournalModeIsWAL pins the concurrency mode the busy handling assumes.
func TestJournalModeIsWAL(t *testing.T) {
	db, err := NewDatabase(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer func() { _ = db.Close() }()

	var mode string
	if err := db.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil {
		t.Fatalf("read journal_mode: %v", err)
	}
	if mode != "wal" {
		t.Errorf("journal_mode = %q, want %q", mode, "wal")
	}
}

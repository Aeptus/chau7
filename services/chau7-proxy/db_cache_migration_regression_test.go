package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// A legacy database that already received cache_creation_input_tokens but not
// the other two counters. The fixture carries the full base schema because
// initSchema creates indexes on session_id/timestamp/provider before migrating.
func TestNewDatabaseMigratesEachCacheCounterIndependently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "analytics.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE api_calls (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		session_id TEXT,
		provider TEXT NOT NULL,
		model TEXT,
		endpoint TEXT NOT NULL,
		input_tokens INTEGER,
		output_tokens INTEGER,
		latency_ms INTEGER,
		ttft_ms INTEGER DEFAULT 0,
		status_code INTEGER,
		cost_usd REAL,
		pricing_version TEXT,
		timestamp TEXT DEFAULT (datetime('now')),
		error_message TEXT,
		task_id TEXT,
		tab_id TEXT,
		project_path TEXT,
		cache_creation_input_tokens INTEGER
	)`)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	analytics, err := NewDatabase(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = analytics.Close() }()

	rows, err := analytics.db.Query("PRAGMA table_info(api_calls)")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notnull, pk int
		var name, columnType string
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &columnType, &notnull, &defaultValue, &pk); err != nil {
			t.Fatal(err)
		}
		columns[name] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !columns["cache_creation_input_tokens"] || !columns["cache_read_input_tokens"] || !columns["reasoning_output_tokens"] {
		t.Fatalf("cache columns = %#v", columns)
	}
}

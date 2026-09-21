package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestNewDatabaseMigratesEachCacheCounterIndependently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "analytics.db")
	db, err := sql.Open("sqlite", path)
	if err != nil { t.Fatal(err) }
	_, err = db.Exec(`CREATE TABLE api_calls (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		provider TEXT NOT NULL,
		endpoint TEXT NOT NULL,
		cache_creation_input_tokens INTEGER
	)`)
	if err != nil { t.Fatal(err) }
	if err := db.Close(); err != nil { t.Fatal(err) }

	analytics, err := NewDatabase(path)
	if err != nil { t.Fatal(err) }
	defer analytics.Close()

	rows, err := analytics.db.Query("PRAGMA table_info(api_calls)")
	if err != nil { t.Fatal(err) }
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notnull, pk int
		var name, columnType string
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &columnType, &notnull, &defaultValue, &pk); err != nil { t.Fatal(err) }
		columns[name] = true
	}
	if err := rows.Err(); err != nil { t.Fatal(err) }
	if !columns["cache_creation_input_tokens"] || !columns["cache_read_input_tokens"] || !columns["reasoning_output_tokens"] {
		t.Fatalf("cache columns = %#v", columns)
	}
}

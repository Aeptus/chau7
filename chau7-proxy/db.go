package main

import (
	"database/sql"
	"time"

	_ "modernc.org/sqlite"
)

// APICallRecord represents a single API call to be stored in the database
type APICallRecord struct {
	SessionID    string
	Provider     Provider
	Model        string
	Endpoint     string
	InputTokens  int
	OutputTokens int
	LatencyMs    int64
	StatusCode   int
	CostUSD      float64
	Timestamp    time.Time
	ErrorMessage string
}

// Database wraps SQLite operations
type Database struct {
	db *sql.DB
}

// NewDatabase creates and initializes the SQLite database
func NewDatabase(dbPath string) (*Database, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}

	// Enable WAL mode for better concurrent access
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, err
	}

	// Set busy timeout to handle concurrent writes gracefully
	if _, err := db.Exec("PRAGMA busy_timeout=5000"); err != nil {
		db.Close()
		return nil, err
	}

	// Create tables
	if err := initSchema(db); err != nil {
		db.Close()
		return nil, err
	}

	return &Database{db: db}, nil
}

// Close closes the database connection
func (d *Database) Close() error {
	if d.db != nil {
		return d.db.Close()
	}
	return nil
}

// InsertAPICall inserts a new API call record
func (d *Database) InsertAPICall(record *APICallRecord) error {
	_, err := d.db.Exec(`
		INSERT INTO api_calls (
			session_id, provider, model, endpoint,
			input_tokens, output_tokens, latency_ms, status_code,
			cost_usd, timestamp, error_message
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		record.SessionID,
		string(record.Provider),
		record.Model,
		record.Endpoint,
		record.InputTokens,
		record.OutputTokens,
		record.LatencyMs,
		record.StatusCode,
		record.CostUSD,
		record.Timestamp.UTC().Format(time.RFC3339),
		record.ErrorMessage,
	)
	return err
}

// GetDailyStats returns aggregated stats for today
func (d *Database) GetDailyStats() (*DailyStats, error) {
	today := time.Now().UTC().Format("2006-01-02")

	row := d.db.QueryRow(`
		SELECT
			COUNT(*) as call_count,
			COALESCE(SUM(input_tokens), 0) as total_input,
			COALESCE(SUM(output_tokens), 0) as total_output,
			COALESCE(SUM(cost_usd), 0) as total_cost,
			COALESCE(AVG(latency_ms), 0) as avg_latency
		FROM api_calls
		WHERE date(timestamp) = ?
	`, today)

	var stats DailyStats
	err := row.Scan(
		&stats.CallCount,
		&stats.TotalInputTokens,
		&stats.TotalOutputTokens,
		&stats.TotalCost,
		&stats.AvgLatencyMs,
	)
	if err != nil {
		return nil, err
	}

	return &stats, nil
}

// GetRecentCalls returns the most recent API calls
func (d *Database) GetRecentCalls(limit int) ([]APICallRecord, error) {
	rows, err := d.db.Query(`
		SELECT
			session_id, provider, model, endpoint,
			input_tokens, output_tokens, latency_ms, status_code,
			cost_usd, timestamp, error_message
		FROM api_calls
		ORDER BY timestamp DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var records []APICallRecord
	for rows.Next() {
		var r APICallRecord
		var provider string
		var timestamp string
		var errorMsg sql.NullString

		err := rows.Scan(
			&r.SessionID,
			&provider,
			&r.Model,
			&r.Endpoint,
			&r.InputTokens,
			&r.OutputTokens,
			&r.LatencyMs,
			&r.StatusCode,
			&r.CostUSD,
			&timestamp,
			&errorMsg,
		)
		if err != nil {
			return nil, err
		}

		r.Provider = Provider(provider)
		r.Timestamp, _ = time.Parse(time.RFC3339, timestamp)
		if errorMsg.Valid {
			r.ErrorMessage = errorMsg.String
		}

		records = append(records, r)
	}

	return records, rows.Err()
}

// DailyStats contains aggregated statistics
type DailyStats struct {
	CallCount         int
	TotalInputTokens  int
	TotalOutputTokens int
	TotalCost         float64
	AvgLatencyMs      float64
}

// initSchema creates the database schema
func initSchema(db *sql.DB) error {
	schema := `
		CREATE TABLE IF NOT EXISTS api_calls (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			session_id TEXT,
			provider TEXT NOT NULL,
			model TEXT,
			endpoint TEXT NOT NULL,
			input_tokens INTEGER DEFAULT 0,
			output_tokens INTEGER DEFAULT 0,
			latency_ms INTEGER,
			status_code INTEGER,
			cost_usd REAL DEFAULT 0,
			timestamp TEXT DEFAULT (datetime('now')),
			error_message TEXT
		);

		CREATE INDEX IF NOT EXISTS idx_api_calls_session ON api_calls(session_id);
		CREATE INDEX IF NOT EXISTS idx_api_calls_timestamp ON api_calls(timestamp);
		CREATE INDEX IF NOT EXISTS idx_api_calls_provider ON api_calls(provider, model);

		CREATE TABLE IF NOT EXISTS model_pricing (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider TEXT NOT NULL,
			model_pattern TEXT NOT NULL,
			input_per_mtok REAL NOT NULL,
			output_per_mtok REAL NOT NULL,
			effective_date TEXT NOT NULL,
			UNIQUE(provider, model_pattern, effective_date)
		);
	`

	_, err := db.Exec(schema)
	return err
}

// Health check for database
func (d *Database) Ping() error {
	return d.db.Ping()
}

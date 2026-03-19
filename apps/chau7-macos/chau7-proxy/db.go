package main

import (
	"database/sql"
	"encoding/json"
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
	TTFTMs       int64 // Time-to-first-token (ms from request start to first response byte)
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
			input_tokens, output_tokens, latency_ms, ttft_ms, status_code,
			cost_usd, timestamp, error_message
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		record.SessionID,
		string(record.Provider),
		record.Model,
		record.Endpoint,
		record.InputTokens,
		record.OutputTokens,
		record.LatencyMs,
		record.TTFTMs,
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
			input_tokens, output_tokens, latency_ms, ttft_ms, status_code,
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
			&r.TTFTMs,
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
	// Create tables first (without indexes that depend on migrated columns).
	// CREATE TABLE IF NOT EXISTS is a no-op for existing tables, so new columns
	// in the definition are only applied to fresh databases.
	tables := `
		CREATE TABLE IF NOT EXISTS api_calls (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			session_id TEXT,
			provider TEXT NOT NULL,
			model TEXT,
			endpoint TEXT NOT NULL,
			input_tokens INTEGER DEFAULT 0,
			output_tokens INTEGER DEFAULT 0,
			latency_ms INTEGER,
			ttft_ms INTEGER DEFAULT 0,
			status_code INTEGER,
			cost_usd REAL DEFAULT 0,
			timestamp TEXT DEFAULT (datetime('now')),
			error_message TEXT,
			task_id TEXT,
			tab_id TEXT,
			project_path TEXT
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

		CREATE TABLE IF NOT EXISTS tasks (
			id TEXT PRIMARY KEY,
			candidate_id TEXT,
			tab_id TEXT NOT NULL,
			session_id TEXT,
			project_path TEXT,
			name TEXT,
			state TEXT NOT NULL DEFAULT 'active',
			start_method TEXT,
			trigger TEXT,
			started_at TEXT NOT NULL,
			completed_at TEXT,
			created_at TEXT DEFAULT (datetime('now'))
		);

		CREATE INDEX IF NOT EXISTS idx_tasks_tab ON tasks(tab_id);
		CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
		CREATE INDEX IF NOT EXISTS idx_tasks_started ON tasks(started_at);

		CREATE TABLE IF NOT EXISTS task_assessments (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id TEXT NOT NULL,
			approved INTEGER NOT NULL,
			note TEXT,
			total_api_calls INTEGER,
			total_tokens INTEGER,
			total_cost_usd REAL,
			duration_seconds INTEGER,
			assessed_at TEXT DEFAULT (datetime('now')),
			FOREIGN KEY (task_id) REFERENCES tasks(id)
		);

		CREATE INDEX IF NOT EXISTS idx_assessments_task ON task_assessments(task_id);

		CREATE TABLE IF NOT EXISTS events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			type TEXT NOT NULL,
			data TEXT NOT NULL,
			timestamp TEXT DEFAULT (datetime('now'))
		);

		CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
		CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);

		-- v1.2: Model output statistics for baseline estimation
		CREATE TABLE IF NOT EXISTS model_output_stats (
			model TEXT PRIMARY KEY,
			total_calls INTEGER DEFAULT 0,
			total_output INTEGER DEFAULT 0,
			avg_output REAL DEFAULT 0,
			last_updated TEXT DEFAULT (datetime('now'))
		);
	`

	if _, err := db.Exec(tables); err != nil {
		return err
	}

	// Run migrations to add columns missing from pre-existing tables.
	// This must happen before creating indexes on those columns.
	if err := runMigrations(db); err != nil {
		return err
	}

	// Post-migration indexes (depend on columns added by runMigrations).
	postMigrationIndexes := `
		CREATE INDEX IF NOT EXISTS idx_api_calls_task ON api_calls(task_id);
	`
	_, err := db.Exec(postMigrationIndexes)
	return err
}

// runMigrations handles schema upgrades for existing databases
func runMigrations(db *sql.DB) error {
	// Check if task_id column exists in api_calls
	rows, err := db.Query("PRAGMA table_info(api_calls)")
	if err != nil {
		return err
	}
	defer rows.Close()

	hasTaskID := false
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			continue
		}
		if name == "task_id" {
			hasTaskID = true
			break
		}
	}

	if !hasTaskID {
		// Add new columns to api_calls
		migrations := []string{
			"ALTER TABLE api_calls ADD COLUMN task_id TEXT",
			"ALTER TABLE api_calls ADD COLUMN tab_id TEXT",
			"ALTER TABLE api_calls ADD COLUMN project_path TEXT",
		}
		for _, m := range migrations {
			db.Exec(m) // Ignore errors for columns that may already exist
		}
	}

	// v1.2 migrations: Add baseline fields to api_calls
	baselineMigrations := []string{
		"ALTER TABLE api_calls ADD COLUMN baseline_input_tokens INTEGER",
		"ALTER TABLE api_calls ADD COLUMN baseline_output_tokens INTEGER",
		"ALTER TABLE api_calls ADD COLUMN baseline_total_tokens INTEGER",
		"ALTER TABLE api_calls ADD COLUMN baseline_method TEXT",
		"ALTER TABLE api_calls ADD COLUMN baseline_version TEXT",
		"ALTER TABLE api_calls ADD COLUMN tokens_saved INTEGER",
	}
	for _, m := range baselineMigrations {
		db.Exec(m) // Ignore errors for columns that may already exist
	}

	// v1.2: Add baseline fields to task_assessments
	assessmentMigrations := []string{
		"ALTER TABLE task_assessments ADD COLUMN baseline_total_tokens INTEGER",
		"ALTER TABLE task_assessments ADD COLUMN tokens_saved INTEGER",
		"ALTER TABLE task_assessments ADD COLUMN baseline_method TEXT",
	}
	for _, m := range assessmentMigrations {
		db.Exec(m) // Ignore errors for columns that may already exist
	}

	// Create model_output_stats table if it doesn't exist (for older databases)
	db.Exec(`
		CREATE TABLE IF NOT EXISTS model_output_stats (
			model TEXT PRIMARY KEY,
			total_calls INTEGER DEFAULT 0,
			total_output INTEGER DEFAULT 0,
			avg_output REAL DEFAULT 0,
			last_updated TEXT DEFAULT (datetime('now'))
		)
	`)

	return nil
}

// Health check for database
func (d *Database) Ping() error {
	return d.db.Ping()
}

// --- Task Methods ---

// InsertTask creates a new task record
func (d *Database) InsertTask(task *Task) error {
	var completedAt *string
	if task.CompletedAt != nil {
		s := task.CompletedAt.UTC().Format(time.RFC3339)
		completedAt = &s
	}

	_, err := d.db.Exec(`
		INSERT INTO tasks (
			id, candidate_id, tab_id, session_id, project_path,
			name, state, start_method, trigger, started_at, completed_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		task.ID,
		task.CandidateID,
		task.TabID,
		task.SessionID,
		task.ProjectPath,
		task.Name,
		string(task.State),
		string(task.StartMethod),
		string(task.Trigger),
		task.StartedAt.UTC().Format(time.RFC3339),
		completedAt,
	)
	return err
}

// UpdateTask updates an existing task record
func (d *Database) UpdateTask(task *Task) error {
	var completedAt *string
	if task.CompletedAt != nil {
		s := task.CompletedAt.UTC().Format(time.RFC3339)
		completedAt = &s
	}

	_, err := d.db.Exec(`
		UPDATE tasks SET
			name = ?,
			state = ?,
			completed_at = ?
		WHERE id = ?
	`,
		task.Name,
		string(task.State),
		completedAt,
		task.ID,
	)
	return err
}

// GetTask retrieves a task by ID
func (d *Database) GetTask(taskID string) (*Task, error) {
	row := d.db.QueryRow(`
		SELECT id, candidate_id, tab_id, session_id, project_path,
			   name, state, start_method, trigger, started_at, completed_at
		FROM tasks WHERE id = ?
	`, taskID)

	var task Task
	var candidateID, sessionID, projectPath, name sql.NullString
	var startMethod, trigger, completedAt sql.NullString
	var startedAt string

	err := row.Scan(
		&task.ID,
		&candidateID,
		&task.TabID,
		&sessionID,
		&projectPath,
		&name,
		&task.State,
		&startMethod,
		&trigger,
		&startedAt,
		&completedAt,
	)
	if err != nil {
		return nil, err
	}

	task.CandidateID = candidateID.String
	task.SessionID = sessionID.String
	task.ProjectPath = projectPath.String
	task.Name = name.String
	task.StartMethod = TaskStartMethod(startMethod.String)
	task.Trigger = TaskTrigger(trigger.String)
	task.StartedAt, _ = time.Parse(time.RFC3339, startedAt)
	if completedAt.Valid {
		t, _ := time.Parse(time.RFC3339, completedAt.String)
		task.CompletedAt = &t
	}

	return &task, nil
}

// GetTaskMetrics returns aggregated metrics for a task
func (d *Database) GetTaskMetrics(taskID string) (*TaskMetrics, error) {
	row := d.db.QueryRow(`
		SELECT
			COUNT(*) as total_calls,
			COALESCE(SUM(input_tokens + output_tokens), 0) as total_tokens,
			COALESCE(SUM(cost_usd), 0) as total_cost
		FROM api_calls
		WHERE task_id = ?
	`, taskID)

	var metrics TaskMetrics
	err := row.Scan(&metrics.TotalCalls, &metrics.TotalTokens, &metrics.TotalCost)
	if err != nil {
		return nil, err
	}
	return &metrics, nil
}

// UpdateCallTaskID updates the task_id for an API call
func (d *Database) UpdateCallTaskID(callID string, taskID string) error {
	_, err := d.db.Exec(`UPDATE api_calls SET task_id = ? WHERE id = ?`, taskID, callID)
	return err
}

// InsertTaskAssessment records a task assessment
func (d *Database) InsertTaskAssessment(assessment *TaskAssessment) error {
	approved := 0
	if assessment.Approved {
		approved = 1
	}

	_, err := d.db.Exec(`
		INSERT INTO task_assessments (
			task_id, approved, note, total_api_calls,
			total_tokens, total_cost_usd, duration_seconds, assessed_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`,
		assessment.TaskID,
		approved,
		assessment.Note,
		assessment.TotalAPICalls,
		assessment.TotalTokens,
		assessment.TotalCostUSD,
		assessment.DurationSeconds,
		assessment.AssessedAt.UTC().Format(time.RFC3339),
	)
	return err
}

// InsertAPICallWithTask inserts an API call with task correlation
func (d *Database) InsertAPICallWithTask(record *APICallRecord, taskID, tabID, projectPath string) (int64, error) {
	result, err := d.db.Exec(`
		INSERT INTO api_calls (
			session_id, provider, model, endpoint,
			input_tokens, output_tokens, latency_ms, ttft_ms, status_code,
			cost_usd, timestamp, error_message, task_id, tab_id, project_path
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		record.SessionID,
		string(record.Provider),
		record.Model,
		record.Endpoint,
		record.InputTokens,
		record.OutputTokens,
		record.LatencyMs,
		record.TTFTMs,
		record.StatusCode,
		record.CostUSD,
		record.Timestamp.UTC().Format(time.RFC3339),
		record.ErrorMessage,
		taskID,
		tabID,
		projectPath,
	)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

// InsertEvent stores an event in the database
func (d *Database) InsertEvent(eventType string, data []byte) error {
	_, err := d.db.Exec(`
		INSERT INTO events (type, data, timestamp)
		VALUES (?, ?, datetime('now'))
	`, eventType, string(data))
	return err
}

// GetEvents retrieves recent events with pagination
func (d *Database) GetEvents(limit, offset int) ([]Event, int, error) {
	// Get total count
	var total int
	err := d.db.QueryRow(`SELECT COUNT(*) FROM events`).Scan(&total)
	if err != nil {
		return nil, 0, err
	}

	// Get events
	rows, err := d.db.Query(`
		SELECT type, data, timestamp
		FROM events
		ORDER BY timestamp DESC
		LIMIT ? OFFSET ?
	`, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var eventType, data, timestamp string
		if err := rows.Scan(&eventType, &data, &timestamp); err != nil {
			continue
		}

		var eventData interface{}
		json.Unmarshal([]byte(data), &eventData)

		events = append(events, Event{
			Type:      eventType,
			Data:      eventData,
			Timestamp: timestamp,
		})
	}

	return events, total, rows.Err()
}

// --- v1.2 Baseline Methods ---

// UpdateModelOutputStats updates the output statistics for a model
func (d *Database) UpdateModelOutputStats(model string, outputTokens int) error {
	_, err := d.db.Exec(`
		INSERT INTO model_output_stats (model, total_calls, total_output, avg_output, last_updated)
		VALUES (?, 1, ?, ?, datetime('now'))
		ON CONFLICT(model) DO UPDATE SET
			total_calls = total_calls + 1,
			total_output = total_output + excluded.total_output,
			avg_output = CAST((total_output + excluded.total_output) AS REAL) / (total_calls + 1),
			last_updated = datetime('now')
	`, model, outputTokens, float64(outputTokens))
	return err
}

// GetModelOutputStats retrieves all model output statistics
func (d *Database) GetModelOutputStats() ([]*ModelOutputStats, error) {
	rows, err := d.db.Query(`
		SELECT model, total_calls, total_output, avg_output, last_updated
		FROM model_output_stats
		WHERE total_calls > 0
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var stats []*ModelOutputStats
	for rows.Next() {
		var s ModelOutputStats
		var lastUpdated string
		if err := rows.Scan(&s.Model, &s.TotalCalls, &s.TotalOutput, &s.AvgOutput, &lastUpdated); err != nil {
			continue
		}
		s.LastUpdated, _ = time.Parse(time.RFC3339, lastUpdated)
		stats = append(stats, &s)
	}
	return stats, rows.Err()
}

// InsertAPICallWithBaseline inserts an API call with task and baseline data
func (d *Database) InsertAPICallWithBaseline(record *APICallRecord, taskID, tabID, projectPath string, baseline *BaselineEstimate) (int64, error) {
	var baselineInput, baselineOutput, baselineTotal, tokensSaved *int
	var baselineMethod, baselineVersion *string

	if baseline != nil {
		baselineInput = &baseline.InputTokens
		baselineOutput = &baseline.OutputTokens
		baselineTotal = &baseline.TotalTokens
		tokensSaved = &baseline.TokensSaved
		method := string(baseline.Method)
		baselineMethod = &method
		baselineVersion = &baseline.Version
	}

	result, err := d.db.Exec(`
		INSERT INTO api_calls (
			session_id, provider, model, endpoint,
			input_tokens, output_tokens, latency_ms, ttft_ms, status_code,
			cost_usd, timestamp, error_message, task_id, tab_id, project_path,
			baseline_input_tokens, baseline_output_tokens, baseline_total_tokens,
			baseline_method, baseline_version, tokens_saved
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		record.SessionID,
		string(record.Provider),
		record.Model,
		record.Endpoint,
		record.InputTokens,
		record.OutputTokens,
		record.LatencyMs,
		record.TTFTMs,
		record.StatusCode,
		record.CostUSD,
		record.Timestamp.UTC().Format(time.RFC3339),
		record.ErrorMessage,
		taskID,
		tabID,
		projectPath,
		baselineInput,
		baselineOutput,
		baselineTotal,
		baselineMethod,
		baselineVersion,
		tokensSaved,
	)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

// GetTaskBaselineMetrics returns aggregated baseline metrics for a task
func (d *Database) GetTaskBaselineMetrics(taskID string) (*TaskBaselineMetrics, error) {
	row := d.db.QueryRow(`
		SELECT
			COALESCE(SUM(baseline_total_tokens), 0) as baseline_total,
			COALESCE(SUM(tokens_saved), 0) as tokens_saved,
			COUNT(CASE WHEN baseline_method IS NOT NULL THEN 1 END) as baseline_count
		FROM api_calls
		WHERE task_id = ?
	`, taskID)

	var metrics TaskBaselineMetrics
	err := row.Scan(&metrics.BaselineTotalTokens, &metrics.TokensSaved, &metrics.BaselineCallCount)
	if err != nil {
		return nil, err
	}
	return &metrics, nil
}

// TaskBaselineMetrics contains baseline aggregation for a task
type TaskBaselineMetrics struct {
	BaselineTotalTokens int
	TokensSaved         int
	BaselineCallCount   int
}

// InsertTaskAssessmentWithBaseline records a task assessment with baseline data
func (d *Database) InsertTaskAssessmentWithBaseline(assessment *TaskAssessment, baseline *TaskBaselineMetrics) error {
	approved := 0
	if assessment.Approved {
		approved = 1
	}

	var baselineTotal, tokensSaved *int
	var baselineMethod *string
	if baseline != nil && baseline.BaselineCallCount > 0 {
		baselineTotal = &baseline.BaselineTotalTokens
		tokensSaved = &baseline.TokensSaved
		method := "aggregated"
		baselineMethod = &method
	}

	_, err := d.db.Exec(`
		INSERT INTO task_assessments (
			task_id, approved, note, total_api_calls,
			total_tokens, total_cost_usd, duration_seconds, assessed_at,
			baseline_total_tokens, tokens_saved, baseline_method
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		assessment.TaskID,
		approved,
		assessment.Note,
		assessment.TotalAPICalls,
		assessment.TotalTokens,
		assessment.TotalCostUSD,
		assessment.DurationSeconds,
		assessment.AssessedAt.UTC().Format(time.RFC3339),
		baselineTotal,
		tokensSaved,
		baselineMethod,
	)
	return err
}

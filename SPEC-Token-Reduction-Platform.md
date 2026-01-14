# Token Reduction Platform Spec (Chau7 + Proxy + Aethyme + Mockup)

## Goal
Provide measurable, per-task token and cost reduction for teams by combining:
- Local agent workflows and human assessment (Chau7)
- Repo intelligence and context packs (Aethyme)
- A portable API proxy with accurate token accounting and business logic (Go proxy)
- A SaaS cockpit for analytics and accountability (Mockup)

The system must make task outcomes and savings deterministic, auditable, and portable across OSes.

## Non-Goals
- Full multi-agent orchestration in v1.
- Storing raw prompts or code by default (opt-in only).
- OS-specific proxy implementations (proxy must remain cross-platform).
- Business logic in platform-specific clients (keep in proxy for portability).

## Portability Requirements
- Proxy is a self-contained Go binary (no CGO), runnable on macOS/Linux/Windows.
- Proxy owns all business logic: task detection, baseline estimation, metrics computation.
- Shared data contracts (events, headers, APIs) are OS-agnostic.
- Only the Chau7 UI and shortcuts are macOS-specific.
- Future clients (VS Code, Linux terminal) use the same proxy with identical behavior.

## Schema Version
Current schema version: `1.0.0`

All events include `schema_version` for forward compatibility. Consumers must ignore unknown fields. Breaking changes require a major version bump.

## System Overview
```
┌─────────────────┐     ┌──────────────────────────────────────┐     ┌─────────────────┐
│   CLI Tool      │────▶│            Go Proxy                  │────▶│  Provider API   │
│  (Claude Code)  │◀────│  - Token accounting                  │◀────│  (Anthropic)    │
└─────────────────┘     │  - Task lifecycle detection          │     └─────────────────┘
                        │  - Baseline estimation               │
        ┌───────────────│  - Metrics computation               │───────────────┐
        │               │  - Event emission                    │               │
        │               └──────────────────────────────────────┘               │
        │ IPC                           │ HTTP                                 │ HTTP
        ▼                               ▼                                      ▼
┌─────────────────┐           ┌─────────────────┐                    ┌─────────────────┐
│     Chau7       │           │     Aethyme     │                    │     Mockup      │
│  (macOS UI)     │           │  (Repo Intel)   │                    │  (SaaS Analytics)│
└─────────────────┘           └─────────────────┘                    └─────────────────┘
```

Component responsibilities:
- **Chau7**: Local terminal UI, displays events, accepts user input (task naming, assessment).
- **Go Proxy**: ALL business logic - task detection, token accounting, baseline estimation, event emission.
- **Aethyme**: Repo intelligence, context packs, skill metadata, scorecards.
- **Mockup**: Tenancy, RBAC, audit logging, analytics dashboards.

## Implementation Status

| Component | Feature | Status |
|-----------|---------|--------|
| Proxy | Token accounting (Anthropic, OpenAI, Gemini) | ✅ Implemented |
| Proxy | Cost calculation | ✅ Implemented |
| Proxy | IPC event emission | ✅ Implemented |
| Proxy | SQLite storage | ✅ Implemented |
| Proxy | Correlation headers | 🔜 Planned v1.1 |
| Proxy | Task lifecycle detection | 🔜 Planned v1.1 |
| Proxy | Baseline estimation | 🔜 Planned v1.2 |
| Chau7 | Proxy integration | ✅ Implemented |
| Chau7 | Task naming UI | 🔜 Planned v1.1 |
| Chau7 | Task assessment UI | 🔜 Planned v1.1 |
| Aethyme | Context packs | 🔜 Planned v1.2 |
| Mockup | Event ingestion | 🔜 Planned v1.2 |

## Core Entities
- **Tenant, Org, User**: Managed in Mockup.
- **Repo**: Managed in Aethyme (repo_id, local path).
- **Session**: Provider session or conversation ID.
- **Tab**: Chau7 tab identifier.
- **Task**: Primary unit of measurement. One task per tab.
- **TaskCandidate**: Heuristic suggestion that a new task should start (emitted by proxy).
- **TaskAssessment**: Human approval or failure of a task (captured by Chau7, forwarded to proxy).
- **APICall**: Each LLM call captured by the proxy.
- **ContextPack, SkillPack**: Aethyme artifacts referenced by ID.

## Task Lifecycle (Owned by Proxy)

The proxy owns task lifecycle detection to ensure consistent behavior across all clients.

### Task Start Triggers (Priority Order - First Match Wins)
1. **Manual**: `X-Chau7-New-Task: true` header forces new task immediately (bypasses candidate state).
2. **New session**: New `X-Chau7-Session` value with no active task.
3. **Idle gap**: Last activity > N minutes (configurable, default 30).
4. **Repo switch**: `X-Chau7-Project` changes from previous call.

For triggers 2-4, the proxy emits a `task_candidate` event and auto-confirms after a grace period unless dismissed.

### Task State Machine (Proxy-Side)
```
[No Task] ──manual──▶ [Active] ──assess──▶ [Completed]
     │                    │
     └──trigger──▶ [Candidate] ──grace_period──▶ [Active]
                       │                            │
                       └──dismiss──▶ [No Task]      └──timeout──▶ [Abandoned]
```

**Manual trigger** (`X-Chau7-New-Task: true`): Bypasses candidate state entirely, directly creates active task.

**Heuristic triggers**: Create a candidate that auto-confirms after a configurable grace period (default 5 seconds) unless dismissed.

### Task Candidate Confirmation

Candidates are handled via a preflight + layered mechanism:

**Preflight (default path)**: Before making an LLM call, the client sends `GET /task/candidate` to check for pending candidates. If a candidate exists, the client can:
- Confirm it (let grace period expire or call `/task/start`)
- Dismiss it (`POST /task/dismiss`)
- Override it (`X-Chau7-New-Task: true` on the next API call)

**Layered dismissal**:
1. **Auto-confirm (default)**: After `CHAU7_CANDIDATE_GRACE_PERIOD` seconds (default 5s), candidates auto-confirm.
2. **Header-based dismiss**: Include `X-Chau7-Dismiss-Candidate: <candidate_id>` on any API call to dismiss.
3. **Endpoint dismiss**: `POST /task/dismiss` with `{"candidate_id": "cand_abc123"}` to explicitly dismiss.

**First call assignment**: If an API call arrives during the candidate grace period, it is assigned to the candidate (provisional). If the candidate is later dismissed, the call is reassigned to the previous active task (or marked task-less if none).

This design ensures the first LLM call timing doesn't create a race condition.

### Task Naming
- Tasks start with a placeholder name: `"Untitled Task"` (or timestamp-based like `"Task 2026-01-14 12:00"`).
- Name is updated after first prompt is parsed (verb phrase or first 6-10 words).
- Prompt content is stored locally only (never transmitted to cloud services).
- Client can override via `X-Chau7-Task-Name` header at any time.
- If user dismisses candidate, current task continues.

**Name update event**: When a task name is derived or updated, emit `task_name_updated` event (not a separate event type - use `task_started` with updated name or a lightweight IPC notification).

### Task Assessment
- Client sends assessment via HTTP endpoint or header.
- Proxy records outcome and emits `task_assessment` event.

## Proxy Responsibilities (Cross-Platform)

### Token Accounting
Accurate extraction for all providers:
- **Anthropic**: `usage.input_tokens`, `usage.output_tokens`
- **OpenAI**: `usage.prompt_tokens`, `usage.completion_tokens`
- **Gemini**: `usageMetadata.promptTokenCount`, `usageMetadata.candidatesTokenCount`
- Streaming: Accumulate from SSE chunks, use final usage block.

### Correlation Headers (Inbound)
Clients should set these headers on LLM requests:
| Header | Required | Description |
|--------|----------|-------------|
| `X-Chau7-Session` | Yes | Session/conversation ID |
| `X-Chau7-Tab` | Yes | Tab/terminal identifier |
| `X-Chau7-Project` | Yes | Git root or project path |
| `X-Chau7-Task` | No | Existing task ID (if known) |
| `X-Chau7-Task-Name` | No | Override auto-derived name |
| `X-Chau7-New-Task` | No | Force new task immediately (bypasses candidate) |
| `X-Chau7-Dismiss-Candidate` | No | Dismiss a pending task candidate by ID |
| `X-Chau7-Tenant` | No | Tenant ID for multi-tenant |
| `X-Chau7-Org` | No | Organization ID |
| `X-Chau7-User` | No | User ID (hashed) |

### Baseline Estimation (Planned v1.2)
Compute hypothetical token usage without context optimization:
```
baseline_input_tokens = tokenize(prompt_without_context_pack)
baseline_output_tokens = model_avg_output(model, task_type)
baseline_total_tokens = baseline_input_tokens + baseline_output_tokens
tokens_saved = baseline_total_tokens - actual_total_tokens
```

Baseline metadata includes:
- `baseline_method`: Algorithm used (e.g., `no_context_estimate`, `historical_avg`)
- `baseline_version`: Version of estimation algorithm

### Metrics Computation (Proxy-Side)
The proxy computes all metrics to ensure consistency:
- `tokens_saved`: `baseline_total_tokens - total_tokens` (can be negative)
- `cost_usd`: Computed from model pricing table
- `success_rate`: Tasks with `approved = true` / total assessed tasks

Edge cases:
- **Negative savings**: Valid - context pack increased tokens (logged for analysis).
- **Zero baseline**: Baseline estimation failed (use `baseline_method: "unavailable"`).
- **No API calls**: Task with no LLM usage (valid for manual-only tasks).

### Storage
- Local SQLite database (default) or JSONL export.
- All records include task, session, and correlation metadata.
- Configurable retention period.

### IPC and HTTP Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/stats` | GET | Daily aggregate statistics |
| `/events` | GET | Recent events (paginated) |
| `/task/start` | POST | Force start a new task (bypasses candidate) |
| `/task/dismiss` | POST | Dismiss a pending task candidate |
| `/task/assess` | POST | Submit task assessment |
| `/task/current` | GET | Get current task state |
| `/task/candidate` | GET | Get pending candidate (if any) |

IPC (Unix socket): Real-time event stream for local clients.

## Event Schema (Shared Contract)

All events are JSON objects with these common fields:
```json
{
  "schema_version": "1.0.0",
  "type": "event_type",
  "ts": "2026-01-14T12:00:00Z",
  "tool": "source_component",
  "origin": "emitting_system"
}
```

| Field | Description |
|-------|-------------|
| `tool` | The component that triggered/owns the event (e.g., `proxy`, `chau7`, `aethyme`) |
| `origin` | The system that emitted the event (future-proofs for multi-tool scenarios) |

Currently `tool` and `origin` are typically the same, but separating them allows for scenarios where one tool triggers events on behalf of another.

Unknown fields must be preserved (forward compatibility).

### Task Candidate
Emitted by proxy when a new task trigger is detected (heuristic triggers only).
```json
{
  "schema_version": "1.0.0",
  "type": "task_candidate",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:00:00Z",
  "candidate_id": "cand_abc123",
  "trigger": "idle_gap",
  "tab_id": "tab_123",
  "session_id": "sess_456",
  "project_path": "/path/to/repo",
  "suggested_name": "Fix login redirect",
  "confidence": 0.85,
  "grace_period_seconds": 5
}
```

### Task Started
Emitted when a task begins (via manual trigger or candidate confirmation).
```json
{
  "schema_version": "1.0.0",
  "type": "task_started",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:00:01Z",
  "task_id": "task_789",
  "candidate_id": "cand_abc123",
  "tab_id": "tab_123",
  "session_id": "sess_456",
  "project_path": "/path/to/repo",
  "task_name": "Fix login redirect",
  "start_method": "auto_confirmed",
  "trigger": "idle_gap"
}
```

The `start_method` field indicates how the task started:
- `manual`: Via `X-Chau7-New-Task: true` header (no candidate phase)
- `auto_confirmed`: Candidate auto-confirmed after grace period
- `user_confirmed`: User explicitly confirmed the candidate

### Task Candidate Dismissed
Emitted when a candidate is dismissed (user action prevents task creation).
```json
{
  "schema_version": "1.0.0",
  "type": "task_candidate_dismissed",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:00:05Z",
  "candidate_id": "cand_abc123",
  "tab_id": "tab_123",
  "dismiss_method": "header",
  "reason": "user_dismissed"
}
```

The `dismiss_method` field indicates how the candidate was dismissed:
- `header`: Via `X-Chau7-Dismiss-Candidate` header
- `endpoint`: Via `POST /task/dismiss` endpoint
- `ui`: Via client UI action (forwarded to proxy)

### Task Assessment
Emitted when user approves or fails a task.
```json
{
  "schema_version": "1.0.0",
  "type": "task_assessment",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:30:00Z",
  "task_id": "task_789",
  "tab_id": "tab_123",
  "session_id": "sess_456",
  "approved": true,
  "note": "Tests passed",
  "total_api_calls": 12,
  "total_tokens": 45000,
  "total_cost_usd": 0.234,
  "tokens_saved": null,
  "duration_seconds": 1800
}
```

**Note**: `tokens_saved` is `null` until baseline estimation is implemented (v1.2). Do not interpret `null` as zero savings.

### API Call
Emitted for each LLM API call.
```json
{
  "schema_version": "1.0.0",
  "type": "api_call",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:10:00Z",
  "call_id": "call_xyz",
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "endpoint": "/v1/messages",
  "input_tokens": 1200,
  "output_tokens": 800,
  "total_tokens": 2000,
  "latency_ms": 900,
  "status_code": 200,
  "cost_usd": 0.0123,
  "session_id": "sess_456",
  "task_id": "task_789",
  "tab_id": "tab_123",
  "project_path": "/path/to/repo",
  "baseline_total_tokens": null,
  "baseline_method": null,
  "tokens_saved": null,
  "is_streaming": true,
  "error_message": null
}
```

**Note**: Baseline fields (`baseline_total_tokens`, `baseline_method`, `tokens_saved`) are `null` until v1.2.

### API Call Error
When an API call fails.
```json
{
  "schema_version": "1.0.0",
  "type": "api_call",
  "tool": "proxy",
  "origin": "proxy",
  "ts": "2026-01-14T12:10:00Z",
  "call_id": "call_xyz",
  "provider": "openai",
  "model": "gpt-4o",
  "endpoint": "/v1/chat/completions",
  "input_tokens": 0,
  "output_tokens": 0,
  "total_tokens": 0,
  "latency_ms": 50,
  "status_code": 429,
  "cost_usd": 0,
  "session_id": "sess_456",
  "task_id": "task_789",
  "error_message": "rate_limit_exceeded",
  "error_type": "rate_limit",
  "retry_after_seconds": 60
}
```

## Provider-Specific Notes

### Anthropic
- Endpoint: `/v1/messages`, `/v1/complete`
- Detection: `anthropic-version` header or `x-api-key` prefix `sk-ant-`
- Streaming: Final chunk contains `usage` block
- Token fields: `input_tokens`, `output_tokens`

### OpenAI
- Endpoints: `/v1/chat/completions`, `/v1/completions`, `/v1/responses`
- Detection: Path pattern
- Streaming: `stream_options.include_usage` must be true for usage in stream
- Token fields: `prompt_tokens`, `completion_tokens`

### Gemini
- Endpoints: `/v1/models/*:generateContent`, `/v1beta/models/*:generateContent`
- Detection: Path pattern or `x-goog-api-key` header
- Token fields: `usageMetadata.promptTokenCount`, `usageMetadata.candidatesTokenCount`

## Aethyme Responsibilities
- Generate and version context packs and skill packs.
- Provide `context_pack_id`, `skill_pack_id`, and token size metadata.
- Provide repo-level scorecards for correlation with savings.
- API for proxy to fetch context pack metadata (for baseline estimation).

## Mockup Responsibilities
- Multi-tenant identity, org, and user management.
- Event ingestion (task events + proxy call metrics).
- Analytics and dashboards for token savings and behavior.
- RBAC for team-level and org-level views.

## Metrics Definitions

| Metric | Definition | Notes |
|--------|------------|-------|
| Successful task | `task_assessment.approved = true` | Only assessed tasks count |
| Tokens saved | `sum(baseline_total_tokens) - sum(total_tokens)` | Can be negative |
| Cost saved | `sum(baseline_cost) - sum(cost_usd)` | Requires baseline pricing |
| Candidates per task | `count(task_candidate) / count(task_started)` | Lower is better |
| Auto-start rate | `task_started.auto_started = true / total` | Target: >80% |
| Task completion rate | `assessed / started` | Track abandonment |
| Avg tokens per task | `sum(total_tokens) / count(tasks)` | By model/provider |

## Security and Privacy

### Local Storage (Proxy)
- Prompt content may be stored locally for task naming and debugging.
- Local storage is never transmitted to cloud services (Aethyme, Mockup).
- Allow opt-in verbose prompt logging for internal testing (`CHAU7_LOG_PROMPTS=1`).

### Cloud Transmission
- Only anonymized metrics are sent to cloud services (token counts, costs, timing).
- Raw prompt content is NEVER transmitted to cloud.
- User IDs should be hashed before sending to proxy.
- All tenant/user data is scoped and auditable.

## Configuration

Proxy environment variables:
| Variable | Description | Default |
|----------|-------------|---------|
| `CHAU7_PROXY_PORT` | HTTP port | `18080` |
| `CHAU7_DB_PATH` | SQLite database path | Required |
| `CHAU7_IPC_SOCKET` | Unix socket for IPC | Optional |
| `CHAU7_LOG_LEVEL` | Log level | `info` |
| `CHAU7_LOG_PROMPTS` | Log prompt previews (local only) | `0` |
| `CHAU7_IDLE_TIMEOUT` | Idle gap for new task (minutes) | `30` |
| `CHAU7_CANDIDATE_GRACE_PERIOD` | Seconds before candidate auto-confirms | `5` |

## Deployment and Ops
- Proxy runs locally as a sidecar.
- Chau7 controls proxy startup on macOS.
- VS Code extension will control proxy on other platforms.
- Aethyme and Mockup are cloud hosted.
- IPC is optional; HTTP endpoints exist for all clients.

## Extensibility
- Additional OS clients emit the same events and headers.
- New providers added by extending proxy metadata parsing.
- Additional task triggers can be added without breaking schemas.
- Schema versioning allows gradual migration.

## Implementation Checklist (v1.1)

### Proxy - Go Code Required

```
chau7-proxy/
├── task.go              # NEW: Task struct, state machine, triggers
├── task_endpoints.go    # NEW: /task/* HTTP handlers
├── task_test.go         # NEW: Tests for task lifecycle
├── headers.go           # NEW: Parse X-Chau7-* correlation headers
├── db.go                # MODIFY: Add tasks, task_assessments tables
├── ipc.go               # MODIFY: Add new event types
└── main.go              # MODIFY: Register new endpoints
```

**Task State Machine (task.go):**
```go
type TaskState string
const (
    TaskStateNone      TaskState = "none"
    TaskStateCandidate TaskState = "candidate"
    TaskStateActive    TaskState = "active"
    TaskStateCompleted TaskState = "completed"
    TaskStateAbandoned TaskState = "abandoned"
)

type Task struct {
    ID             string
    CandidateID    string
    TabID          string
    SessionID      string
    ProjectPath    string
    Name           string
    State          TaskState
    StartMethod    string  // "manual", "auto_confirmed", "user_confirmed"
    Trigger        string  // "manual", "idle_gap", "new_session", "repo_switch"
    StartedAt      time.Time
    CompletedAt    *time.Time
    GracePeriodEnd *time.Time
}

type TaskManager struct {
    mu            sync.RWMutex
    tasks         map[string]*Task       // tabID -> current task
    candidates    map[string]*Task       // candidateID -> pending candidate
    pendingCalls  map[string][]string    // candidateID -> call IDs (for reassignment)
    gracePeriod   time.Duration
    idleTimeout   time.Duration
    lastActivity  map[string]time.Time   // tabID -> last activity
}
```

**Endpoint Request/Response Schemas (task_endpoints.go):**
```go
// GET /task/candidate?tab_id=xxx
type CandidateResponse struct {
    HasCandidate       bool   `json:"has_candidate"`
    CandidateID        string `json:"candidate_id,omitempty"`
    SuggestedName      string `json:"suggested_name,omitempty"`
    Trigger            string `json:"trigger,omitempty"`
    GraceRemainingMs   int64  `json:"grace_remaining_ms,omitempty"`
}

// POST /task/start
type StartTaskRequest struct {
    TabID       string `json:"tab_id"`
    TaskName    string `json:"task_name,omitempty"`
    CandidateID string `json:"candidate_id,omitempty"`  // Optional: confirm specific candidate
}

type StartTaskResponse struct {
    TaskID   string `json:"task_id"`
    TaskName string `json:"task_name"`
}

// POST /task/dismiss
type DismissRequest struct {
    CandidateID string `json:"candidate_id"`
}

type DismissResponse struct {
    Dismissed       bool   `json:"dismissed"`
    ReassignedCalls int    `json:"reassigned_calls"`  // Number of calls moved to previous task
}

// POST /task/assess
type AssessRequest struct {
    TaskID   string `json:"task_id"`
    Approved bool   `json:"approved"`
    Note     string `json:"note,omitempty"`
}

// GET /task/current?tab_id=xxx
type CurrentTaskResponse struct {
    HasTask       bool    `json:"has_task"`
    TaskID        string  `json:"task_id,omitempty"`
    TaskName      string  `json:"task_name,omitempty"`
    State         string  `json:"state,omitempty"`
    TotalCalls    int     `json:"total_calls,omitempty"`
    TotalTokens   int     `json:"total_tokens,omitempty"`
    TotalCostUSD  float64 `json:"total_cost_usd,omitempty"`
    DurationSec   int64   `json:"duration_sec,omitempty"`
}

// Error response (all endpoints)
type ErrorResponse struct {
    Error   string `json:"error"`
    Code    string `json:"code,omitempty"`  // e.g., "no_candidate", "task_not_found"
}
```

**Database Schema Migration (db.go):**
```sql
-- v1.1 schema additions
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

-- Add task_id column to api_calls
ALTER TABLE api_calls ADD COLUMN task_id TEXT;
ALTER TABLE api_calls ADD COLUMN tab_id TEXT;
ALTER TABLE api_calls ADD COLUMN project_path TEXT;

CREATE INDEX IF NOT EXISTS idx_api_calls_task ON api_calls(task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_tab ON tasks(tab_id);
```

### Chau7 - Swift Code Required

```
Sources/Chau7/
├── Proxy/
│   ├── TaskCandidate.swift        # NEW: Task candidate data model
│   ├── TaskCandidateView.swift    # NEW: Banner/toast UI component
│   └── TaskAssessmentView.swift   # NEW: Success/failure buttons
├── TerminalSessionModel.swift     # MODIFY: Add tab_id, project injection
└── TerminalTabView.swift          # MODIFY: Add candidate/assessment overlays
```

**Additional Environment Variables (TerminalSessionModel.swift):**
```swift
// Add to shellEnvironment() after line 947:
dict["CHAU7_TAB_ID"] = tabIdentifier  // unique per tab
dict["CHAU7_PROJECT"] = currentDirectory  // git root or cwd
```

**IPC Event Handler Updates (ProxyIPCServer.swift):**
```swift
// Add handling for new event types:
case "task_candidate":
    handleTaskCandidate(message)
case "task_started":
    handleTaskStarted(message)
case "task_candidate_dismissed":
    handleTaskDismissed(message)
case "task_assessment":
    handleTaskAssessment(message)
```

### CLI Integration Question

**⚠️ BLOCKER**: How does Claude Code (or other CLI tools) send `X-Chau7-*` headers?

Options:
1. **Environment-to-header mapping**: CLI reads `CHAU7_*` env vars and adds as headers
   - Requires: Claude Code modification or wrapper script
2. **Proxy injects from env**: Proxy reads `CHAU7_*` from request context
   - Problem: HTTP requests don't carry parent process env
3. **Wrapper script**: Shell function wraps `claude` to add headers
   - Most portable, no CLI changes needed

**Recommended**: Option 3 - Shell wrapper in shell integration:
```bash
# In .zshrc / .bashrc (injected by Chau7)
claude() {
    command claude "$@" \
        --header "X-Chau7-Session: ${CHAU7_SESSION_ID:-}" \
        --header "X-Chau7-Tab: ${CHAU7_TAB_ID:-}" \
        --header "X-Chau7-Project: ${CHAU7_PROJECT:-}"
}
```

**OR** if Claude Code respects env vars for headers (check docs):
```bash
export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:$CHAU7_SESSION_ID,X-Chau7-Tab:$CHAU7_TAB_ID"
```

---

## Implementation Effort Assessment

### v1.0 → v1.1 (Proxy + Chau7)

| Component | Feature | Effort | Notes |
|-----------|---------|--------|-------|
| **Proxy** | Correlation headers parsing | S | Parse 10 headers, store in context |
| **Proxy** | Task state machine | M | State struct, trigger detection, grace period timer |
| **Proxy** | Task candidate endpoints | S | `/task/candidate`, `/task/dismiss`, `/task/start` |
| **Proxy** | Provisional call assignment | M | Track pending calls, reassign on dismiss |
| **Proxy** | Task naming from prompt | S | Extract first 6-10 words, verb phrase heuristic |
| **Proxy** | Event schema updates | S | Add `origin`, `start_method`, `dismiss_method` fields |
| **Chau7** | Preflight integration | S | Call `GET /task/candidate` before LLM requests |
| **Chau7** | Task candidate UI | M | Toast/banner for candidate, confirm/dismiss buttons |
| **Chau7** | Task assessment UI | M | Success/failure buttons, optional note field |
| **Chau7** | Header injection | S | Add correlation headers to spawned terminal env |

**v1.1 Total**: ~3-4 weeks for one developer

### v1.1 → v1.2 (Proxy + Aethyme + Mockup)

| Component | Feature | Effort | Notes |
|-----------|---------|--------|-------|
| **Proxy** | Baseline estimation | L | Tokenizer integration, historical avg calculation |
| **Proxy** | Aethyme API client | M | Fetch context pack metadata |
| **Aethyme** | Context pack API | M | Expose pack metadata for baseline calc |
| **Mockup** | Event ingestion | M | Webhook receiver, event storage |
| **Mockup** | Analytics dashboard | L | Charts, filters, aggregations |

**v1.2 Total**: ~6-8 weeks for one developer (or parallel with multiple)

### Effort Key
- **S** (Small): < 1 day
- **M** (Medium): 1-3 days
- **L** (Large): 1-2 weeks

---

## Full System Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    CHAU7 (macOS UI)                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│  │                              Terminal Tab (tab_123)                              │    │
│  │  ┌─────────────────────────────────────────────────────────────────────────┐    │    │
│  │  │  $ claude-code "fix the login redirect bug"                             │    │    │
│  │  │  > Working on it...                                                     │    │    │
│  │  │  > [Task: Fix login redirect] [Tokens: 2.4k] [Cost: $0.02]              │    │    │
│  │  └─────────────────────────────────────────────────────────────────────────┘    │    │
│  │                                                                                  │    │
│  │  ┌─ Task Candidate Banner ─────────────────────────────────────────────────┐    │    │
│  │  │  📋 New task detected: "Fix login redirect"     [✓ Confirm] [✗ Dismiss] │    │    │
│  │  └─────────────────────────────────────────────────────────────────────────┘    │    │
│  │                                                                                  │    │
│  │  ┌─ Task Assessment Panel ─────────────────────────────────────────────────┐    │    │
│  │  │  Task complete?  [✓ Success] [✗ Failed]  Note: [_______________]        │    │    │
│  │  └─────────────────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                                                              ▲
         │ Spawns terminal with env:                                    │ IPC (Unix socket)
         │ ANTHROPIC_BASE_URL=http://127.0.0.1:18080                    │ Real-time events
         │ X-Chau7-Session=sess_456                                     │
         │ X-Chau7-Tab=tab_123                                          │
         │ X-Chau7-Project=/path/to/repo                                │
         ▼                                                              │
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                   CLI TOOL (Claude Code)                                │
│                                                                                         │
│  1. Before LLM call:  GET /task/candidate ──────────────────────────────────┐           │
│                                                                             │           │
│  2. LLM Request with headers:                                               │           │
│     POST /v1/messages                                                       │           │
│     X-Chau7-Session: sess_456                                               │           │
│     X-Chau7-Tab: tab_123                                                    │           │
│     X-Chau7-Project: /path/to/repo                                          ▼           │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                                                              │
         │ HTTP (localhost:18080)                                       │
         ▼                                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                      GO PROXY                                           │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                            REQUEST PROCESSING                                    │   │
│  │                                                                                  │   │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │   │
│  │  │    Parse     │───▶│   Detect     │───▶│    Task      │───▶│   Forward    │   │   │
│  │  │   Headers    │    │   Provider   │    │   Trigger?   │    │  to Provider │   │   │
│  │  └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘   │   │
│  │        │                   │                    │                    │          │   │
│  │        ▼                   ▼                    ▼                    ▼          │   │
│  │  X-Chau7-Session    anthropic/openai    idle_gap? repo_switch?   Anthropic     │   │
│  │  X-Chau7-Tab        /gemini detected    new_session? manual?      OpenAI       │   │
│  │  X-Chau7-Project                                                  Gemini       │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                           TASK STATE MACHINE                                     │   │
│  │                                                                                  │   │
│  │     ┌──────────┐         ┌─────────────┐         ┌──────────┐                   │   │
│  │     │ No Task  │─manual─▶│   Active    │─assess─▶│Completed │                   │   │
│  │     └──────────┘         └─────────────┘         └──────────┘                   │   │
│  │          │                     ▲                                                 │   │
│  │          │ trigger             │ grace_period (5s)                              │   │
│  │          ▼                     │                                                 │   │
│  │     ┌─────────────┐────────────┘                                                │   │
│  │     │  Candidate  │                                                              │   │
│  │     └─────────────┘                                                              │   │
│  │          │                                                                       │   │
│  │          │ dismiss                                                               │   │
│  │          ▼                                                                       │   │
│  │     ┌──────────┐                                                                 │   │
│  │     │ No Task  │  (calls reassigned to previous task)                           │   │
│  │     └──────────┘                                                                 │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                          RESPONSE PROCESSING                                     │   │
│  │                                                                                  │   │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │   │
│  │  │   Receive    │───▶│   Extract    │───▶│  Calculate   │───▶│    Store     │   │   │
│  │  │   Response   │    │   Tokens     │    │    Cost      │    │   + Emit     │   │   │
│  │  └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘   │   │
│  │        │                   │                    │                    │          │   │
│  │        ▼                   ▼                    ▼                    ▼          │   │
│  │  Stream chunks      input_tokens: 1200   Model pricing       SQLite + IPC      │   │
│  │  or full response   output_tokens: 800   table lookup        event emission    │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  ┌─ HTTP Endpoints ────────────────────┐  ┌─ IPC Events ──────────────────────────┐   │
│  │ GET  /health                        │  │ {"type":"task_candidate",...}         │   │
│  │ GET  /stats                         │  │ {"type":"task_started",...}           │   │
│  │ GET  /task/candidate                │  │ {"type":"task_candidate_dismissed",...│   │
│  │ POST /task/start                    │  │ {"type":"task_assessment",...}        │   │
│  │ POST /task/dismiss                  │  │ {"type":"api_call",...}               │   │
│  │ POST /task/assess                   │  └───────────────────────────────────────┘   │
│  │ GET  /task/current                  │                                              │
│  └─────────────────────────────────────┘                                              │
│                                                                                         │
│  ┌─ Local Storage ─────────────────────────────────────────────────────────────────┐   │
│  │  SQLite: ~/.chau7/analytics.db                                                   │   │
│  │  ├── api_calls (id, task_id, provider, model, tokens, cost, latency, ts)        │   │
│  │  ├── tasks (id, tab_id, session_id, name, status, start_ts, end_ts)             │   │
│  │  └── task_assessments (task_id, approved, note, ts)                              │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                                           │
         │ HTTPS (v1.2)                              │ HTTPS (v1.2)
         ▼                                           ▼
┌─────────────────────────────┐          ┌─────────────────────────────┐
│         AETHYME             │          │          MOCKUP             │
│     (Repo Intelligence)     │          │     (SaaS Analytics)        │
│                             │          │                             │
│  Context Packs              │          │  Event Ingestion            │
│  Skill Packs                │          │  Analytics Dashboard        │
│  Repo Scorecards            │          │  RBAC / Multi-tenant        │
│                             │          │                             │
│  API: GET /context-pack/:id │          │  API: POST /events          │
│       GET /repo/:id/score   │          │       GET /analytics        │
└─────────────────────────────┘          └─────────────────────────────┘


═══════════════════════════════════════════════════════════════════════════════════════════
                                    DATA FLOW SEQUENCE
═══════════════════════════════════════════════════════════════════════════════════════════

┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│  User   │     │  Chau7  │     │  CLI    │     │  Proxy  │     │Provider │
└────┬────┘     └────┬────┘     └────┬────┘     └────┬────┘     └────┬────┘
     │               │               │               │               │
     │ Opens tab     │               │               │               │
     │──────────────▶│               │               │               │
     │               │               │               │               │
     │               │ Spawn terminal│               │               │
     │               │ with headers  │               │               │
     │               │──────────────▶│               │               │
     │               │               │               │               │
     │               │               │ Preflight     │               │
     │               │               │──────────────▶│               │
     │               │               │               │               │
     │               │               │ No candidate  │               │
     │               │               │◀──────────────│               │
     │               │               │               │               │
     │ Types prompt  │               │               │               │
     │──────────────▶│──────────────▶│               │               │
     │               │               │               │               │
     │               │               │ LLM Request   │               │
     │               │               │ + Headers     │               │
     │               │               │──────────────▶│               │
     │               │               │               │               │
     │               │               │               │ Detect: new   │
     │               │               │               │ session ──────│─▶ Create
     │               │               │               │               │   Candidate
     │               │               │               │               │
     │               │               │               │ Forward       │
     │               │               │               │──────────────▶│
     │               │               │               │               │
     │               │               │               │ Response      │
     │               │               │               │◀──────────────│
     │               │               │               │               │
     │               │               │               │ Extract tokens│
     │               │               │               │ Calculate cost│
     │               │               │               │ Store + emit  │
     │               │               │               │───────┐       │
     │               │               │               │       │       │
     │               │ IPC: api_call │               │◀──────┘       │
     │               │◀──────────────│───────────────│               │
     │               │               │               │               │
     │               │ IPC: task_    │               │               │
     │               │ candidate     │ Grace period  │               │
     │               │◀──────────────│───────────────│               │
     │               │               │               │               │
     │               │ Show banner   │               │               │
     │◀──────────────│               │               │               │
     │               │               │               │               │
     │ [Confirm] or  │               │               │               │
     │ let expire    │               │               │               │
     │──────────────▶│               │               │               │
     │               │               │               │               │
     │               │               │               │ task_started  │
     │               │ IPC: task_    │               │───────┐       │
     │               │ started       │               │       │       │
     │               │◀──────────────│───────────────│◀──────┘       │
     │               │               │               │               │
     │               │               │   ... more LLM calls ...      │
     │               │               │               │               │
     │ Task done,    │               │               │               │
     │ assess ✓      │               │               │               │
     │──────────────▶│               │               │               │
     │               │               │               │               │
     │               │ POST /task/   │               │               │
     │               │ assess        │               │               │
     │               │──────────────▶│──────────────▶│               │
     │               │               │               │               │
     │               │               │               │ task_         │
     │               │ IPC: task_    │               │ assessment    │
     │               │ assessment    │               │───────┐       │
     │               │◀──────────────│───────────────│◀──────┘       │
     │               │               │               │               │
     ▼               ▼               ▼               ▼               ▼


═══════════════════════════════════════════════════════════════════════════════════════════
                                    HEADER FLOW DETAIL
═══════════════════════════════════════════════════════════════════════════════════════════

  Chau7 spawns terminal with environment:
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  ANTHROPIC_BASE_URL = http://127.0.0.1:18080                                        │
  │  OPENAI_BASE_URL    = http://127.0.0.1:18080/v1                                     │
  │  CHAU7_SESSION      = sess_456        ─┐                                            │
  │  CHAU7_TAB          = tab_123          │ Injected into CLI tool's                   │
  │  CHAU7_PROJECT      = /path/to/repo   ─┘ outgoing HTTP headers                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
  CLI tool sends request:
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  POST /v1/messages HTTP/1.1                                                          │
  │  Host: 127.0.0.1:18080                                                               │
  │  Authorization: Bearer sk-ant-xxxxx                                                  │
  │  anthropic-version: 2023-06-01                                                       │
  │  X-Chau7-Session: sess_456            ◀── Correlation                               │
  │  X-Chau7-Tab: tab_123                 ◀── Correlation                               │
  │  X-Chau7-Project: /path/to/repo       ◀── Correlation                               │
  │  X-Chau7-Task: task_789               ◀── Optional (if known)                       │
  │  X-Chau7-New-Task: true               ◀── Optional (force new)                      │
  │  X-Chau7-Dismiss-Candidate: cand_abc  ◀── Optional (dismiss)                        │
  │  Content-Type: application/json                                                      │
  │                                                                                      │
  │  {"model":"claude-sonnet-4-20250514","messages":[...]}                              │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
  Proxy forwards to provider (strips X-Chau7-* headers):
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  POST /v1/messages HTTP/1.1                                                          │
  │  Host: api.anthropic.com                                                             │
  │  Authorization: Bearer sk-ant-xxxxx                                                  │
  │  anthropic-version: 2023-06-01                                                       │
  │  Content-Type: application/json                                                      │
  │                                                                                      │
  │  {"model":"claude-sonnet-4-20250514","messages":[...]}                              │
  └─────────────────────────────────────────────────────────────────────────────────────┘
```

## Migration Path

### v1.0 → v1.1
- Add correlation headers support
- Add task lifecycle detection with candidate state machine
- Add layered candidate dismissal (auto-confirm, header, endpoint)
- Add `/task/*` endpoints including `/task/dismiss` and `/task/candidate`
- Add `origin` field to all events (alongside `tool`)
- Add `start_method` and `dismiss_method` fields for task events
- Add local prompt storage for task naming

### v1.1 → v1.2
- Add baseline estimation
- Add Aethyme integration for context packs
- Add Mockup event ingestion

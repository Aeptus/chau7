# Token Reduction Platform - v1.1 Deployment Assessment

> Generated from SPEC-Token-Reduction-Platform.md analysis

## Executive Summary

The Chau7 Token Reduction Platform has **v1.0 fully implemented**. Deploying v1.1 requires implementing **task lifecycle management** in both the Go proxy and Swift UI.

**Estimated effort:** 3-4 weeks for one developer

---

## Current State (v1.0) ✅ COMPLETE

### Go Proxy - Implemented Features
| Feature | Status | Location |
|---------|--------|----------|
| Token accounting (Anthropic, OpenAI, Gemini) | ✅ | `metadata.go` |
| Cost calculation (50+ models) | ✅ | `pricing.go` |
| SQLite persistence with WAL mode | ✅ | `db.go` |
| IPC event emission | ✅ | `ipc.go` |
| Provider detection & routing | ✅ | `router.go` |
| Health & stats endpoints | ✅ | `main.go` |
| Session correlation header | ✅ | `proxy.go` |

### Swift/Chau7 - Implemented Features
| Feature | Status | Location |
|---------|--------|----------|
| Proxy process management | ✅ | `Proxy/ProxyManager.swift` |
| IPC event reception | ✅ | `Proxy/ProxyIPCServer.swift` |
| API call event model | ✅ | `Proxy/APICallEvent.swift` |
| Environment variable injection | ✅ | `TerminalSessionModel.swift:931-948` |
| Proxy settings UI | ✅ | `SettingsViews/ProxySettingsView.swift` |

---

## v1.1 Required Work

### Go Proxy Work Items

#### 1. Correlation Headers Parsing (Small - < 1 day)
**File:** New `headers.go`, modify `proxy.go`

Parse additional headers from incoming requests:
```
X-Chau7-Tab          - Tab/terminal identifier
X-Chau7-Project      - Git root or project path
X-Chau7-Task         - Existing task ID (if known)
X-Chau7-Task-Name    - Override auto-derived name
X-Chau7-New-Task     - Force new task immediately
X-Chau7-Dismiss-Candidate - Dismiss pending candidate
X-Chau7-Tenant       - Tenant ID (multi-tenant)
X-Chau7-Org          - Organization ID
X-Chau7-User         - User ID (hashed)
```

#### 2. Task State Machine (Medium - 1-3 days)
**File:** New `task.go`

Implement state machine:
```
[No Task] ──manual──▶ [Active] ──assess──▶ [Completed]
     │                    │
     └──trigger──▶ [Candidate] ──grace_period──▶ [Active]
                       │                            │
                       └──dismiss──▶ [No Task]      └──timeout──▶ [Abandoned]
```

Task triggers (priority order):
1. Manual: `X-Chau7-New-Task: true` header
2. New session: New `X-Chau7-Session` value
3. Idle gap: Last activity > 30 minutes
4. Repo switch: `X-Chau7-Project` changes

#### 3. Task HTTP Endpoints (Small - < 1 day)
**File:** New `task_endpoints.go`, modify `main.go`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/task/candidate` | GET | Get pending candidate (if any) |
| `/task/start` | POST | Force start new task |
| `/task/dismiss` | POST | Dismiss pending candidate |
| `/task/assess` | POST | Submit task assessment |
| `/task/current` | GET | Get current task state |
| `/events` | GET | Paginated event history |

#### 4. Provisional Call Assignment (Medium - 1-3 days)
**File:** Modify `task.go`, `db.go`

- Track API calls made during candidate grace period
- Reassign calls if candidate is dismissed
- Handle edge case of first-call timing

#### 5. Task Naming from Prompt (Small - < 1 day)
**File:** Modify `task.go`

- Extract verb phrase or first 6-10 words from prompt
- Store prompt locally only (never transmitted to cloud)
- Support `X-Chau7-Task-Name` header override

#### 6. Database Schema Migration (Small - < 1 day)
**File:** Modify `db.go`

```sql
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

-- Add columns to existing table
ALTER TABLE api_calls ADD COLUMN task_id TEXT;
ALTER TABLE api_calls ADD COLUMN tab_id TEXT;
ALTER TABLE api_calls ADD COLUMN project_path TEXT;

CREATE INDEX IF NOT EXISTS idx_api_calls_task ON api_calls(task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_tab ON tasks(tab_id);
```

#### 7. Event Schema Updates (Small - < 1 day)
**File:** Modify `ipc.go`

Add new event types:
- `task_candidate` - Heuristic trigger detected
- `task_started` - Task began (auto-confirmed or manual)
- `task_candidate_dismissed` - User dismissed candidate
- `task_assessment` - Approval or failure recorded

Add fields to all events:
- `origin` - Emitting system (future-proofing)
- `start_method` - How task started
- `dismiss_method` - How candidate was dismissed

---

### Swift/Chau7 Work Items

#### 1. Task Candidate UI (Medium - 1-3 days)
**Files:** New `Proxy/TaskCandidate.swift`, `Proxy/TaskCandidateView.swift`

- Toast/banner component for candidate notification
- Confirm/dismiss buttons
- Grace period countdown display
- Auto-dismiss after grace period

#### 2. Task Assessment UI (Medium - 1-3 days)
**File:** New `Proxy/TaskAssessmentView.swift`

- Success/failure buttons
- Optional note field
- Display task statistics (tokens, cost, duration)

#### 3. Header Injection Enhancement (Small - < 1 day)
**File:** Modify `TerminalSessionModel.swift`

Add to `shellEnvironment()` after line 947:
```swift
dict["CHAU7_TAB_ID"] = tabIdentifier
dict["CHAU7_PROJECT"] = currentDirectory  // git root or cwd
```

#### 4. IPC Handler Updates (Small - < 1 day)
**File:** Modify `Proxy/ProxyIPCServer.swift`

Handle new event types:
```swift
case "task_candidate":
    handleTaskCandidate(message)
case "task_started":
    handleTaskStarted(message)
case "task_candidate_dismissed":
    handleTaskDismissed(message)
case "task_assessment":
    handleTaskAssessment(message)
```

#### 5. Terminal Tab Integration (Medium - 1-3 days)
**File:** Modify `TerminalTabView.swift`

- Integrate candidate banner overlay
- Integrate assessment panel overlay
- Wire up to IPC events

---

## ⚠️ BLOCKER: CLI Header Injection

**Problem:** How does Claude Code (or other CLI tools) send `X-Chau7-*` headers to the proxy?

**Options:**
1. **Environment-to-header mapping** - CLI reads env vars and adds headers (requires CLI modification)
2. **Proxy injects from env** - Not possible (HTTP requests don't carry parent process env)
3. **Shell wrapper** - Most portable, no CLI changes needed ✅ RECOMMENDED

**Recommended Solution:**
```bash
# Injected by Chau7 into .zshrc / .bashrc via shell integration
claude() {
    command claude "$@" \
        --header "X-Chau7-Session: ${CHAU7_SESSION_ID:-}" \
        --header "X-Chau7-Tab: ${CHAU7_TAB_ID:-}" \
        --header "X-Chau7-Project: ${CHAU7_PROJECT:-}"
}
```

**Alternative** (if Claude Code respects env vars):
```bash
export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:$CHAU7_SESSION_ID,X-Chau7-Tab:$CHAU7_TAB_ID"
```

**Action Required:** Investigate Claude Code documentation for header injection support.

---

## Effort Summary

### v1.1 Implementation Matrix

| Component | Feature | Effort | Priority |
|-----------|---------|--------|----------|
| Proxy | Correlation headers | S | P0 |
| Proxy | Task state machine | M | P0 |
| Proxy | Database migration | S | P0 |
| Proxy | Task endpoints | S | P0 |
| Proxy | Provisional call assignment | M | P1 |
| Proxy | Task naming | S | P1 |
| Proxy | Event schema updates | S | P1 |
| Chau7 | Header injection | S | P0 |
| Chau7 | IPC handler updates | S | P0 |
| Chau7 | Task candidate UI | M | P1 |
| Chau7 | Task assessment UI | M | P1 |
| Chau7 | Terminal tab integration | M | P1 |

**Effort Key:**
- S (Small): < 1 day
- M (Medium): 1-3 days
- L (Large): 1-2 weeks

**Total v1.1 Estimate:** 3-4 weeks (1 developer)

---

## Recommended Implementation Order

### Phase 1: Foundation (Week 1)
1. Proxy: Correlation headers parsing
2. Proxy: Database schema migration
3. Proxy: Task state machine (basic)
4. Swift: Header injection enhancement

### Phase 2: Core Features (Week 2)
5. Proxy: Task HTTP endpoints
6. Proxy: Event schema updates
7. Swift: IPC handler updates
8. Investigate CLI header injection blocker

### Phase 3: UI Integration (Week 3)
9. Swift: Task candidate data model
10. Swift: Task candidate UI component
11. Swift: Task assessment UI component
12. Swift: Terminal tab integration

### Phase 4: Polish & Testing (Week 4)
13. Proxy: Provisional call assignment
14. Proxy: Task naming from prompt
15. End-to-end testing
16. Documentation updates

---

## v1.2 Future Work (Not for Immediate Deployment)

| Component | Feature | Effort |
|-----------|---------|--------|
| Proxy | Baseline estimation | L (1-2 weeks) |
| Proxy | Aethyme API client | M (1-3 days) |
| Aethyme | Context pack API | M (1-3 days) |
| Mockup | Event ingestion | M (1-3 days) |
| Mockup | Analytics dashboard | L (1-2 weeks) |

**Total v1.2 Estimate:** 6-8 weeks (1 developer, or parallel with multiple)

---

## Files Reference

### Go Proxy Files to Create
```
chau7-proxy/
├── task.go              # Task struct, state machine, triggers
├── task_endpoints.go    # /task/* HTTP handlers
├── task_test.go         # Tests for task lifecycle
└── headers.go           # Parse X-Chau7-* correlation headers
```

### Go Proxy Files to Modify
```
chau7-proxy/
├── db.go                # Add tasks, task_assessments tables
├── ipc.go               # Add new event types
├── main.go              # Register new endpoints
└── proxy.go             # Extract correlation headers
```

### Swift Files to Create
```
Sources/Chau7/Proxy/
├── TaskCandidate.swift        # Task candidate data model
├── TaskCandidateView.swift    # Banner/toast UI component
└── TaskAssessmentView.swift   # Success/failure buttons
```

### Swift Files to Modify
```
Sources/Chau7/
├── Proxy/ProxyIPCServer.swift     # Handle new event types
├── TerminalSessionModel.swift     # Add tab_id, project injection
└── TerminalTabView.swift          # Add candidate/assessment overlays
```

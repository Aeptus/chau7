# Proxy

API analytics proxy managing a Go subprocess, Unix socket IPC, and task lifecycle tracking.

## Files

| File | Purpose |
|------|---------|
| `APICallEvent.swift` | Model for captured API calls with provider, tokens, latency, cost, and status |
| `ProxyIPCServer.swift` | Unix socket server receiving real-time API call notifications from the proxy |
| `ProxyManager.swift` | Manages the chau7-proxy Go binary lifecycle (start/stop/restart) |
| `TaskAssessmentView.swift` | Panel for assessing task completion (approve/fail with optional notes) |
| `TaskCandidate.swift` | Model for pending task candidates detected from API activity |
| `TaskCandidateView.swift` | Banner view for confirming or dismissing detected task candidates |

## Key Types

- `ProxyManager` — singleton managing the chau7-proxy subprocess and port configuration
- `ProxyIPCServer` — singleton Unix socket server broadcasting API call events
- `APICallEvent` — Codable model for LLM API usage tracking (tokens, cost, latency)
- `TaskCandidate` — model for task lifecycle events with grace period and confidence

## Dependencies

- **Uses:** Logging, Settings
- **Used by:** Analytics, Settings/Views, Overlay

# Dashboard

Swift: `apps/chau7-macos/Sources/Dashboard/`
Swift tests: see each row
Wave: 3
Depends on: Repository, Runtime, Telemetry

Repository-scoped agent dashboard, separate from the historical terminal analytics dashboard.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| DSH-001 | Repository dashboard tab with agent count, total tokens/cost, proxy health, overall approval/conflict status and empty state | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardTypesTests |  | missing |  |
| DSH-002 | Cards include managed runtime and detected live terminal agents; show backend, purpose, delegation parent/depth/children, state, turns, tool, files, cache token breakdown and latest result | `Dashboard/AgentDashboardSessionController.swift`; `Dashboard/AgentDashboardTypes.swift` | AgentDashboardTypesTests |  | missing |  |
| DSH-003 | Start agent sheet chooses Claude/Codex, optional model and prompt, auto-approval; launch in repository and switch to its tab | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardLaunchTests |  | missing |  |
| DSH-004 | Stop one or all agents, switch to agent tab, commit one agent or all agent-touched files with editable message and success/error feedback | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` | AgentDashboardLaunchTests |  | missing |  |
| DSH-005 | File-conflict section distinguishes shared touched files and files modified concurrently in current turns | `Dashboard/AgentDashboardModel.swift`; `SplitPanes/SessionFilesTracker.swift` | FileTrackingModelsTests |  | missing |  |
| DSH-006 | Repository event timeline with stable session:sequence IDs, state/tool/approval icons and Show more pagination | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` | AgentDashboardTypesTests |  | missing |  |
| DSH-007 | Detect companion Markdown plans, display checkbox progress and open the selected plan beside the dashboard | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` |  |  | missing |  |
| DSH-008 | Code review sheet selects parent agent, base/head commits, model/instructions and launches a delegated reviewer with structured findings | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardLaunchTests; CodeReviewTaskTemplateTests |  | missing |  |

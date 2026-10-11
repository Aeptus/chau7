# Dashboard

Swift: `apps/chau7-macos/Sources/Dashboard/`
Swift tests: see each row
Wave: 3
Depends on: Repository, Runtime, Telemetry

Repository-scoped agent dashboard, separate from the historical terminal analytics dashboard.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| DSH-001 | Repository dashboard tab with agent count, total tokens/cost, proxy health, overall approval/conflict status and empty state | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardTypesTests | chau7_next/src/panes/dashboard.rs; chau7_next_core/src/dashboard.rs | done |  |
| DSH-002 | Cards include managed runtime and detected live terminal agents; show backend, purpose, delegation parent/depth/children, state, turns, tool, files, cache token breakdown and latest result | `Dashboard/AgentDashboardSessionController.swift`; `Dashboard/AgentDashboardTypes.swift` | AgentDashboardTypesTests | chau7_next/src/panes/dashboard.rs; chau7_next_core/src/runtime/session.rs; chau7_next_core/src/dashboard.rs | done |  |
| DSH-003 | Start agent sheet chooses Claude/Codex, optional model and prompt, auto-approval; launch in repository and switch to its tab | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardLaunchTests | chau7_next/src/panes/dashboard.rs; chau7_next/src/runtime/control.rs | done |  |
| DSH-004 | Stop one or all agents, switch to agent tab, commit one agent or all agent-touched files with editable message and success/error feedback | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` | AgentDashboardLaunchTests | chau7_next/src/panes/dashboard.rs; chau7_next_core/src/dashboard.rs | done |  |
| DSH-005 | File-conflict section distinguishes shared touched files and files modified concurrently in current turns | `Dashboard/AgentDashboardModel.swift`; `SplitPanes/SessionFilesTracker.swift` | FileTrackingModelsTests | chau7_next_core/src/dashboard.rs; chau7_next/src/panes/dashboard.rs | done |  |
| DSH-006 | Repository event timeline with stable session:sequence IDs, state/tool/approval icons and Show more pagination | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` | AgentDashboardTypesTests | chau7_next_core/src/dashboard.rs; chau7_next/src/panes/dashboard.rs; chau7_next/src/assets.rs | done |  |
| DSH-007 | Detect the preferred companion Markdown plan, display checkbox progress and open it beside the real dashboard pane | `Dashboard/AgentDashboardModel.swift`; `Dashboard/AgentDashboardView.swift` |  | chau7_next_core/src/dashboard.rs; chau7_next_core/src/editor/markdown.rs; chau7_next/src/panes/dashboard.rs; chau7_next/src/pane.rs | done |  |
| DSH-008 | Code review sheet selects parent agent, base/head commits, model/instructions and launches a delegated reviewer with structured findings | `Dashboard/AgentDashboardView.swift`; `Dashboard/AgentDashboardModel.swift` | AgentDashboardLaunchTests; CodeReviewTaskTemplateTests | chau7_next_core/src/runtime/code_review.rs; chau7_next/src/panes/dashboard.rs; chau7_next/src/runtime/control.rs | done |  |

## Current source and validation evidence

- The group overlay and the persistent Dashboard pane share the same real scoped controller (`panes/dashboard.rs`). Cards merge actual registered terminal sessions with managed runtime sessions; absent token/cost evidence remains unavailable. Empty saved scopes restore an empty dashboard, rather than a fabricated terminal or workspace.
- Starting an agent or delegated reviewer now selects the valid returned tab UUID. The launch reply regressions reject error responses, malformed UUIDs and non-launch replies; the underlying runtime creation deliberately starts background MCP tabs, so selection is a Dashboard responsibility.
- The timeline retains stable `session:seq` identities, real backend labels and current tool/turn/approval/state icons. Four core regressions cover identity across refresh, numeric sequence ordering, message evidence, the 200-entry cap and icon categories; the application asset regression verifies every icon is actually embedded. Pagination remains 50 entries at a time.
- Current Swift `detectedPlanFiles` is an internal candidate list, not a visible plan-choice picker. Next selects the preferred existing plan using touched paths or the single-session companion, imports it read-only into Next-owned state, counts real Markdown checkboxes outside fenced code, and opens it once after the scoped snapshot arrives. The pane tree reuses an already open editor and retains its external-change/conflict guard.
- Existing core regressions cover repository boundaries, deterministic session selection, approval/conflict status precedence, current-turn conflicts, incremental file tracking, literal Git path containment and preservation of unrelated staged files. Structured review templates and actual runtime result/delegation contracts remain shared with Runtime.
- The polling task is owned by the real Dashboard entity, exposes timer diagnostics, pauses refresh while its pane/tab or window is hidden, survives moving the pane to another window, and ends when the entity is dropped. Persistent-pane serialization tests cover scopes, absent scopes and duplicate IDs alongside repository, editor and terminal leaves.
- DSH-003 and DSH-008 create ordinary tabs through a private trusted UI origin. External MCP enabled/approval/tab-limit settings do not gate explicit Dashboard launches. Two actual creation-rule regressions cover disabled MCP and preserved external approval/limits; external connections cannot spoof the private origin. UI-created tabs are not marked MCP-controlled and prefer the active window. Native click acceptance remains pending below.
- Native visual and relaunch acceptance is still to be performed on the coordinator's isolated macOS instance. These status labels describe implemented source behavior, not a claim that all UI actions have already been hand-tested.

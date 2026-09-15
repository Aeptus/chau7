# StatusBar

Menu bar status item with popover panel.

## Files

| File | Purpose |
|------|---------|
| `StatusBarController.swift` | Manages NSStatusItem, NSPopover, and global/local event monitors for the menu bar icon |
| `StatusBarIconPresenter.swift` | Pure status item rendering decisions: SF Symbol, title count, accessibility label, and tooltip |
| `StatusBarPanelView.swift` | SwiftUI popover content, quick actions, live sessions, and footer |
| `CommandCenterEnvironment.swift` | Injected command-center data sources and side-effect actions |
| `CommandCenterSessionPresentation.swift` | Pure per-session row presentation decisions: SF Symbol, label, tone, and attention flag |
| `CommandCenterViewModel.swift` | Popover state, badge counts, refresh timer, and user actions |
| `CommandCenterSessionSummary.swift` | Live AI session summary model and collection from overlay tabs |
| `CommandCenterTimeline.swift` | Unified activity timeline entry model and event/history mapping |

## Key Types

- `StatusBarController` — singleton managing the menu bar status item and popover lifecycle
- `StatusBarIconPresenter` — pure badge/icon presentation policy consumed by `StatusBarController`
- `StatusBarPanelView` — SwiftUI menu bar popover content
- `CommandCenterEnvironment` — injectable bridge to app/window/session services
- `CommandCenterSessionPresentation` — pure presentation mapping for action-list session states
- `CommandCenterViewModel` — state and actions shared across popover open/close cycles
- `CommandCenterSessionSummary` — AI-agnostic live session summary used by the command center
- `UnifiedTimelineEntry` — merged notification history and recent-event timeline item

## Ownership Boundaries

- `StatusBarController` is the only type that mutates `NSStatusItem`, `NSPopover`, and AppKit event monitors.
- `StatusBarIconPresenter` and `CommandCenterSessionPresentation` stay pure and testable; they do not import AppKit or hold UI objects.
- `CommandCenterViewModel` owns derived popover state, but all app side effects go through `CommandCenterEnvironment`.
- `CommandCenterEnvironment.production` may talk to `AppDelegate`, overlay windows, pasteboard, snippets, and notification history. Tests should use `.testing(...)`.
- `StatusBarPanelView` renders the current model and invokes view-model actions. It should not discover windows, sessions, notification stores, or settings windows directly.

## Session State

Command center session state preserves approval-required separately from generic waiting input. Badge counts follow `TabAttentionKind` priority: approval-required sessions win over waiting-input sessions, so the menu bar count answers the highest-priority unresolved action.

Stuck sessions are shown in the action list with their own warning presentation, but they do not increment the attention badge. They represent visible risk/context, not an explicit user action.

## Settings Routing

Status panel settings actions must use routed intents:

- Monitoring opens `SettingsSection.notifications` with anchor `eventMonitoring`.
- Pinned snippets opens `SettingsSection.snippetsTools` with anchor `snippets`.
- Footer Settings opens `SettingsSection.startHere`.

Use `CommandCenterViewModel.openMonitoringSettings()`, `openPinnedSnippetSettings()`, and `openDefaultSettings()` rather than calling the environment route directly from SwiftUI.

## Regression Coverage

Phase 8 coverage lives in `Tests/Chau7Tests/StatusBar/` and should remain in place when changing this feature:

- multi-window session collection through `CommandCenterSessionSummary.collectLiveSessions(in:)`
- approval, waiting-input, running, and stuck row presentation through `CommandCenterSessionPresentation`
- badge/icon behavior through `StatusBarIconPresenter`
- timeline formatting/dedup through `CommandCenterViewModel.unifiedTimeline(...)`
- snippet insertion and clipboard fallback through `CommandCenterViewModel.executeSnippet(...)`
- settings routing through injected `CommandCenterEnvironment.openSettings`

## Manual Smoke Checklist

Before shipping status bar changes, inspect:

- monitoring on/off hero text and icon state
- multiple Chau7 windows with live AI sessions
- approval-required session badge and action row
- pinned snippets inserted into a focused terminal and copied fallback when no active terminal exists
- settings buttons land on Monitoring, Snippets & Tools, and Start Here
- popover dismissal after focusing sessions, opening settings, and successful snippet insertion

## Dependencies

- **Uses:** App, Settings, Overlay, Terminal, Snippets, Notifications, Localization
- **Used by:** App

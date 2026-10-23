# Chau7Core

Pure Swift library with zero UI dependencies. Contains all testable business logic, parsers, and domain types.

## What belongs here

- Domain types: `AIEvent`, `TerminalKeyPress`, `CommandBlock`, `HistoryRecord`
- Parsers: `ConfigFileParser`, `SSHConfigParser`, `FrameParser`, `EscapeSequenceSanitizer`
- Detection: `AIDetectionState`, `CommandDetection`, `AIToolRegistry`, `AIResumeParser`
- Notification model: `CanonicalNotificationEvent`, `NotificationIngress`, provider adapters
- Runtime: `EventJournal`, `RuntimeSessionState`, `AgentBackend` protocol
- Telemetry: `TelemetryRun`, `TelemetryTurn`, `TokenMetrics`
- Utilities: `SubprocessRunner`, `ShellEscaping`, `DateFormatters`

## What does NOT belong here

- Anything that imports AppKit, SwiftUI, or Metal
- Singleton managers (those live in the Chau7 app target)
- View models or UI state

## Testing

All 1100+ tests in `Tests/Chau7Tests/` test this target via `@testable import Chau7Core`.

```bash
cd apps/chau7-macos && swift test
```

## Key types

| Type | Purpose |
|------|---------|
| `AIEvent` | Canonical cross-tool event (all monitors produce these) |
| `AIToolRegistry` | Single source of truth for AI tool identity |
| `AIDetectionState` | State machine for detecting which AI tool is running |
| `NotificationIngress` | Entry point for the notification pipeline |
| `RuntimeSessionState` | State machine for managed AI agent sessions |
| `CommandDetection` | Pattern matching for shell commands |

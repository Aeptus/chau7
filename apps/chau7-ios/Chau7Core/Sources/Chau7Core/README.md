# Chau7Core

Pure Swift library with zero UI dependencies, used by the iOS remote app, its widget and their tests. It started as the shared core of the former Swift macOS app, so it still contains logic that only that app used.

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
- Singleton managers (those live in the app targets)
- View models or UI state

## Testing

The tests in `Tests/Chau7CoreTests/` of this package exercise the target via `@testable import Chau7Core`.

```bash
swift test --package-path apps/chau7-ios/Chau7Core
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

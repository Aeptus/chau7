# Notifications

Event-driven notification pipeline: detection → evaluation → actions.

## Files

| File | Purpose |
|------|---------|
| `NotificationManager.swift` | Central manager: coalescing, pipeline evaluation, native notification dispatch |
| `NotificationPipeline.swift` | Decision engine: trigger matching, condition evaluation, action binding |
| `NotificationActionExecutor.swift` | Action runner: show notification, play sound, dock bounce, style tab |
| `TabResolver.swift` | 5-tier tab resolution: exact ID → session ID → brand → title → CWD fallback |

## Event Flow

```
Source (shell/AI/hooks) → AIEvent → NotificationManager.notify()
  → enqueue + coalesce (0.25s window)
  → NotificationPipeline.evaluate() → Decision (.drop / .fireDefault / .fireActions)
  → NotificationActionExecutor → native notification + tab styling + sound + dock bounce
```

## Key Patterns

- All resolvers search ALL windows via `TerminalControlService.allTabs`
- `onlyWhenTabInactive` (default) suppresses notifications for the selected tab
- Tab styles have 30s auto-clear; `.persistent` styles require manual clearing

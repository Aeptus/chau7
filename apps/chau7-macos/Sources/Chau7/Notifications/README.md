# Notifications

Notification delivery, action execution, and trigger localization.

## Files

| File | Purpose |
|------|---------|
| `NotificationActionExecutor.swift` | Executes notification actions (focus tab, set badge, run snippet, style tab) |
| `NotificationManager.swift` | Manages UNUserNotificationCenter authorization and notification delivery |
| `NotificationTriggerLocalization.swift` | Localization extensions for notification trigger labels and descriptions |

## Key Types

- `NotificationManager` — singleton handling native notification delivery with authorization tracking
- `NotificationActionExecutor` — singleton executing actions from notification triggers (focus, badge, style)

## Dependencies

- **Uses:** Logging, Settings, Localization, Snippets
- **Used by:** App, Overlay, Monitoring, Settings/Views

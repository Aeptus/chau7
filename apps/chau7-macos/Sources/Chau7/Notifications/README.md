# Notifications

Notification delivery, tab routing, action execution, and trigger localization.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. The notification and tab-routing pipeline never references specific AI tools by name. `TabResolver` derives all tool aliases from `AIToolRegistry` and dispatches CWD-based lookups through a closure registry populated by tool monitors at startup. Adding a new AI backend requires zero changes here.

## Files

| File | Purpose |
|------|---------|
| `TabResolver.swift` | Stateless, tool-agnostic tab routing: resolves which tab an `AIEvent` should target via 4 fallback tiers (brand → title → deep scan → registered CWD resolver) |
| `NotificationActionExecutor.swift` | Executes notification actions (focus tab, set badge, run snippet, style tab) |
| `NotificationManager.swift` | Manages UNUserNotificationCenter authorization and notification delivery |
| `NotificationTriggerLocalization.swift` | Localization extensions for notification trigger labels and descriptions |

## Key Types

- `TabResolver` — caseless enum with stateless static methods for tab routing. Tool monitors register CWD resolvers via `registerCWDResolver(forProviderKey:resolver:)` — TabResolver itself has no knowledge of specific tools.
- `NotificationManager` — singleton handling native notification delivery with authorization tracking
- `NotificationActionExecutor` — singleton executing actions from notification triggers (focus, badge, style)

## Dependencies

- **Uses:** Logging, Settings, Localization, Snippets, Chau7Core (AIToolRegistry, AIResumeParser)
- **Used by:** App, Overlay, Monitoring, Settings/Views

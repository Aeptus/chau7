# Events

App-level event emission for the notification system (scheduled, inactivity, memory).

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. Events flow through the generic `AIEvent` type and are routed by `TabResolver` without knowledge of specific AI backends.

## Files

| File | Purpose |
|------|---------|
| `AIEventPublishing.swift` | Narrow event publishing protocol used by event detectors/emitters instead of depending on `AppModel` directly |
| `AppEventEmitter.swift` | Emits scheduled, inactivity, and memory threshold events for notification triggers |

## Key Types

- `AIEventPublishing` — app-layer abstraction for publishing `AIEvent` records into the unified pipeline
- `AppEventEmitter` — manages timers for scheduled events, inactivity detection, and memory monitoring

## Dependencies

- **Uses:** App, Settings, Notifications
- **Used by:** App, Monitoring

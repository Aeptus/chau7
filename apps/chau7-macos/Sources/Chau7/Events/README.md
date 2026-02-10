# Events

App-level event emission for the notification system (scheduled, inactivity, memory).

## Files

| File | Purpose |
|------|---------|
| `AppEventEmitter.swift` | Emits scheduled, inactivity, and memory threshold events for notification triggers |

## Key Types

- `AppEventEmitter` — manages timers for scheduled events, inactivity detection, and memory monitoring

## Dependencies

- **Uses:** App, Settings, Notifications
- **Used by:** App, Monitoring

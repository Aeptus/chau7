# App

Application entry point, delegate, and top-level model managing state, monitoring, and notifications.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. `AppModel` starts all tool monitors and registers their CWD resolvers with `TabResolver` during setup, but the event pipeline, tab routing, and notification system operate generically via `AIEvent` and `AIToolRegistry`. No downstream subsystem should reference a specific AI backend by name.

## Files

| File | Purpose |
|------|---------|
| `AppConstants.swift` | Centralized magic numbers and configuration limits (buffer sizes, timeouts) |
| `AppDelegate.swift` | NSApplicationDelegate handling window management, hotkeys, and overlay lifecycle |
| `AppIcon.swift` | Loads the app icon from bundle or Resources folder for dock/splash display |
| `AppModel.swift` | Main ObservableObject managing monitoring state, sessions, and notifications. Registers tool monitors at startup. |
| `Chau7App.swift` | SwiftUI `@main` App struct wiring AppModel, OverlayTabsModel, and menus |

## Key Types

- `AppModel` — central state model for monitoring, sessions, and notification handling
- `AppDelegate` — handles window events, global hotkeys, overlay windows, and fullscreen
- `AppConstants` — enum namespacing all buffer limits and configuration defaults

## Dependencies

- **Uses:** Overlay, Terminal, Monitoring, Notifications, Settings, Profiles
- **Used by:** StatusBar, Debug, Settings/Views, Views

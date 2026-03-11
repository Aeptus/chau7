# Overlay

Main overlay window, tab management model, fullscreen behavior, and titlebar styling.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. Tab management and session display use `AIToolRegistry` for tool identity and `AIEvent` for the event pipeline — never hardcoding behavior for a specific AI backend.

## Files

| File | Purpose |
|------|---------|
| `Chau7OverlayView.swift` | Primary SwiftUI overlay view with toolbar, tab strip, and terminal content |
| `FullscreenToolbarController.swift` | Manages fullscreen presentation options and toolbar visibility |
| `OverlayTabsModel.swift` | Core tab management model handling tab creation, switching, styling, and lifecycle |
| `OverlayWindow.swift` | Custom NSWindow subclass with fullscreen support and key/main handling |
| `TitlebarBackgroundInstaller.swift` | Installs a vibrancy effect behind the native titlebar |

## Key Types

- `OverlayTabsModel` — main ObservableObject managing all terminal tabs, sessions, and notification styles
- `OverlayWindow` — NSWindow subclass configured for fullscreen with collection behaviors
- `FullscreenToolbarController` — handles fullscreen transitions and toolbar auto-hide behavior

## Dependencies

- **Uses:** Terminal, Settings, Appearance, Commands, Keyboard, Snippets, Notifications, Monitoring, AI, SplitPanes, Remote
- **Used by:** App, Debug, StatusBar

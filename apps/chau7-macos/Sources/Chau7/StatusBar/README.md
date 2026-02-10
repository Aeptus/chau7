# StatusBar

Menu bar status item with popover panel and standalone settings window.

## Files

| File | Purpose |
|------|---------|
| `MainPanelView.swift` | Popover panel view with stream selection, settings window wrapper, and history display |
| `StatusBarController.swift` | Manages NSStatusItem, NSPopover, and global/local event monitors for the menu bar icon |

## Key Types

- `StatusBarController` — singleton managing the menu bar status item and popover lifecycle
- `SettingsWindowView` — wrapper view for the standalone settings window (Cmd+,)
- `StreamSelection` — enum for selecting which log/terminal stream to display in the panel

## Dependencies

- **Uses:** App, Settings, Overlay, Terminal/Views, Localization
- **Used by:** App

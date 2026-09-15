# Appearance

Theming, color schemes, and visual mode management for the terminal UI.

## Files

| File | Purpose |
|------|---------|
| `AppTheme.swift` | Enum for system/light/dark app-wide theme selection |
| `MinimalMode.swift` | Manages minimal mode that hides non-essential UI chrome for maximum terminal space |
| `TabColor.swift` | Predefined tab color palette (blue, teal, green, etc.) |
| `TerminalColorScheme.swift` | macOS `NSColor` conversion + caching for `TerminalColorScheme` (the pure-data struct lives in `Chau7Core`, shared with the iOS remote app) |

## Key Types

- `TerminalColorScheme` — Codable struct (defined in `Chau7Core`) defining all terminal colors; this module adds hex-to-`NSColor` caching accessors
- `MinimalMode` — singleton ObservableObject toggling UI element visibility
- `AppTheme` — enum for system, light, and dark theme selection

## Dependencies

- **Uses:** Logging, Chau7Core
- **Used by:** Settings, Settings/Views, Terminal/Rendering, Overlay

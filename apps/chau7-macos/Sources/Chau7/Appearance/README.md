# Appearance

Theming, color schemes, and visual mode management for the terminal UI.

## Files

| File | Purpose |
|------|---------|
| `AppTheme.swift` | Enum for system/light/dark app-wide theme selection |
| `MinimalMode.swift` | Manages minimal mode that hides non-essential UI chrome for maximum terminal space |
| `TabColor.swift` | Predefined tab color palette (blue, teal, green, etc.) |
| `TerminalColorScheme.swift` | Full terminal color scheme model with 16 ANSI colors plus bg/fg/cursor/selection |

## Key Types

- `TerminalColorScheme` — Codable struct defining all terminal colors with hex-to-NSColor caching
- `MinimalMode` — singleton ObservableObject toggling UI element visibility
- `AppTheme` — enum for system, light, and dark theme selection

## Dependencies

- **Uses:** Logging
- **Used by:** Settings, Settings/Views, Terminal/Rendering, Overlay

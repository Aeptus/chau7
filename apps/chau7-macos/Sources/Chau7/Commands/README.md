# Commands

Command palette, dangerous command interception, and path click handling.

## Files

| File | Purpose |
|------|---------|
| `CommandPalette.swift` | Fuzzy-search command palette UI (like VS Code's Cmd+Shift+P) |
| `DangerousCommandConfirmationView.swift` | Confirmation dialog shown when a dangerous command is detected |
| `DangerousCommandGuard.swift` | Intercepts Enter keystrokes that match risky command patterns |
| `PathClickHandler.swift` | Handles Cmd+Click on file paths and URLs in terminal output |

## Key Types

- `DangerousCommandGuard` — singleton that delays Enter delivery for risky commands until confirmed
- `PaletteCommand` — model for a single command palette entry with title, shortcut, and action
- `PathClickHandler` — static utility detecting file paths with optional line:column in terminal text

## Dependencies

- **Uses:** Logging, Settings, Utilities (RegexPatterns)
- **Used by:** Overlay, Terminal/Session, Settings/Views

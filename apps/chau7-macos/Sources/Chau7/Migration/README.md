# Migration

Profile import from Terminal.app and iTerm2, plus launch-at-login plist management.

## Files

| File | Purpose |
|------|---------|
| `LaunchAtLoginManager.swift` | Installs/removes the macOS LaunchAgent plist for launch-at-login without loading it in the current session |
| `TerminalMigrationWizard.swift` | Scans and imports profiles from Terminal.app and iTerm2 plist files |
| `TerminalMigrationWizardView.swift` | Step-by-step wizard UI for selecting and importing detected profiles |

## Key Types

- `TerminalMigrationWizard` — ObservableObject that detects and imports profiles from other terminals
- `LaunchAtLoginManager` — static utility for installing/removing a LaunchAgent plist
- `TerminalMigrationWizardView` — multi-step SwiftUI wizard (welcome, scan, select, import, complete)

## Dependencies

- **Uses:** Logging, Appearance (TerminalColorScheme)
- **Used by:** Settings/Views

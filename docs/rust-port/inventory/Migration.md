# Migration

Swift: `apps/chau7-macos/Sources/Chau7/Migration/` (3 files, 679 lines)
Swift tests: `Migration/TerminalMigrationTests`
Wave: 5 (see README.md)
Depends on: Settings (profiles), Profiles

Two unrelated things: Launch at Login (a LaunchAgent the app installs for
itself), and a wizard that imports Terminal.app and iTerm2 profiles as Chau7
settings profiles.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| MIG-001 | Launch at Login switch (Settings > General): on writes `~/Library/LaunchAgents/<bundle id>.plist` (RunAtLoad, no KeepAlive) and loads it with `launchctl bootstrap` (falls back to `load -w`); off boots it out and deletes the file | `Migration/LaunchAtLoginManager.swift`, `Settings/FeatureSettings.swift` (`launchAtLogin`), `Settings/Views/GeneralSettingsView.swift` |  | chau7_next/src/platform/login_item.rs (SMAppService) | done | LaunchAgent, launchctl |
| MIG-002 | The Launch at Login switch starts from the real state: on if the job is loaded or the plist exists, when the user never set it | `Migration/LaunchAtLoginManager.swift` (`isEnabled`), `Settings/FeatureSettings.swift` |  | chau7_next/src/platform/login_item.rs (SMAppService) | done | launchctl |
| MIG-003 | Find Terminal.app profiles: font family and size, background and text colors, cursor shape, columns and rows, startup command | `Migration/TerminalMigrationWizard.swift` (`scanTerminalApp`) | `TerminalMigrationTests` | chau7_next_core/src/terminal_import.rs | done | NSKeyedUnarchiver (NSFont, NSColor) |
| MIG-004 | Find iTerm2 profiles: font family and size, background and foreground colors, command, working directory | `Migration/TerminalMigrationWizard.swift` (`scanITerm2`) | `TerminalMigrationTests` | chau7_next_core/src/terminal_import.rs | done |  |
| MIG-005 | Import selected profiles as Chau7 settings profiles named "Imported: <name>", carrying font family, font size and cursor style; current settings are left unchanged | `Migration/TerminalMigrationWizard.swift` (`importProfiles`) |  | chau7_next/src/migration/, chau7_next_core/src/terminal_import.rs | done |  |
| MIG-006 | Import wizard: Welcome (Terminal.app and iTerm2), Scanning, Select (Select All, Deselect All, "N selected"), Importing, Done or "No Profiles Found" | `Migration/TerminalMigrationWizardView.swift` |  | chau7_next/src/migration/, chau7_next_core/src/terminal_import.rs | done |  |

## Notes

- What the import really carries over: only font family, font size and cursor
  style reach the new profile (`FeatureSettings.createProfile` snapshots the
  current settings after setting those three). Colors, window size, shell and
  working directory are read and shown in the summary but dropped.
- The wizard view (`TerminalMigrationWizardView`) has no caller in the Swift
  app: no menu item or settings button opens it. Decide with the user whether
  to port it, wire it up, or mark it dropped.
- Terminal.app profiles come from `~/Library/Preferences/com.apple.Terminal.plist`
  ("Window Settings"); iTerm2 from `com.googlecode.iterm2.plist` ("New
  Bookmarks", font stored as "Name Size", colors as 0 to 1 components). Both
  files are read only and safe to read from Chau7 Next (DUAL-SHIP.md).
- Launch at Login is disabled in isolated test mode (`CHAU7_HOME_ROOT`). The
  LaunchAgent label is the bundle id, so Chau7 Next must use `com.chau7.next`
  and never touch `com.chau7.app.plist` (DUAL-SHIP.md). `SMAppService` is an
  alternative on macOS 13+, which is also Chau7 Next's minimum.
- `apps/chau7-macos/LaunchAgent/com.chau7.plist` is a hand-install sample
  (KeepAlive true), not used by the app.
- Not part of this Swift module but related: Chau7 Next copies `~/.chau7/config.toml`
  and `~/.chau7/snippets.json` from the Swift app on first launch
  (`DataRoot::import_from_swift_app`).

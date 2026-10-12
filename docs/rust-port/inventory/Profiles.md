# Profiles

Swift: `apps/chau7-macos/Sources/Chau7/Profiles/` (3 files, 1182 lines), plus `Chau7Core/ProfileSwitchRule.swift`, the profile model in `Settings/FeatureSettings.swift` (`SettingsProfile`) and the settings views `Settings/Views/ProfileSelectorBar.swift`, `ProfileAutoSwitchSettingsView.swift`, `SSHProfilesSettingsView.swift`, `ProfilesBackupSettingsView.swift`
Swift tests: `ProfileSwitchRuleTests`, `ProfileSwitchTriggerTests`, `SSHConfigParserTests`
Wave: 1
Depends on: Settings (a profile is a snapshot of all exportable settings), Repository (directory and branch for rules)

Settings profiles (named snapshots of every exportable setting, switchable by hand or automatically by rules on the tab's directory), and SSH connections: a connection manager, and sync with `~/.ssh/config`.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| PRO-001 | A settings profile is a name, an icon (16 SF Symbols) and a full copy of the exportable settings (font, colors, shell, shortcuts, notifications, tabs, hover card, snippets, MCP, remote, ...) | `Settings/FeatureSettings.swift` (`SettingsProfile`, `ExportableSettings`) |  | chau7_next_core/src/settings_profiles.rs,chau7_next/src/profiles/mod.rs | done |  |
| PRO-002 | Profile bar in Settings: menu with all profiles (check on the active one), load a profile, "Save Current" into the active profile, "Create New Profile..." (name and icon, saves current settings), "Deactivate Profile"; window title "Chau7 Settings for <name>" | `Settings/Views/ProfileSelectorBar.swift`, `Settings/FeatureSettings.swift` (`createProfile`, `loadProfile`, `saveCurrentToProfile`, `deleteProfile`) |  | chau7_next/src/settings_window/mine/profiles.rs | done |  |
| PRO-003 | A "Default" profile exists when none were saved | `Settings/FeatureSettings.swift` (`SettingsProfile.defaultProfiles`) |  | chau7_next_core/src/settings_profiles.rs | done |  |
| PRO-004 | Auto-switch rules: name, enabled, priority, target profile, and one trigger: directory glob (`*` per segment, `**` any depth, `~` expanded), git repo (folder name, case-insensitive), SSH host, running process, environment variable equals value | `Chau7Core/ProfileSwitchRule.swift` | `ProfileSwitchRuleTests`, `ProfileSwitchTriggerTests` | chau7_next_core/src/profile_rules.rs, chau7_next_core/src/settings_profiles.rs, chau7_next_core/src/procargs.rs, chau7_next/src/platform/process.rs (process_args_env), chau7_next/src/settings_window/mine/profiles.rs | done |  |
| PRO-005 | When a tab's directory changes (and once a command started in it), enabled rules are checked by priority (then name) against its directory, running processes, SSH host and environment; the first match loads its profile (the previous one is remembered); when nothing matches any more, the previous profile is restored | `Profiles/ProfileAutoSwitcher.swift` (`evaluateRules`, `applyRule`, `restorePreviousProfile`), `Terminal/Session/TerminalSessionModel.swift` (`updateCurrentDirectory`) |  | chau7_next_core/src/settings_profiles.rs, chau7_next/src/profiles/mod.rs (evaluate, rule_context), chau7_next/src/workspace/mod.rs (evaluate_profile_rules) | done |  |
| PRO-006 | Auto-switch settings: enable switch (off restores the previous profile), "Active: rule to profile" banner with Restore, rule list with DISABLED and P<n> badges, add/edit sheet (name, trigger type and value, target profile, enabled), delete with confirmation | `Settings/Views/ProfileAutoSwitchSettingsView.swift` |  | chau7_next/src/settings_window/mine/profiles.rs | done |  |
| PRO-007 | SSH connection manager window ("SSH Connections...", Shift+Cmd+O): list sorted by name, search by name/host/user, "Recent" section (5 last used), double-click connects, context menu Connect / Edit... / Duplicate / Delete, + and - buttons | `Profiles/SSHConnectionManager.swift` (`SSHConnectionView`, `SSHConnectionWindowController`) |  | chau7_next/src/profiles/ssh_manager.rs (SshRowMenu) | done |  |
| PRO-008 | Connection editor: name, host, port, user, identity file, jump host (ProxyJump), extra SSH options, tab color (7 colors); Save needs a host | `Profiles/SSHConnectionManager.swift` (`ConnectionEditorView`, `SSHConnection`) |  | chau7_next/src/profiles/ssh_manager.rs | done |  |
| PRO-009 | Connection detail: host, port, user, identity, jump host, last connected (relative), SSH command preview, Connect and Edit buttons | `Profiles/SSHConnectionManager.swift` (`ConnectionDetailView`) |  | chau7_next/src/profiles/ssh_manager.rs | done |  |
| PRO-010 | Connect: opens a new tab and types the ssh command (`-p` when not 22, `-i` escaped and `~` expanded, `-J`, extra options, escaped `user@host`), then records the last-connected time | `Profiles/SSHConnectionManager.swift` (`sshCommand`, `connect`, `markConnected`) |  | chau7_next_core/src/ssh_connections.rs,chau7_next/src/profiles/mod.rs | done |  |
| PRO-011 | Extra SSH options are validated: dangerous options, command substitution, redirection and shell control characters show a warning in the editor and are left out of the command | `Profiles/SSHConnectionManager.swift`, `Chau7Core/ShellEscaping.swift` (`validateSSHOptions`) | `ShellEscaping` tests | chau7_next_core/src/ssh_connections.rs,chau7_next/src/profiles/ssh_manager.rs | done |  |
| PRO-012 | Saved connections persist across launches (UserDefaults `ssh.connections`, `ssh.folders`) | `Profiles/SSHConnectionManager.swift` (`loadConnections`, `saveConnections`) |  | chau7_next_core/src/ssh_connections.rs,chau7_next/src/profiles/mod.rs | done |  |
| PRO-013 | SSH passwords stored per connection in the Keychain (service `com.chau7.ssh`, API only, no UI uses it) | `Profiles/SSHConnectionManager.swift` (`storePassword`, `password`, `removePassword`) |  | chau7_next/src/profiles/mod.rs | done | Keychain |
| PRO-014 | Connections export/import as JSON, import skips duplicates (same host, user, port) (API only, no UI) | `Profiles/SSHConnectionManager.swift` (`exportToJSON`, `importFromJSON`) |  | chau7_next_core/src/ssh_connections.rs | done |  |
| PRO-015 | Group, tags and notes on a connection, with filtering by group or tag (model only, no UI) | `Profiles/SSHConnectionManager.swift` (`allGroups`, `allTags`, `connections(inGroup:withTag:)`) |  | chau7_next_core/src/ssh_connections.rs | done |  |
| PRO-016 | "Import from ~/.ssh/config" in the manager's menu: adds hosts not already saved (same host and user) | `Profiles/SSHConnectionManager.swift` (`importFromSSHConfig`) |  | chau7_next_core/src/ssh_connections.rs,chau7_next/src/profiles/ssh_manager.rs | done |  |
| PRO-017 | SSH Config Sync settings: list of `~/.ssh/config` entries, file watch status and last sync time, Refresh, Import one host or Import All (with confirmation, wildcards skipped) | `Profiles/SharedSSHProfiles.swift`, `Settings/Views/SSHProfilesSettingsView.swift` | Four owned-file/native-watch regressions; actual current Settings summary and target native acceptance at5fa1e4c4 | chau7_next/src/profiles/ssh_config_sync.rs; chau7_next/src/settings_window/mine/profiles.rs; chau7_next/src/settings_window/summary.rs | done | One serial worker coalesces event/request bursts, caps reads at1MiB and4096 hosts, retains prior entries/success timestamp on failure, and caches local timezone conversion off UI. Native watch state is observed, with pending Loading and unsuccessful Never; Refresh queues actual work. Existing bounded profiler measures read/parse wall cost separately from waits, cache publication and UI rendering. |
| PRO-018 | "Export to SSH Config": appends saved connections whose host alias is not yet in `~/.ssh/config` | `Profiles/SharedSSHProfiles.swift` (`exportConnection`, `appendToSSHConfig`), `Settings/Views/SSHProfilesSettingsView.swift` | `SSHConfigParserTests` | chau7_next/src/settings_window/mine/profiles.rs,chau7_next_core/src/ssh_connections.rs | done |  |
| PRO-019 | Quick host list from `~/.ssh/config` (no wildcard hosts), searchable, shows `ssh user@hostname` | `Profiles/SharedSSHProfiles.swift` (`configEntries`) | `SSHConfigParserTests` | `chau7_next/src/workspace/` (`PickerKind::Ssh`), `chau7_next_core/src/ssh_config.rs` | done | |
| PRO-020 | iCloud settings sync (Sync Now, Restore from iCloud) and settings backup (Export/Import Settings... JSON) in the Profiles and Backup settings tab | `Settings/Views/ProfilesBackupSettingsView.swift` |  | chau7_next/src/settings_window/backup.rs, chau7_next/src/settings/export.rs, chau7_next/src/settings/sync.rs, chau7_next/src/platform/icloud.rs | done | NSUbiquitousKeyValueStore, NSSavePanel, NSOpenPanel |

## Notes

- PRO-005 only passes `directory`, `gitBranch` and child process names to the
  rules (and only on directory change). SSH host and environment triggers are
  accepted by the editor but never match, because nothing passes those values.
- `ProfilesBackupSettingsView` creates its own `ProfileAutoSwitcher()` instead
  of using `.shared`, and `.shared` loads rules only at init, so rules added in
  Settings take effect after a relaunch. Port the intended behavior (rules
  apply at once), not the bug.
- Rule storage: UserDefaults `feature.profileAutoSwitch` (bool) and
  `feature.profileSwitchRules` (JSON array of `ProfileSwitchRule`). Profiles:
  `settings.profiles` (JSON array), active id `settings.activeProfile`.
  Loading a profile posts `.settingsProfileChanged`.
- Rust parses `[profile.<name>]` sections of `config.toml`
  (`chau7_next_core/src/config.rs`, `ProfileConfig`: font family, font size,
  color scheme, shell) but the app never uses them. A Rust port could build
  profiles on that format rather than on UserDefaults.
- The Swift SSH connect (PRO-010) does not apply the connection's tab color;
  it waits 0.3 s after creating the tab before typing the command.
- PRO-020 may also be listed in Settings.md; keep only one row when merging.

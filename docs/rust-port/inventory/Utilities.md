# Utilities

Swift: `apps/chau7-macos/Sources/Chau7/Utilities/` (10 files, 1538 lines)
Swift tests: `Utilities/FileOperationsTests`, `Utilities/ManagedProcessTests`, `Utilities/DateFormattersTests`
Wave: 1 (see README.md)
Depends on: none

Shared helpers. Most of the module is plumbing (formatters, bounded arrays,
error enums, file helpers) with no effect of its own. The rows below are the
helpers a user can notice: which links are clickable, where secrets are kept,
how protected folders are treated, and the environment variables that override
paths and logging.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| UTL-001 | Links with `http`, `https`, `file`, `ssh`, `ftp` and `sftp` schemes are detected in terminal output and clickable | `Utilities/RegexPatterns.swift` (`url`), used by `RustBackend/RustTerminalView.swift` |  | `chau7_next_core/src/link_detect.rs` (`find_urls`, `target_at`), `chau7_next/src/terminal/links.rs` | done |  |
| UTL-002 | File paths with optional `:line:column` (absolute or relative) are detected in output for Cmd-click | `Utilities/RegexPatterns.swift` (`filePath`), used by `Commands/PathClickHandler.swift` |  | `chau7_next_core/src/link_detect.rs` (`find_paths`, `editor_launch`), `chau7_next/src/terminal/links.rs` | done |  |
| UTL-003 | Secrets (LLM API keys, saved SSH passwords) are stored in the Keychain, readable only on this Mac while unlocked | `Utilities/KeychainHelper.swift`, used by `Settings/Views/LLMSettingsView.swift`, `Profiles/SSHConnectionManager.swift` |  | chau7_next/src/platform/secrets.rs (WhenUnlockedThisDeviceOnly), chau7_next/src/ai/llm.rs, chau7_next/src/profiles/mod.rs | done | Keychain (SecItem) |
| UTL-004 | Repo detection never touches protected folders (Downloads, Desktop, Documents, ~/Library, /Applications, /System, /Library), so no macOS privacy prompt appears, unless the user enables access | `Utilities/ProtectedPathPolicy.swift` (`shouldSkipAutoAccess`), used by `Repository/RepositoryCache.swift` |  | `chau7_next_core/src/protected_path.rs`, `chau7_next/src/protected_paths.rs`, `chau7_next/src/platform/process.rs` (`git_root`) | done | TCC |
| UTL-005 | "Grant access" dialog to pick protected folders; access is kept as security-scoped bookmarks, re-activated at launch, refreshed when stale; a denied folder is retried after 5 minutes; Reset clears all checks | `Utilities/ProtectedPathPolicy.swift` (`requestAccessToProtectedFolders`, `activatePersistedBookmarks`, `resetAccessChecks`), `Settings/Views/ProductivitySettingsView.swift`, `App/AppDelegate.swift` |  | chau7_next/src/protected_paths.rs, chau7_next/src/platform/bookmarks.rs, chau7_next/src/settings_window/general.rs (Grant Access..., Reset Checks), chau7_next_core/src/protected_path.rs | done | NSOpenPanel, security-scoped bookmarks |
| UTL-006 | (dev) Environment variables override log and monitor paths: `CHAU7_LOG_FILE`, `CHAU7_LOG_MAX_BYTES`, `CHAU7_VERBOSE`, `CHAU7_TRACE`, `CHAU7_EVENTS_LOG`, `CHAU7_CODEX_HISTORY_LOG`, `CHAU7_CLAUDE_HISTORY_LOG`, `CHAU7_IDLE_STALE_SECONDS`, `CHAU7_CODEX_TERMINAL_LOG`, `CHAU7_CLAUDE_TERMINAL_LOG`, `CHAU7_TERMINAL_NORMALIZE`, `CHAU7_TERMINAL_ANSI`, `CHAU7_IDLE_SECONDS`, `CHAU7_COMMAND_FALLBACK_SECONDS`, `CHAU7_CLEAR_ON_LAUNCH`, `CHAU7_PTY_DUMP_MAX_BYTES`, `CHAU7_PTY_LOG_MAX_BYTES`, `CHAU7_REMOTE_OUTPUT_BATCH`, each with a legacy `AI_*` or `SMART_OVERLAY_*` name | `Utilities/Utilities.swift` (`EnvVars`) |  | chau7_next_core/src/env_vars.rs, chau7_next/src/logging/mod.rs (env_override), chau7_next/src/history/monitor.rs, chau7_next/src/ai/hub.rs, chau7_next/src/ai/log_view.rs, chau7_next/src/remote/mod.rs, chau7_next/src/terminal/pty_capture.rs, chau7_next_core/src/shell_session.rs, chau7_next_core/src/ai/pty_log.rs | done |  |
| UTL-007 | Helper processes (proxy, remote agent) are stopped with SIGTERM, then SIGINT after 1 s, then SIGKILL | `Utilities/ManagedProcess.swift` | `ManagedProcessTests` | | n/a | |
| UTL-008 | `git` is resolved from Homebrew before the Xcode shim | `Utilities/Utilities.swift` (`GitBinary`) | | | n/a | |
| UTL-009 | Accessibility helpers: Dynamic Type scaled fonts, high contrast colors, reduce motion, VoiceOver announcements, focus rings, list item hints | `Utilities/AccessibilityUtilities.swift` | | | n/a | NSAccessibility |
| UTL-010 | Typed errors with recovery suggestions and input validation for host, port, path and user name | `Utilities/Chau7Error.swift` (`Chau7Error`, `InputValidation`, `RateLimiter`) | | | n/a | |
| UTL-011 | File and JSON helpers that log failures instead of crashing; appended files get their parent folder created | `Utilities/Chau7Error.swift` (`FileOperations`, `JSONOperations`) | `FileOperationsTests` | | n/a | |
| UTL-012 | Shared date formatters, bounded arrays and sets, `trimToLast` | `Utilities/Formatters.swift`, `Utilities/BoundedArray.swift`, `Utilities/Utilities.swift` | `DateFormattersTests` | | n/a | |
| UTL-013 | Resource bundle lookup so strings and icons load both from `Chau7.app` and from an unbundled `.build` run | `Utilities/Chau7Resources.swift` | | | n/a | Bundle |

## Notes

- n/a reasons:
  - UTL-007: plumbing for Proxy and Remote; port it with those modules (Rust
    `std::process::Child` plus `libc::kill`).
  - UTL-008: `GitBinary` has no caller in the Swift app, and Chau7 Next reads
    `.git/HEAD` directly (`platform/process.rs`) instead of running `git`.
  - UTL-009: none of these modifiers or `AccessibilityAnnouncement` has a caller
    outside `AccessibilityUtilities.swift`; accessibility work in Rust belongs to
    the views that need it.
  - UTL-010: `Chau7Error` is only produced by `InputValidation`, which has no
    caller outside the file; Rust uses `Result` with its own error types.
  - UTL-011 to UTL-013: plain helpers; Rust has its own equivalents
    (`serde_json`, `std::fs`, `DataRoot`). UTL-013 matters again when Localization
    is ported.
- Protected folder policy: setting `allowProtectedFolderAccess`
  (FeatureSettings). Bookmarks are stored in UserDefaults key
  `protectedPathPolicy.securityScopedBookmarksByRoot.v1`. A "not found" error
  counts as accessible; only permission errors (EACCES,
  NSFileReadNoPermissionError) count as denied. In Chau7 Next the prompt would
  name "Chau7 Next" and its decision is separate from Chau7's.
- Keychain: Swift services are `com.chau7.llm.<provider>.apikey` (account
  `apikey`) and `com.chau7.ssh` (account: the connection UUID); items use
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Chau7 Next must prefix its
  own `com.chau7.next.` and offer an import with consent (DUAL-SHIP.md).
- Chau7 Next strips every inherited `CHAU7_*` variable at startup
  (`shell_env::inherited_cleanup`), so each variable is read under its
  `CHAU7_NEXT_*` name first (`logging::env_override`), then the `CHAU7_` and
  legacy names. `CHAU7_CLEAR_ON_LAUNCH` is only read by Swift's
  `maybeClearOnLaunch`, which nothing calls, so it has no effect in either app.

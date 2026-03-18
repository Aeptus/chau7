# Changelog

All notable changes to Chau7 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **MCP `tab_output` source=pty_log**: New `source` param on `tab_output` reads the ANSI-stripped PTY output log instead of the terminal buffer. Captures full AI session output including alternate-screen content that TUI-based tools discard on exit. Works for all AI providers.
- **MCP `wait_for_stable_ms`**: New param on `tab_output` polls the terminal buffer until content settles, fixing the race where `is_at_prompt` fires before the agent's final response finishes rendering
- **PTY Log Fallback Transcript**: `run_transcript` now falls back to the ANSI-stripped PTY output log when provider-specific extraction fails, capturing full agent output including alternate-screen content from TUI-based tools
- **Terminal Buffer Fallback Transcript**: Secondary fallback captures the terminal scrollback at run-end time for non-TUI agents
- **Remote Live Activity State**: Chau7 now projects one authoritative remote AI activity over the remote-control channel so the iPhone client can render a native Live Activity / Dynamic Island state for the most relevant task
- **Isolated Test App Builder**: Added a dedicated isolated app build that runs with its own bundle ID, home root, keychain prefix, logs, and app support directories for safe manual testing alongside the main app
- **MCP Terminal Key Tools**: Added `tab_press_key` for real terminal key events and `tab_submit_prompt` as an Enter-key convenience for interactive TUIs like Claude Code
- **Tab Bar Staleness Detection**: Watchdog now detects when NSHostingView becomes disconnected (preference keys stop firing) and forces recovery
- **Clickable File Paths**: Cmd+Click on file paths in terminal output to open in right panel editor (planned)
- **Runtime Turn Send for Adopted Sessions**: MCP clients can now send prompts through `runtime_turn_send` even when the runtime session was adopted from an existing tab

### Fixed
- **AI Tool Detection**: Fixed false positive detecting "Cline" on Claude Code sessions — bare `cline` pattern matched substrings. Command-based detection now gates output pattern scanning to prevent race conditions.
- **Idle Tab Event Spam**: `HistoryIdleMonitor` now fires idle exactly once per session — heartbeat entries no longer reset the dedup flag. Scheduler backs off to the stale deadline for already-idle sessions.
- **Redundant Tab Highlights**: Notification executor tracks applied presets per tab and skips re-applies when the same style is already active with a pending auto-clear timer.
- **MCP `tab_output` Line Cap**: Raised from 5000 to 10000 to match default scrollback depth
- **Claude Code JSONL Discovery**: Provider now scans session root directory when `subagents/` is empty, supporting older Claude Code versions
- **Shell Termination Timeouts**: AI sessions get longer grace periods (3s+2s) vs plain shells (1s+0.5s) to avoid SIGKILL escalation during cleanup
- **Tab Restoration for Background Tabs**: Tabs outside the nearby rendering range now delegate prefill to the session level instead of burning 55s of retries
- **Claude Code Prompt Submission via MCP**: `tab_send_input` remains raw text while the new keypress path now sends real Enter-style terminal input, fixing prompt submission in TUIs that distinguish pasted newlines from the Return key
- **Isolated Test App Startup**: Disabled notification-center initialization in isolated mode and corrected the embedded isolated-home launcher path to prevent startup crashes
- **AI Tool Detection**: Fixed false positive detecting "Cursor" on Codex sessions - patterns now more specific to avoid matching generic text like "cursor position"
- **Build Errors**: Fixed Swift 6 actor isolation error in `handleOutput()` and optional binding on non-optional Data
- **Tab Reordering Preview**: Fixed dragged tabs causing sibling tabs to slide early with a visible offset in the toolbar

### Changed
- **Queued Terminal Input Ordering**: Terminal sessions now preserve order between queued raw text input and queued key presses when a tab is created or restored before its view attaches
- **Runtime Path Isolation**: Chau7-owned paths and keychain service names can now be redirected through `RuntimeIsolation`, allowing safe test builds without touching the main app's storage
- **Output Detection Patterns**: Made patterns more specific (URLs with slashes, version strings, box-drawing banners) to reduce false positives

---

## [0.5.0] - 2026-01-21

### Added
- **Tab Notification Styling**: New `TabNotificationStyle` with color, italic, bold, pulse, and icon properties
  - Predefined styles: `.waiting`, `.error`, `.success`, `.attention`
  - Integration with notification action system (`styleTab` action type)
  - Auto-clear timer support with race condition prevention

- **Snippet Variable Improvements**:
  - Picker support: `${input:name:opt1|opt2|opt3}` for single-select dropdowns
  - Multi-select support: `${multiselect:name:opt1|opt2|opt3}` with toggle buttons
  - FlowLayout for multi-select buttons

- **Manual Tab Bar Recovery**: Window menu → "Refresh Tab Bar" (Cmd+Option+R)

### Fixed
- **Major Tab Bar Resilience** (4 architectural fixes):
  1. Cache NSHostingView in TabBarToolbarDelegate - prevents state loss on toolbar recreation
  2. Visibility-based recovery - detects "rendered but invisible" tabs via geometry
  3. Stable view identity with UnifiedTabButton - prevents SwiftUI view recreation
  4. Model-owned watchdog lifecycle - runs regardless of view lifecycle events

- **Debug Console**: Fixed empty logs issue - category filter now allows logs without tags
- **Snippet Variable Dialog**: Fixed crash from ForEach indices binding - uses identity-based bindings

---

## [0.4.0] - 2026-01-20

### Added
- **Tab Bar Watchdog**: Timer-based health monitoring with automatic recovery
  - Reports rendered tab count from view to model
  - Limits refresh attempts to 3 to prevent log spam
  - Thread-safe with `dispatchPrecondition`

- **Smart Scroll**: Preserves user's scroll position when new output arrives
  - Only auto-scrolls if user is at/near bottom of terminal
  - New `isSmartScrollEnabled` setting (default: true)

- **Enhanced Logging System** (`LogEnhanced`):
  - 11 categories: App, Tabs, Terminal, Session, Network, Performance, etc.
  - Structured JSON output option
  - Correlation IDs for async operation tracing
  - `PerfTracker` for performance measurement
  - Memory pressure monitoring
  - OSLog integration for Console.app

- **Debug Console Improvements**:
  - Level filter chips (TRACE, INFO, WARN, ERROR)
  - Category filter chips with emojis
  - Quick presets ("All", "Errors Only")
  - Entry counter and memory display

### Fixed
- **Tab Bar Crash**: Removed `.drawingGroup(opaque: false)` causing Metal render corruption
- **ProxyManager Concurrency**: Fixed race condition (DispatchQueue.global → .main)
- **14 Build Warnings**: Unused vars, var→let, discarded results

### Changed
- **Logging Defaults**: Restored critical logs from TRACE to INFO (dev server, AI detection, stuck detection)
- **FileTailer Buffer**: Increased from 1MB to 4MB for verbose Codex output
- **Stale Timeout**: Reduced from 600s to 180s (3 min) for faster session close detection
- **History Idle Notification**: Disabled by default (was noisy)

---

## [0.3.0] - 2026-01-19

### Added
- **Tab Reordering**: Drag-and-drop tabs to reorder
- **Terminal Context Menu**: Right-click menu with common actions
- **Notification Event System**:
  - `ShellEventDetector` for shell events (exit codes, patterns, long-running commands)
  - `AppEventEmitter` for app events (scheduled, inactivity, memory pressure)
  - `NotificationActionExecutor` for executing trigger actions
  - Thread safety with serial queues and rate limiting
  - Memory hysteresis to prevent alert flooding

### Fixed
- **Terminal Focus**: Focus returns to terminal after snippet selection
- **Git Badge**: Fixed git icon/branch not showing on new tabs - use `updateCurrentDirectory()` instead of direct property assignment
- **Text Selection Bugs**:
  - `lastSelectionText` not clearing when user clicks to deselect
  - Mouse state not cleared when mouseUp is outside bounds/window
  - Lowered drag threshold from 3px to 1.5px for better detection

### Changed
- Keyboard shortcut updates

---

## [0.2.1] - 2026-01-15

### Added
- **v1.3 Shell Integration**: CLI header injection for AI tool detection
- **v1.2 Baseline Metrics**: Display in Swift UI with token savings estimation

### Fixed
- **v1.2 Code Review Bugs**:
  - Task assessments now forward to Mockup analytics
  - IPC notifications include TokensSaved from baseline
  - Mockup client wired to task manager

---

## [0.2.0] - 2026-01-14

### Added
- **API Proxy**: LLM token analytics and cost tracking
  - Intercepts API calls to track usage
  - Per-session and aggregate statistics

- **v1.1 Task Lifecycle Management**:
  - Task state machine (pending → running → completed/failed)
  - Automatic task detection from terminal output
  - Task duration tracking
  - Tests and UI wiring

- **Terminal Header Box**: Visual indicator for active AI sessions

### Fixed
- Overlay layout issues

---

## [0.2.0] - 2026-01-13

"One proud foot of code" release

### Added
- Complete settings system with all features wired
- Session handling improvements
- Settings layout refactoring

---

## [0.1.0] - 2026-01-11

Initial development release

### Added
- **Core Terminal**:
  - SwiftTerm-based terminal emulation (custom fork)
  - Startup line display before shell prompt
  - Terminal defaults wiring

- **AI CLI Detection**:
  - Automatic detection of Claude, Codex, Gemini, ChatGPT, Copilot, Aider, Cursor
  - Command-based detection from input
  - Output pattern detection for missed commands
  - Custom detection rules support

- **Snippets System**:
  - Template expansion with variables
  - `${input:name}`, `${input:name:default}` syntax
  - Quick-select keys (1-9)
  - Three scope levels: Global, Profile, Tab

- **Tab Management**:
  - Multiple tabs with Cmd+T/Cmd+W
  - Tab colors per AI tool
  - Tab renaming

- **Overlay Mode**:
  - Dropdown terminal (like iTerm2 hotkey window)
  - UX improvements

- **Split Panes**:
  - Horizontal and vertical splits
  - Text editor in right panel

- **Settings**:
  - Comprehensive settings UI
  - Import/export configuration

### Technical
- SwiftUI-based architecture
- macOS 13+ (Ventura) minimum
- Swift 5.9+ required
- SwiftTerm fork for custom terminal features

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 0.5.0 | 2026-01-21 | Tab notification styling, major tab bar fixes |
| 0.4.0 | 2026-01-20 | Smart scroll, watchdog recovery, enhanced logging |
| 0.3.0 | 2026-01-19 | Tab reordering, notification events, selection fixes |
| 0.2.1 | 2026-01-15 | Shell integration, baseline metrics |
| 0.2.0 | 2026-01-14 | API proxy, task lifecycle, terminal header |
| 0.1.0 | 2026-01-11 | Initial release with core features |

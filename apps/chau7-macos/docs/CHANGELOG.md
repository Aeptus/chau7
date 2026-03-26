# Changelog

All notable changes to Chau7 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Repository Tab Grouping**: Tabs can be grouped by git repository (Off/Auto/Manual modes). Grouped tabs show an inline repo-name tag chip with a thin connecting line overlaying their top borders, and suppress the redundant repo path from individual tab titles. Auto mode groups by detected gitRootPath; Manual mode lets users right-click to add/remove tabs from groups. Free drag reorder preserved.
- **Split Pane File Preview**: Read-only file viewer with syntax highlighting for text and native rendering for images (png/jpg/gif/svg/webp). Opens via Cmd+Opt+P or Changed Files context menu.
- **Split Pane Diff Viewer**: Unified git diff view with colored additions/deletions, dual line numbers, and Working/Staged mode toggle. Opens via Cmd+Opt+Shift+D or Changed Files "Open Diff" context menu.
- **Remote iPhone Efficiency Pass**: Chau7 Remote now processes incoming frames off the main actor, adds `os_signpost` instrumentation for remote frame processing and ANSI stripping, requests a fresh active-tab snapshot on foreground resume, and preserves approvals/prompts when the background keepalive expires.
- **Selected-Tab Remote Streaming**: The macOS remote sender now streams terminal output and snapshots only for the tab currently selected on iPhone, reducing background traffic and receive-side render work.
- **Remote Background Approval Mode**: The Chau7 Remote iPhone app now keeps a short-lived background session alive in approvals-only mode so pending approvals and detected interactive prompts can still sync after the app backgrounds.
- **Remote Push Approval Delivery**: The Cloudflare relay and Go remote helper now support APNs-backed push registration and push-triggered approval delivery for the Chau7 Remote iPhone app when the phone is no longer actively connected.
- **Experimental iPhone Terminal Renderer**: Chau7 Remote can now render a real Rust-backed terminal grid on iPhone behind a toggle, while keeping the text renderer as a fallback.
- **Interactive Remote Prompts**: iPhone remote clients now surface detected Claude and Codex terminal prompts in the Approvals tab and can reply with a mapped option directly to the originating tab. Destructive options require a second confirmation on iPhone.
- **MCP `tab_output` source=pty_log**: New `source` param on `tab_output` reads the ANSI-stripped PTY output log instead of the terminal buffer. Captures full AI session output including alternate-screen content that TUI-based tools discard on exit. Works for all AI providers.
- **MCP `wait_for_stable_ms`**: New param on `tab_output` polls the terminal buffer until content settles, fixing the race where `is_at_prompt` fires before the agent's final response finishes rendering
- **PTY Log Fallback Transcript**: `run_transcript` now falls back to the ANSI-stripped PTY output log when provider-specific extraction fails, capturing full agent output including alternate-screen content from TUI-based tools
- **Terminal Buffer Fallback Transcript**: Secondary fallback captures the terminal scrollback at run-end time for non-TUI agents
- **Menu Bar Only Mode**: New setting hides Chau7 from Dock and Cmd+Tab (activation policy `.accessory`)
- **Floating Window Mode**: New setting keeps the terminal window above other apps (`.floating` window level)
- **Angle Bracket Matching**: Editor now matches `<>` pairs and supports jump-to-matching-bracket
- **Whole-Word Terminal Search**: New toggle wraps search query in `\b` word boundaries
- **Relative/Hybrid Line Numbers**: Editor gutter supports absolute, relative, and hybrid line number modes with dynamic width
- **Cursor Blink Rate**: Configurable blink interval (0.3–2.0s) and custom cursor color (hex)
- **Visual Bell + Rate Limiting**: Bell can flash the screen (combinable with audible), with configurable minimum interval
- **Keybindings JSON Export/Import**: Standalone export/import methods for keybindings separate from full settings
- **Custom API Pricing**: `~/.chau7/pricing.json` overrides the built-in model pricing table
- **TTFT Latency Tracking**: Time-to-first-token measured via firstByteReader wrapper. Stored in SQLite, logged, and sent via IPC.
- **Font Ligature Rendering**: Metal renderer now shapes multi-character sequences via CoreText. Fonts with OpenType ligature tables (Fira Code, JetBrains Mono, Cascadia Code) automatically display ligatures. Configurable via `enableLigatures` setting.
- **OSC 133 Shell Integration**: FinalTerm/iTerm2 shell integration markers parsed in Rust interceptor. Provides authoritative prompt/command/output region tracking with exit codes. Feeds ShellEventDetector for accurate command lifecycle. When present, heuristic detection (echo-based start, timeout-based finish, OSC 7 prompt inference) is suppressed.
- **TelemetryStore Resilience**: SQLite insert failures now log the actual error message (was logging only the record ID). Database integrity check on startup with automatic recreation on corruption.
- **TabResolver Accuracy**: Directory disambiguation now prefers the most recently active tab instead of the first match. Fallback uses most recently active tab instead of most recently created. Eliminates most ambiguous matches.
- **Watchdog Tolerance**: Tab bar health check now allows ±2 tolerance in rendered count to prevent false recovery triggers during transitions.
- **Log Noise Reduction**: Toolbar lifecycle events (appeared/disappeared/visibility) downgraded from WARN/INFO to TRACE.
- **Show Changed Files**: Git diff snapshot at command start (OSC 133 C) and finish (OSC 133 D) identifies files modified by each command. View > Show Changed Files (Cmd+Option+G) or via keybinding.
- **File Drag & Drop**: Drop files onto terminal to paste shell-escaped paths. Option+drop images for base64 data URI (for AI CLIs). 10MB size cap.
- **chau7:// URL Handler**: `chau7://ssh/user@host`, `chau7://run/<base64>`, `chau7://cd/path`, `chau7://open/path` open tabs or files from external apps. Run commands require user confirmation.
- **Markdown Runbooks**: Open a .md file in the editor pane → auto-renders with executable code blocks. Click "Run" on each block or "Run All" to execute in the adjacent terminal.
- **Idle Tabs Dropdown**: Tabs idle 10+ minutes are collected into a dropdown chip at the start of the tab bar. Hover shows tab hover card. Click to select, "Close All Idle" to clean up. Configurable in Settings > Tabs.
- **Keyboard Shortcut Standardization**: All Chau7-specific shortcuts now use Cmd+Option. Standard macOS shortcuts unchanged. Tab selection (Cmd+1-9) internationalized for all keyboard layouts.
- **API Analytics Fix**: Streaming response metadata (model, tokens, cost) now correctly parsed for Anthropic and OpenAI. Tab names shown instead of UUIDs.
- **Profile Auto-Switch Wired Up**: `evaluateRules()` now fires on directory change with git branch and process context
- **API Analytics Tab**: Debug console (Cmd+Shift+L) now shows per-provider cost, per-tab tokens, and aggregate totals
- **Hyperlink Protocols**: Clickable links now detect file://, ssh://, ftp://, sftp:// in addition to http/https
- **Clipboard Persistence + Search**: Clipboard history persists across restarts, supports substring search, cap raised to 1000 items
- **Unicode Ambiguous-Width Config**: Per-profile setting for East Asian ambiguous character width (1=single, 2=double) with Rust FFI support
- **Font Weight Setting**: Configurable NSFont weight (0=ultralight to 14=ultra-heavy)
- **JSON-RPC API Complete**: All 7 stubbed methods (list_tabs, get_tab, run_command, get_output, create_tab, close_tab, run_snippet) now implemented
- **Timeline Density Heatmap**: Minimap shows activity hotspots via bucketed opacity overlay
- **Remote Live Activity State**: Chau7 now projects one authoritative remote AI activity over the remote-control channel so the iPhone client can render a native Live Activity / Dynamic Island state for the most relevant task
- **Isolated Test App Builder**: Added a dedicated isolated app build that runs with its own bundle ID, home root, keychain prefix, logs, and app support directories for safe manual testing alongside the main app
- **MCP Terminal Key Tools**: Added `tab_press_key` for real terminal key events and `tab_submit_prompt` as an Enter-key convenience for interactive TUIs like Claude Code
- **Tab Bar Staleness Detection**: Watchdog now detects when NSHostingView becomes disconnected (preference keys stop firing) and forces recovery
- **Clickable File Paths**: Cmd+Click on file paths in terminal output to open in right panel editor (planned)
- **Runtime Turn Send for Adopted Sessions**: MCP clients can now send prompts through `runtime_turn_send` even when the runtime session was adopted from an existing tab

### Fixed
- **Notification Identity Scoping**: Notification coalescing and rate limiting are now scoped by tab, session, or directory identity instead of only trigger/tool matching. One noisy tab no longer suppresses the same notification on another tab.
- **AI Tool Detection**: Fixed false positive detecting "Cline" on Claude Code sessions — bare `cline` pattern matched substrings. Command-based detection now gates output pattern scanning to prevent race conditions.
- **Dangerous Command Guard Hardening**: Unicode homoglyph detection, multiline paste protection, per-directory allowlists
- **MCP Audit-Only Mode**: New `auditOnly` permission mode allows execution but logs for review. Per-agent profile scoping via agentAllowlist.
- **Process Exit Confirmation**: Cmd+Q now lists running process names and asks for confirmation before quitting
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
- **Phantom Window on Launch**: Closed windows no longer reappear on relaunch — disabled macOS native state restoration (`isRestorable = false`) and hardened the save filter with explicit hidden-window tracking

### Changed
- **Settings UX Overhaul**: 15 UX fixes — separate Font & Colors / Display reset, Tabs reset button, configurable idle tab threshold (1-60 min), LLM settings with proper help text, mouse settings above shortcuts table, consolidated Input reset, ligatures toggle promoted, SSH Profiles elevated, MCP Appearance before Profiles, Persistent History at top and defaulting to on, Token Optimization "How It Works" visible when off, AI Detection actionable-first layout, Render Test Image feedback
- **Chau7 Remote Branding**: The iPhone app now uses the Chau7 dock icon and in-app branding assets so macOS and iOS share the same visual identity.
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
| 0.5.1 | 2026-03-19 | Richer remote approval context on iPhone: directory, recent command, project/branch, and MCP source notes |
| 0.5.0 | 2026-01-21 | Tab notification styling, major tab bar fixes |
| 0.4.0 | 2026-01-20 | Smart scroll, watchdog recovery, enhanced logging |
| 0.3.0 | 2026-01-19 | Tab reordering, notification events, selection fixes |
| 0.2.1 | 2026-01-15 | Shell integration, baseline metrics |
| 0.2.0 | 2026-01-14 | API proxy, task lifecycle, terminal header |
| 0.1.0 | 2026-01-11 | Initial release with core features |

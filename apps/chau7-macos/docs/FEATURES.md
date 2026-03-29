# Chau7 Features

The AI-native terminal for macOS. GPU-accelerated, MCP-enabled, built for developers who ship with AI.

> See also: [features.csv](features.csv) for the machine-readable feature inventory.

## Table of Contents

- [Terminal Core](#terminal-core)
- [Performance](#performance)
- [AI Detection & Integration](#ai-detection--integration)
- [MCP Server](#mcp-server)
- [MCP Tools](#mcp-tools)
- [API Analytics & Token Tracking](#api-analytics--token-tracking)
- [Tabs, Panes & Windows](#tabs-panes--windows)
- [Productivity](#productivity)
- [Appearance & Theming](#appearance--theming)
- [Settings & Configuration](#settings--configuration)
- [Accessibility & Localization](#accessibility--localization)
- [SSH, Profiles & Remote](#ssh-profiles--remote)
- [Scripting & Debugging](#scripting--debugging)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [File Locations](#file-locations)
- [Environment Variables](#environment-variables)

---

## Terminal Core

- **Rust terminal backend** — custom emulator via FFI: fast, memory-safe, correct.
- Full ANSI/VT100 with 16-color, 256-color, and 24-bit true color support.
- International Option-key punctuation input preserved for programming characters like brackets and braces.
- Kitty keyboard protocol (full progressive enhancement).
- Inline images: iTerm2 (ESC ] 1337), Sixel, and Kitty image protocols.
- Configurable cursor styles (block, underline, bar) with optional blinking.
- Large configurable scrollback buffer with GPU-accelerated scrolling.
- Shell selection: Zsh, Bash, Fish, or custom path — Apple Silicon and Intel native.
- Dead key and IME support with proper `NSTextInputClient` marked text handling.
- Shell integration via OSC 7 for working directory tracking.
- OSC 133 (FinalTerm) shell integration: prompt start (A), command start (B), output start (C), command finished with exit code (D). Parsed in Rust interceptor, feeds ShellEventDetector. When present, heuristic fallbacks are suppressed.
- File drag-and-drop: drop files to paste shell-escaped paths; Option+drop images for base64 data URIs.
- Markdown runbooks: open .md files in the editor pane with executable code blocks.
- Native macOS cut/copy/paste shortcuts are preserved inside split-pane text editors before terminal-specific fallbacks run.
- Show Changed Files (Cmd+Option+G): git diff snapshot per command shows which files were modified.
- Idle tabs dropdown: tabs idle beyond a configurable threshold (default 10 min) are grouped into a compact chip in the tab bar.
- Repository tab grouping: group tabs by git repo (Off/Auto/Manual). Shows inline repo-name tag chip with connecting line. Suppresses redundant repo path in tab titles.
- Split pane file preview: read-only viewer with syntax highlighting and image support (Cmd+Opt+P).
- Split pane diff viewer: unified git diff with colored additions/deletions and Working/Staged toggle (Cmd+Opt+Shift+D).
- `chau7://` URL scheme: ssh, run, cd, and open actions from external apps (with confirmation).
- Default start directory and optional startup commands.
- Copy on select, Option+click cursor positioning, paste escaping.

## Performance

Chau7's rendering pipeline is purpose-built for latency-sensitive terminal work:

| Layer | What It Does |
| --- | --- |
| **Metal GPU rendering** | Hardware-accelerated text via Apple Metal |
| **IOSurface direct display** | Bypass the macOS compositor — GPU straight to display |
| **Glyph atlas caching** | Dynamic glyph cache eliminates redundant rasterization |
| **SIMD escape parsing** | 16–32 byte SIMD-accelerated ANSI parsing in Rust |
| **Lock-free ring buffer** | SPSC lock-free PTY pipeline — zero contention |
| **Triple buffering** | Atomic swap terminal state — no tearing, no blocking |
| **Low-latency input (IOKit HID)** | Bypass NSEvent queue for sub-10ms keyboard latency |
| **Real-time thread priority** | Mach real-time policy on render and input threads |
| **Predictive rendering** | Pre-cache likely output to shave display latency |
| **Dirty region tracking** | Only re-render what changed |
| **Feature profiler** | Per-feature timing with os.signpost integration |

## AI Detection & Integration

### Auto-Detection

Chau7 recognizes AI CLIs the moment they launch — no configuration required:

- **Claude** (claude, claude-code, claude-cli)
- **Codex** (codex, codex-cli, codex-pty)
- **Gemini** (gemini, gemini-cli)
- **ChatGPT** (chatgpt, gpt, openai)
- **GitHub Copilot** (copilot, gh copilot)
- **Aider**, **Cursor**, and custom-defined tools

Detection methods:
- Command line tokenization with wrapper skipping (env, sudo, npx, bunx, pnpm). Command detection gates output scanning to prevent false positives.
- Output banner matching for all supported CLIs. Patterns require tool-specific context to avoid substring collisions.
- Custom detection rules with display name, tab color, and logo.

### AI Features

- **Branded tab logos** — each agent gets its logo in the tab.
- **Auto tab theming** — tabs adopt the brand color of the active AI agent.
- **LLM error explanation** — one-click error analysis via OpenAI, Anthropic, Ollama, or custom endpoint.
- **Claude Code deep integration** — monitor hook events: prompts, tools, permissions, responses.
- **AI event notifications** — finished, failed, needs_validation, permission, tool_complete, session_end, idle.
- **Runtime session startup** — MCP-created runtime sessions become ready immediately after launch, and `attach_tab_id` sessions start usable without a manual state repair step.
- **MCP command filter hardening** — permission checks now recognize background separators, tabs, and newlines before deciding whether a command is allowed, blocked, or needs approval.
- **Backend launch environment validation** — runtime backend launch strings now drop invalid environment variable names before shell interpolation.
- **History monitor tab routing** — idle and finished history events resolve provider session metadata to recover the working directory before notification routing.
- **Session-aware tab resolution** — notification routing prefers exact AI session ID matches before broader provider/title heuristics.
- **File conflict events** — newly detected cross-tab file conflicts emit app events for each affected tab.
- **PTY output logging** — capture raw terminal output for AI tool sessions.
- **Codex session resolver** — maps Codex OpenAI capture sessions to working directories with LRU caching.

### Context Token Optimization (CTO)

- Monitor and optimize LLM API token usage in real time.
- Per-tab or global CTO mode with flag files that AI tools read.
- Runtime monitor: decision counts, mode changes, deferred operations, health assessment.
- MCP-controllable via `tab_set_cto`.

### History Storage

- Persistent history maintenance now serializes on the DB queue, so queued async inserts cannot repopulate history after `clearAll()`.
- Regression coverage now locks in that queued inserts are removed by a subsequent `clearAll()`.

## MCP Server

Chau7 runs an embedded MCP (Model Context Protocol) server — your AI agents can see and control your terminal.

### Architecture

- **Protocol**: JSON-RPC 2.0 over Unix domain socket (`~/.chau7/mcp.sock`).
- **Version**: MCP 2024-11-05 with tools and resources capabilities.
- **Bridge**: `~/.chau7/bin/chau7-mcp-bridge` (stdio-to-socket bridge for standard MCP clients).
- **Thread safety**: All terminal operations dispatch to main thread via `DispatchQueue.main.sync`.

### Auto-Registration

On every launch, Chau7 automatically registers itself as an MCP server in:

| AI Tool | Config File | Format |
| --- | --- | --- |
| Claude Code | `~/.claude.json` | JSON (`mcpServers.chau7`) |
| Cursor | `~/.cursor/mcp.json` | JSON (`mcpServers.chau7`) |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | JSON (`mcpServers.chau7`) |
| Codex | `~/.codex/config.toml` | TOML (`[mcp_servers.chau7]`) |

Registration only occurs if the AI tool's config directory exists — no files are created for tools you don't use.

### Safety Controls

- **Enable/disable toggle** — `mcpEnabled` setting (default: on).
- **Approval gate** — optional confirmation dialog before MCP operations (`mcpRequiresApproval`).
- **Tab limit** — configurable max MCP-created tabs (default: 4, hard cap: 50).
- **Tab indicator** — purple badge on MCP-controlled tabs (`mcpShowTabIndicator`).

## MCP Tools

### Tab Management (10 tools)

| Tool | Description |
| --- | --- |
| `tab_list` | List all tabs across all windows with status, cwd, git branch, CTO state, active app |
| `tab_create` | Open a new tab with optional directory and target window — respects approval gate and tab limit |
| `tab_exec` | Execute a command in a tab — auto-queues if shell is still loading, checks prompt state |
| `tab_status` | Detailed status: process state, child processes (PID/CPU/RSS), active telemetry run, git branch |
| `tab_send_input` | Send raw input for interactive prompts — no auto-newline appended |
| `tab_press_key` | Send terminal key presses for interactive TUIs — Enter, Escape, arrows, backspace, delete, paging keys, and ctrl/alt combos |
| `tab_submit_prompt` | Submit the current interactive prompt by sending Enter as a key press |
| `tab_close` | Close a tab with optional force flag — checks for running processes |
| `tab_output` | Get recent terminal output (last N lines, max 10000) with 512KB cap. `source='pty_log'` returns ANSI-stripped PTY log (full AI session). `wait_for_stable_ms` polls buffer until stable. |
| `tab_set_cto` | Set per-tab CTO override (default/forceOn/forceOff) — recalculates flag files |

### Telemetry (8 tools)

| Tool | Description |
| --- | --- |
| `run_get` | Get a single telemetry run by ID (active or from store) |
| `run_list` | List runs with filters: session_id, repo_path, provider, date range, tags, limit/offset |
| `run_tool_calls` | Get all tool calls for a run — see exactly what an AI agent did |
| `run_transcript` | Full conversation transcript for a run — falls back to ANSI-stripped PTY log for TUI tools, then terminal buffer |
| `run_tag` | Set tags on a run for organization and filtering |
| `run_latest_for_repo` | Most recent run for a repository — optionally filter by provider |
| `session_list` | List AI sessions with run counts — filter by repo_path, active_only |
| `session_current` | Get currently active AI sessions across all tabs |

### Runtime API (8 tools)

| Tool | Description |
| --- | --- |
| `runtime_session_create` | Start or attach an agent session in Chau7 and return a runtime session ID |
| `runtime_session_list` | List runtime sessions, with optional inclusion of recently stopped sessions |
| `runtime_session_get` | Get detailed state for one runtime session |
| `runtime_session_stop` | Stop a runtime session and optionally close its tab |
| `runtime_turn_send` | Send a formatted prompt to a runtime session, including adopted sessions discovered from existing tabs |
| `runtime_turn_status` | Get the current turn state for a runtime session |
| `runtime_events_poll` | Poll the runtime event stream using a cursor |
| `runtime_approval_respond` | Approve or deny a pending runtime tool-use request |

### Resources (4 endpoints)

| URI | Description |
| --- | --- |
| `chau7://telemetry/runs` | Latest 20 telemetry run summaries |
| `chau7://telemetry/sessions` | AI session index with metadata |
| `chau7://telemetry/sessions/current` | Currently active AI sessions |
| `chau7://telemetry/runs/<run_id>` | Specific run details by ID |

## API Analytics & Token Tracking

- **TLS/WSS proxy** — Go-based `chau7-proxy` intercepts API calls to Claude, OpenAI (Codex), Gemini, Anthropic with TLS and WebSocket support.
- **Token counting & cost calculation** — input/output tokens per call with aggregate cost.
- **Latency tracking** — total request duration and time-to-first-token (TTFT) per API call.
- **Task detection & assessment** — auto-detect AI task candidates with confidence scoring; approve or fail with notes.
- **Baseline estimator** — calculate token savings from context caching.
- **Analytics dashboard** — command stats, error rates, API usage, and timing.
- **Repo-aware debug labels** — per-tab token and CTO rows use `provider/custom title + repo`, with split-session disambiguation when needed.
- **Timeline visualization** — scrubber timeline showing command blocks and metrics.
- **Provider filtering** — include or exclude specific API providers.
- **Correlation headers** — `X-Chau7-Context-Pack`, `X-Chau7-Tab-ID`, `X-Chau7-Project` for tracing.

## Tabs, Panes & Windows

### Tabs

- Unlimited tabs per window — `Cmd+T` to create, `Cmd+1–9` to jump.
- Tab renaming (`Cmd+Shift+R`), 12+ colors, reordering via drag or shortcuts with center-crossing snap thresholds.
- AI agent logos, git branch indicator, directory path, last command badge.
- Broadcast input to all tabs with per-tab exclusion and visual indicator.
- Background rendering suspension for inactive tabs (configurable delay).
- Close other tabs (`Cmd+Opt+W`), configurable new tab position.

### Split Panes

- Horizontal (`Cmd+Opt+H`) and vertical (`Cmd+Opt+V`) splits with draggable dividers.
- Arbitrary nesting via binary tree layout controller.
- Built-in text editor in split panes — syntax highlighting, line numbers, bracket matching, find/replace.
- Multi-language syntax: HTML, CSS, JavaScript, Python, and more.

### Windows

- **Overlay / floating terminal** — on top of all apps with blur background.
- **Dropdown terminal** — `Ctrl+`` quake-style with configurable height.
- Multiple windows (`Cmd+N`), adjustable opacity, native fullscreen.
- Minimal mode — strip all chrome for maximum terminal space.
- Window position memory per workspace, session restoration on relaunch.
- Menu bar only mode — no Dock icon.

## Productivity

### Search

- Find overlay (`Cmd+F`) with regex and case sensitivity toggles.
- Visual match highlighting across terminal output.
- `Cmd+G` / `Cmd+Shift+G` navigation, `Cmd+E` to search from selection.

### Command Safety

- **Dangerous command guard** — intercepts `rm -rf`, `dd`, `mkfs`, etc. with confirmation.
- Custom danger patterns via regex.
- Visual highlighting of dangerous commands in output.

### Path & URL Handling

- `Cmd+click` on file paths (line:column supported) and URLs.
- Configurable action: browser (Safari, Chrome, Firefox, Edge, Brave, Arc), editor, or Finder.

### Keyboard & Clipboard

- Fully customizable keybindings with interactive editor and conflict detection.
- Vim and Emacs presets.
- Clipboard history (`Cmd+Shift+V`) — 100 entries, LRU eviction, pinning.
- Paste escaping for shell-sensitive characters ($, backticks, quotes).

### Snippets

- Snippet manager (`Cmd+;`) — create, edit, delete, import, export.
- Three scopes: global (user), per-SSH-profile, per-repo (`.chau7/config.toml`).
- Placeholder support: `${cursor}` and `${selection}`.

### History & Bookmarks

- Per-tab and global command history (arrow keys and `Cmd+Up/Down`).
- SQLite-backed persistence — searchable and fast.
- Session analytics: command frequency, timing, success rates.
- Terminal bookmarks — pin positions and navigate back.

### Command Palette

- `Cmd+Shift+P` — fuzzy-searchable command palette (VS Code style).

### Notifications

- Native macOS desktop notifications for task completion, failures, permissions.
- Dock badge and bounce (critical/non-critical).
- Configurable sounds (Glass, Purr, etc.) with volume control.
- Command idle detection with configurable threshold. Fires once per session, resets only on real user activity.
- Auto tab styling on events with auto-clear timeout. Deduplicates redundant re-applies, clears persistent approval styling as soon as the approval is resolved, and can highlight every affected tab for file conflicts.
- Visual bell mode (screen flash), combinable with audible bell.
- Bell rate limiting with configurable minimum interval, scoped per trigger and tab/session/directory identity.
- Rate limiting and per-trigger enable/disable.
- Process exit confirmation on Cmd+Q with running process name listing.
- Isolated test mode disables notification-center integration to keep side effects out of the test app.

## Appearance & Theming

- Full color schemes: 16 ANSI + background, foreground, cursor, selection.
- Light / dark / system theme modes.
- 100+ monospace fonts — system, popular coding fonts, or any installed font.
- Font size 8–72pt, per-tab zoom (`Cmd++/-`, 50–200%), adjustable line spacing.
- Command blocks — colored left-border gutter (green success, red fail, blue running).
- Optional line timestamps (multiple formats).
- Optional JSON pretty-print in terminal output.
- Font ligature rendering: CoreText-based multi-character shaping for coding fonts (Fira Code, JetBrains Mono, Cascadia Code).
- Cursor blink rate (0.3–2.0s) and custom cursor color (hex).
- Unicode ambiguous-width: treat East Asian ambiguous characters as 1 or 2 cells.
- Menu bar only mode — hide from Dock and Cmd+Tab.
- Floating window mode — keep terminal above other apps.

## Settings & Configuration

- Comprehensive settings UI with fuzzy search across 100+ settings.
- Settings profiles — save, load, export, import named configurations.
- Per-folder config: `.chau7/config.toml` in any repo for project-specific settings.
- Config file watcher — auto-reload on changes, no restart needed.
- Optional iCloud sync across devices.
- Reset individual settings or all to defaults.

## Accessibility & Localization

- Full VoiceOver support.
- Respects High Contrast and Reduced Motion system preferences.
- 4 languages: English, French, Arabic, Hebrew — with proper RTL layout.
- Runtime language switching without restart.

## SSH, Profiles & Remote

### SSH

- Connection manager — saved hosts, ports, identity files, jump hosts (ProxyJump).
- Auto-import from `~/.ssh/config` with file watching.

### Profiles

- Auto-switching based on directory, SSH host, or environment variables.
- Per-profile color scheme, shell, font, and keybindings.

### Remote (Experimental)

- Read-only remote terminal sharing with viewer approval flow.
- Cloudflare Workers relay — no port forwarding required.
- Session recording with timestamps and timeline scrubber.
- Remote activity projection — macOS reduces AI event streams into one authoritative activity state for remote clients.
- iPhone Live Activity / Dynamic Island support via the Chau7 Remote app for running, waiting-input, completed, and failed states.
- Interactive remote prompts — detected Claude and Codex terminal prompts appear in the iPhone Approvals tab with option buttons that reply to the correct tab. Destructive options require a second confirmation before sending.
- Background keepalive mode — when Chau7 Remote backgrounds, the session can briefly stay alive in approvals-only mode instead of streaming full terminal traffic.
- Push-backed remote approvals — the relay and remote helper can register an iPhone push token and wake the Chau7 Remote app when new approvals or interactive prompts appear.
- Experimental Rust iPhone renderer — Chau7 Remote can render a true terminal grid on iPhone using the shared Rust terminal core, with a text fallback kept available.
- Selected-tab-only streaming — macOS streams terminal output and snapshots only for the tab currently selected on iPhone; background tabs stay metadata/activity/approvals-only until switched to.
- Remote profiling hooks — the iPhone app emits `os_signpost` intervals for frame processing, output append, and ANSI stripping so receive/render lag can be measured in Instruments.

### Isolated Testing

- Isolated test app builder creates a separate `Chau7 Test.app` with its own bundle ID and embedded home root.
- Chau7-owned state is redirected: `UserDefaults`, `~/Library/Application Support`, `~/Library/Logs`, `~/.chau7`, and keychain service names.
- Safe for side-by-side manual testing of Chau7 itself without touching the main app's local storage.

## Scripting & Debugging

### Scripting API

- JSON-RPC Unix socket API — control tabs, run commands, query history, manage snippets, modify settings.

### Debugging

- Debug console (`Cmd+Shift+D`) — State, Contexts, Events, Logs, Report tabs.
- Data Explorer (`Cmd+Shift+D`) reloads its history and telemetry content whenever the singleton window is reopened.
- Sessions Explorer rows use the latest run metadata for provider and repo labels.
- Live state inspector for tabs, sessions, and models.
- Feature profiler with os.signpost integration.
- Structured logging with category-based filtering and correlation IDs.
- One-click bug report generator with full app state snapshot.
- Verbose (`CHAU7_VERBOSE=1`) and trace (`CHAU7_TRACE=1`) modes.

### Monitoring

- Dev server detection by port scanning.
- Git branch change notifications.
- Shell event pattern matching with custom regex.
- Directory change detection.

## Keyboard Shortcuts

### Window and Tabs

| Shortcut | Action |
| --- | --- |
| Cmd+N | New window |
| Cmd+T | New tab |
| Cmd+W | Close tab |
| Cmd+Shift+W | Close window |
| Cmd+Option+W | Close other tabs |
| Cmd+1-9 | Select tab 1-9 |
| Cmd+Shift+] | Next tab |
| Cmd+Shift+[ | Previous tab |
| Cmd+Option+Right | Next tab |
| Cmd+Option+Left | Previous tab |
| Ctrl+Tab | Next tab |
| Ctrl+Shift+Tab | Previous tab |
| Cmd+Option+Shift+] | Move tab right |
| Cmd+Option+Shift+[ | Move tab left |
| Cmd+Shift+R | Rename tab |
| Cmd+/ | Keyboard Shortcuts |

### Editing and Search

| Shortcut | Action |
| --- | --- |
| Cmd+C | Copy (or interrupt if no selection) |
| Cmd+V | Paste |
| Cmd+Option+V | Paste escaped |
| Cmd+X | Cut (copy) |
| Cmd+A | Select all |
| Cmd+F | Find |
| Cmd+G | Find next |
| Cmd+Shift+G | Find previous |
| Cmd+E | Use selection for find |
| Cmd+; | Snippets |
| Cmd+Shift+P | Command palette |

### View and Terminal

| Shortcut | Action |
| --- | --- |
| Cmd+K | Clear screen |
| Cmd+Shift+K | Clear scrollback |
| Cmd+= | Zoom in |
| Cmd+- | Zoom out |
| Cmd+0 | Actual size |
| Cmd+Ctrl+F | Toggle full screen |

### App and Tools

| Shortcut | Action |
| --- | --- |
| Cmd+, | Settings |
| Cmd+Shift+D | Debug console |
| Cmd+Shift+O | SSH connections |
| Cmd+Shift+S | Export text |
| Cmd+P | Print |
| Esc | Close overlays (search, rename, snippets, etc.) |
| Ctrl+` | Toggle dropdown terminal (if enabled) |

## File Locations

| Purpose | Path |
| --- | --- |
| AI event log | `~/.ai-events.log` |
| Claude history log | `~/.claude/history.jsonl` |
| Codex history log | `~/.codex/history.jsonl` |
| Claude Code events | `~/.chau7/claude-events.jsonl` |
| MCP socket | `~/.chau7/mcp.sock` |
| MCP bridge binary | `~/.chau7/bin/chau7-mcp-bridge` |
| App log | `~/Library/Logs/Chau7.log` |
| Codex PTY log | `~/Library/Logs/Chau7/codex-pty.log` |
| Claude PTY log | `~/Library/Logs/Chau7/claude-pty.log` |
| PTY capture log | `~/Library/Logs/Chau7/pty-capture.log` |
| Global snippets | `~/.chau7/snippets.json` |
| Profile snippets | `~/.chau7/profile-snippets.json` |
| Repo snippets | `.chau7/snippets.json` |
| Repo config | `.chau7/config.toml` |
| Bug reports | `~/.chau7/reports/` |
| State snapshots | `~/.chau7/snapshots/` |
| LaunchAgent sample | `apps/chau7-macos/LaunchAgent/com.chau7.plist` |

## Environment Variables

| Variable | Description |
| --- | --- |
| CHAU7_EVENTS_LOG | Path to AI events JSONL log |
| CHAU7_CODEX_HISTORY_LOG | Path to Codex history JSONL |
| CHAU7_CLAUDE_HISTORY_LOG | Path to Claude history JSONL |
| CHAU7_IDLE_SECONDS | Command idle threshold for overlay sessions |
| CHAU7_IDLE_STALE_SECONDS | Stale session threshold for history logs |
| CHAU7_CODEX_TERMINAL_LOG | Path to Codex PTY log |
| CHAU7_CLAUDE_TERMINAL_LOG | Path to Claude PTY log |
| CHAU7_TERMINAL_NORMALIZE | Normalize PTY log output (0 disables) |
| CHAU7_TERMINAL_ANSI | Render ANSI in PTY log viewer (0 disables) |
| CHAU7_LOG_FILE | Override app log file path |
| CHAU7_LOG_MAX_BYTES | Max app log size before trimming (default 10MB) |
| CHAU7_VERBOSE | Verbose logging (1 enables) |
| CHAU7_TRACE | Trace logging (1 enables) |
| CHAU7_CLEAR_ON_LAUNCH | Disable clear-on-launch when set to 0/false |
| CHAU7_PTY_DUMP | Enable raw PTY capture (1 enables) |
| CHAU7_TRACE_PTY | Same as CHAU7_PTY_DUMP |
| CHAU7_PTY_DUMP_PATH | Override PTY capture log path |
| CHAU7_PTY_DUMP_MAX_BYTES | Max PTY capture log size before trimming (default 20MB) |

Legacy `AI_*` and `SMART_OVERLAY_*` environment variables are still supported.

## Migration

- Import profiles from Terminal.app and iTerm2 (auto-detected).
- Guided first-run setup.
- Contextual power user tips.

## Architecture

```
Chau7/
├── apps/
│   ├── chau7-macos/
│   │   ├── Sources/Chau7/       # 158 Swift files, 32 directories
│   │   ├── Sources/Chau7Core/   # 26 pure-function files (testable)
│   │   ├── Tests/               # 701 unit tests
│   │   ├── rust/                # Rust terminal backend (chau7_terminal, chau7_parse)
│   │   ├── chau7-proxy/         # Go TLS/WSS API proxy
│   │   └── Package.swift
│   └── chau7-ios/               # Native iOS companion
├── services/
│   ├── chau7-relay/             # Cloudflare Workers relay
│   └── chau7-remote/            # Go remote agent
└── docs/
```

Key patterns:
- ObservableObject for state management.
- Singleton managers for shared features.
- Pure functions in Chau7Core for testability.
- Correlation IDs for trace logging.
- Binary tree layout for split pane nesting.
- MCP server with thread-safe main-thread dispatch.

## Recent Remote UX

- iPhone approvals and approval notifications now include richer decision context from macOS remote tabs:
  - project and branch
  - working directory
  - recent command context from shell integration / OSC 133-backed command tracking
  - MCP permission-source notes when relevant

## Recent Runtime Safety

- Shell JSON-RPC sessions now preserve argv boundaries when launching the generic shell backend, so quoted user arguments stay literal instead of being reinterpreted by the shell.
- Claude runtime sessions now keep separate bindings for same-directory agent tabs, so tool events, approval prompts, and finished notifications stay attached to the correct tab after another session opens in the same repo.
- On termination, Chau7 clears persisted tab/window state and backup files when every overlay window has been hidden or closed, preventing stale windows from resurrecting on next launch.
- Notification pipeline optimizations now respect disabled single-action rules instead of promoting them to native default notifications.

## Recent Tab Behavior

- Reopen Closed Tab now restores the original overlay tab identity metadata, including the tab ID, creation timestamp, and repo grouping membership.

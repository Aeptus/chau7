# Chau7 Features

See your coding agents, know what they cost, steer them from the outside. A macOS terminal built for people running AI across models.

> See also: [features.csv](features.csv) for the machine-readable feature inventory.
>
> Canonical docs live in [../../../docs/README.md](../../../docs/README.md).

## Table of Contents

- [AI Detection & Integration](#ai-detection--integration)
- [API Analytics & Token Tracking](#api-analytics--token-tracking)
- [MCP Server](#mcp-server)
- [MCP Tools](#mcp-tools)
- [Terminal Core](#terminal-core)
- [Performance](#performance)
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
- [Migration](#migration)
- [Architecture](#architecture)

---

## AI Detection & Integration

### Auto-Detection

Chau7 recognizes AI CLIs the moment they launch — no configuration required:

- **Claude** (claude, claude-code, claude-cli)
- **Codex** (codex, codex-cli, codex-pty)
- **Gemini** (gemini, gemini-cli)
- **ChatGPT** (chatgpt, gpt, openai)
- **GitHub Copilot** (copilot, gh copilot)
- **Aider** (aider)
- **Cursor** (cursor)
- **Windsurf** (windsurf)
- **Cline** (cline)
- **Cody** (cody, sourcegraph)
- **Amazon Q** (amazon-q, q)
- **Devin** (devin)
- **Continue** (continue)
- **Goose** (goose)
- **Mentat** (mentat)
- **Amp** (amp)
- Custom-defined tools with display name, tab color, and logo.

Detection methods:
- Command line tokenization with wrapper skipping (env, sudo, npx, bunx, pnpm). Command detection gates output scanning to prevent false positives.
- Output banner matching for all supported CLIs. Patterns require tool-specific context to avoid substring collisions.
- Custom detection rules with display name, tab color, and logo.

### AI Features

- **Branded tab logos** — each detected agent gets its logo in the tab.
- **Auto tab theming** — tabs adopt the brand color of the active AI agent.
- **LLM error explanation** — one-click error analysis via OpenAI, Anthropic, Ollama, or custom endpoint.
- **Claude Code deep integration** — monitor hook events: prompts, tools, permissions, responses.
- **AI event notifications** — finished, failed, permission, needs_validation, tool_complete, session_end, idle. Default policy: finished, failed, and permission. Noisier triggers available in settings.
- **Multi-provider event normalization** — Claude, Codex, and terminal sources translate provider-specific events into one shared semantic layer. Authoritative events from runtime and hooks take priority over history-derived fallbacks.
- **Session-aware notification routing** — notifications route by exact AI session ID with fallback to provider/title heuristics. Handles tab restoration, split sessions, nested working directories, and cross-tab file conflicts.
- **AI-first notification settings** — simplified overview for Finished, Failed, and Permission Request with direct controls for banner, tab highlight, sound, and dock bounce. Waiting-input and attention-required states surface as “needs me” attention. Per-tool overrides and advanced trigger plumbing available separately.
- **Notification delivery ledger** — lifecycle tracking for debugging: coalescing, retry scheduling, drop reasons, and real UI outcomes.
- **PTY output logging** — capture raw terminal output for AI tool sessions.
- **Codex session resolver** — maps Codex sessions to working directories with LRU caching.

### Context Token Optimization (CTO)

Built-in token optimizer (`chau7_optim`, forked from [RTK](https://github.com/rtk-ai/rtk)) that rewrites CLI output to minimize LLM context consumption. ~40% token savings on average.

- Per-tab or global CTO mode with flag files that AI tools read.
- Runtime monitor: decision counts, mode changes, deferred operations, health assessment.
- MCP-controllable via `tab_set_cto`.
- Ultra-compact mode for maximum savings.
- Token savings tracking with daily/weekly/monthly graphs.

Supported commands (46 parsers):

| Category | Commands |
| --- | --- |
| Version control | `git` (status, diff, log, show, blame, stash, etc.), `gh` (pr, issue, run, repo) |
| Build tools | `cargo`, `go`, `swift`, `npm`, `pnpm`, `pip` |
| Test frameworks | `pytest`, `vitest`, `playwright` |
| Linters/formatters | `golangci-lint`, `ruff`, `prettier`, `tsc`, `eslint`/`biome` |
| File operations | `find`, `ls`, `tree`, `grep`, `wc`, `diff`, `read` |
| Data tools | `jq`, `curl`, `wget` |
| DevOps | `prisma`, `next` (Next.js), `docker`, `kubectl` |
| System | `env`, `tee`, `log` |

### History Storage

- Persistent SQLite-backed AI session and command history with reliable clear-all semantics.

## API Analytics & Token Tracking

- **TLS/WSS proxy** — Go-based `chau7-proxy` intercepts API calls to Claude, OpenAI (Codex), Gemini, Anthropic with TLS and WebSocket support.
- **Token counting & cost calculation** — full token breakdown per call: input, output, cache creation, cache read, and reasoning tokens. Accurate cost calculation using provider-specific cache pricing (Anthropic 0.1x/1.25x, OpenAI 0.5x). Fallback estimation when extraction fails.
- **Latency tracking** — total request duration and time-to-first-token (TTFT) per API call.
- **Task detection & assessment** — auto-detect AI task candidates with confidence scoring; approve or fail with notes.
- **Baseline estimator** — calculate token savings from context caching.
- **Analytics dashboard** — command stats, error rates, API usage, and timing. Adaptive polling (2s active, 5s idle, 10s no agents), proxy health monitoring, timeline pagination, and per-agent cost display with cache/reasoning token breakdown.
- **Repo-level aggregated metrics** — per-repository stats (commands, success rate, AI runs, tokens, cost, providers, top tools) in Debug Console, Data Explorer, and hover card.
- **Repo-aware debug labels** — per-tab token and CTO rows use `provider/custom title + repo`, with split-session disambiguation when needed.
- **Timeline visualization** — scrubber timeline showing command blocks and metrics.
- **Provider filtering** — include or exclude specific API providers.
- **Correlation headers** — `X-Chau7-Context-Pack`, `X-Chau7-Tab-ID`, `X-Chau7-Project` for tracing.

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

### Tab Management (11 tools)

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
| `tab_rename` | Set a custom title for a tab — pass empty string to clear |

### Repository (4 tools)

| Tool | Description |
| --- | --- |
| `repo_get_metadata` | Get metadata for a repository including description, labels, favorite files, and frequent commands |
| `repo_set_metadata` | Set metadata for a repository (description, labels, favorite files) — only provided fields are updated |
| `repo_frequent_commands` | Get frequently used commands for a repository, sorted by frecency |
| `repo_get_events` | Get recent AI tool events (finished, permission, tool_called, etc.) scoped to a given repo |

### Telemetry (8 tools)

| Tool | Description |
| --- | --- |
| `run_get` | Get a single telemetry run by ID (active or from store). Responses include `run_state` (`active`/`completed`) and `content_state` (`missing`/`partial`/`final`) so callers can distinguish live partial sessions from finalized runs |
| `run_list` | List runs with filters: session_id, repo_path, provider, parent_run_id, date range, tags, limit/offset. Active runs are deduplicated against persisted rows before pagination |
| `run_tool_calls` | Get all tool calls for a run — see exactly what an AI agent did |
| `run_transcript` | Full conversation transcript for a run. Active Codex sessions fall back to live prompts from `~/.codex/history.jsonl`; TUI sessions then fall back to ANSI-stripped PTY log, then terminal buffer |
| `run_tag` | Set tags on a run for organization and filtering |
| `run_latest_for_repo` | Most recent run for a repository — optionally filter by provider |
| `session_list` | List AI sessions with run counts — filter by repo_path, active_only. Responses include `active_run_count`, `completed_run_count`, `latest_run_id`, and `latest_run_state` |
| `session_current` | Get currently active AI sessions across all tabs |

### Runtime API (13 tools)

| Tool | Description |
| --- | --- |
| `runtime_session_create` | Start or attach an agent session in Chau7 and return a runtime session ID. Supports delegated-task metadata, structured result schemas, and session policy limits |
| `runtime_session_list` | List runtime sessions, with optional inclusion of recently stopped sessions |
| `runtime_session_get` | Get detailed state for one runtime session |
| `runtime_session_stop` | Stop a runtime session and optionally close its tab |
| `runtime_session_children` | List direct child sessions or full descendant trees for a delegated parent session |
| `runtime_session_cancel_children` | Stop all active descendant sessions for a delegated parent session |
| `runtime_session_retry` | Clone an existing runtime session configuration into a fresh session, optionally resubmitting the last prompt |
| `runtime_turn_send` | Send a formatted prompt to a runtime session, including adopted sessions discovered from existing tabs and optional turn-specific result schemas |
| `runtime_turn_status` | Get the current turn state for a runtime session |
| `runtime_turn_result` | Fetch the latest structured result captured for a completed turn, with telemetry fallback for transcript-derived results |
| `runtime_turn_wait` | Wait for the current or requested turn to finish and return an updated status payload |
| `runtime_events_poll` | Poll the runtime event stream using a cursor |
| `runtime_approval_respond` | Approve or deny a pending runtime tool-use request |

### Resources (4 endpoints)

| URI | Description |
| --- | --- |
| `chau7://telemetry/runs` | Latest 20 telemetry run summaries |
| `chau7://telemetry/sessions` | AI session index with metadata |
| `chau7://telemetry/sessions/current` | Currently active AI sessions |
| `chau7://telemetry/runs/<run_id>` | Specific run details by ID |

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
- Repository tab grouping: group tabs by git repo (Off/Auto/Manual). Shows inline repo-name tag chip with connecting line. Suppresses redundant repo path in tab titles, and inherited group membership auto-detaches when a tab moves to a different repo, including tabs opened directly at another directory.
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

## Tabs, Panes & Windows

### Tabs

- Unlimited tabs per window — `Cmd+T` to create, `Cmd+1–9` to jump.
- Tab renaming (`Cmd+Shift+R`), 12+ colors, reordering via drag or shortcuts with center-crossing snap thresholds.
- AI agent logos, git branch indicator, directory path, last command badge.
- Broadcast input to all tabs with per-tab exclusion and visual indicator.
- Background rendering suspension for inactive tabs (configurable delay).
- Close other tabs (`Cmd+Opt+W`), configurable new tab position.
- Shortcut helper hint box (`⌘/` and `⌥⌘I`) floats 4pt from tab bar bottom and window right edge.

### Split Panes

- Horizontal (`Cmd+Opt+H`) and vertical (`Cmd+Opt+V`) splits with draggable dividers.
- Arbitrary nesting via binary tree layout controller.
- Built-in text editor in split panes — syntax highlighting, line numbers, bracket matching, find/replace.
- Click-to-copy document name in the editor pane header.
- Multi-language syntax: HTML, CSS, JavaScript, Python, and more.
- Repository pane (`Cmd+Opt+B`): full git UI — stage, commit (⌘Enter), branch, push/pull, stash, history with search. Session-aware: shows only agent-touched files with diff stats when an AI is active, resets after push. Ahead/behind indicator, hover tooltips, conventional commit chips.

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
- Tab highlights for all user-facing event types: permission, waiting_input, finished, failed, idle, tool_failed, response_failed, elicitation, attention_required, error, context_limit.
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
- 5 languages: English, French, Spanish, Arabic, Hebrew — with proper RTL layout across all windows.
- RTL layout direction propagated at every NSHostingView boundary — overlay, settings, command palette, data explorer, help docs, bug report, splash, and all auxiliary windows.
- Runtime language switching without restart.
- Full translation coverage: all UI strings localized with zero untranslated gaps across en, fr, ar, he — including NSMenuItem context menus, hover cards, and agent dashboard.
- Final shipped-key sweep completed for English, French, Arabic, and Hebrew bundles — settings search copy, dashboard strings, alert text, snippets examples, and long-form help topics now ship localized with parity and format-specifier checks passing.
- Final locale polish leaves only intentional shared identities in English across fr/ar/he, such as product names, browser names, protocol literals, file paths, and raw placeholder-only values.

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
- Review automation is built from scripting tab/session primitives such as `create_tab`, `run_command`, `get_tab`, `send_input`, `submit_prompt`, `get_output`, `close_tab`, and the generic session helpers.
- Repo-local pre-commit review automation via `Scripts/pre-commit-review`, which creates a review tab, launches Codex, waits for the app to become interactive, sends the staged-diff prompt, validates and submits it, polls PTY output for the final structured JSON block, and prints findings in hook-friendly terminal output.
- Per-repo pre-commit review policy via `.chau7/pre-commit-review.conf` with gate modes (`off`, `advisory`, `high`, `any`), timeout, backend, and model selection. The shipped default reviewer model is `gpt-5.3-codex`.
- Optional verbose tracing for the hook via `--verbose` or `CHAU7_PRE_COMMIT_REVIEW_VERBOSE=1`, including per-step scripting timings and fallback decisions.

### Debugging

- Debug console (`Cmd+Shift+D`) — 10 tabs: State, Token Optimizer, Events, Lag, Perf, Logs, Report, Analytics, Health, Repos.
- Notification reliability dashboard — Debug Console health view summarizes recent completed, dropped, retried, rate-limited, and authoritative notification deliveries.
- Data Explorer (`Cmd+Shift+D`) reloads its history and telemetry content whenever the singleton window is reopened.
- Sessions Explorer rows use the latest run metadata for provider and repo labels.
- Live state inspector for tabs, sessions, and models.
- Feature profiler with os.signpost integration.
- Structured logging with category-based filtering and correlation IDs.
- Privacy-first bug report dialog (⌥⌘I): all sensitive data off by default, per-toggle tab pickers, live preview, HTTPS-only submission via relay, success banner with created issue number when available, tab title redaction, background history capture, no AI session fallback leak.
- In-app issue reporting privacy page: GDPR-compliant sub-processor disclosure (Cloudflare, GitHub) with data categories, retention, legal basis, DPA links, and data subject rights.
- Technology, Licenses & Acknowledgments help page: monorepo layout, languages, Rust crates, bundled binaries, third-party dependencies, system frameworks, and notice file locations. Accessible from Help menu and About settings.
- Verbose (`CHAU7_VERBOSE=1`) and trace (`CHAU7_TRACE=1`) modes.

### Monitoring

- Dev server detection by command hints, output patterns, and port scanning with 30s liveness polling. Handles server restarts, slow starts, and external kills.
- Git branch change notifications.
- Shell event pattern matching with custom regex.
- Directory change detection.
- Power efficiency: adaptive clipboard polling, shared background drain timer, event-driven focus/DND detection, timer leeway coalescing, 5-minute wakeup stats logging.

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
| Repo pre-commit review config | `.chau7/pre-commit-review.conf` |
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
| CHAU7_PRE_COMMIT_REVIEW_CONFIG | Override the repo pre-commit review config path |
| CHAU7_PRE_COMMIT_REVIEW_ENABLED | Enable or disable delegated pre-commit review without editing the hook |
| CHAU7_PRE_COMMIT_REVIEW_GATE | Override pre-commit gate mode: `off`, `advisory`, `high`, or `any` |
| CHAU7_PRE_COMMIT_REVIEW_TIMEOUT_MS | Override the delegated review timeout in milliseconds |
| CHAU7_PRE_COMMIT_REVIEW_MODEL | Override the delegated reviewer model (defaults to `gpt-5.3-codex`) |
| CHAU7_PRE_COMMIT_REVIEW_BACKEND | Override the delegated review backend (defaults to `codex`) |

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
│   │   ├── Sources/Chau7/       # app code (SwiftUI, AppKit, runtime, notifications, telemetry)
│   │   ├── Sources/Chau7Core/   # pure logic and shared testable components
│   │   ├── Tests/               # unit and integration coverage
│   │   ├── rust/                # Rust workspace (chau7_terminal, chau7_parse, chau7_optim, chau7_md)
│   │   ├── chau7-proxy/         # Go TLS/WSS API proxy
│   │   └── Package.swift
│   └── chau7-ios/               # Native iOS companion
├── services/
│   ├── chau7-relay/             # Cloudflare Workers relay
│   └── chau7-remote/            # Go remote agent + protocol docs
└── docs/                        # Shared top-level docs only
```

Key patterns:
- `@Observable` macro for state management (Swift Observation framework).
- Singleton managers for shared features.
- Pure functions in Chau7Core for testability.
- Correlation IDs for trace logging.
- Binary tree layout for split pane nesting.
- MCP server with thread-safe main-thread dispatch.
# Features

- SwiftPM package metadata excludes `Performance/SIMDTerminalParser.swift` from doc/resource scanning so builds keep the SIMD parser as source instead of trying to bundle it as documentation.
- Background terminal snapshots can fall back to cached remote transcript text when the live terminal view is detached, and notification trigger/style logic now treats elicitation plus tool/response failures as first-class interactive events.
- `tab_output` can read a fresher active AI PTY log tail for MCP-driven tabs, improving retrieval of live Codex and Claude responses.
- PTY log tail parsing normalizes terminal control sequences and backspaces before downstream consumers read the transcript.

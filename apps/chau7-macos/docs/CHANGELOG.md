# Changelog

All notable changes to Chau7 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Spanish Language Support**: Full Spanish (es) locale with 2,612 translated keys and 41 .stringsdict plural entries. Informal "tú" form, standard Spanish computing vocabulary. Accessible from Settings > General > Language.

### Fixed
- **Pricing Table Accuracy**: Fixed wrong prices for Claude Opus 4.6 ($15→$5/$75→$25), Haiku 4.5 ($0.80→$1/$4→$5), and Gemini 2.0 Flash (free→$0.10/$0.40 paid tier). Added ~20 missing models (GPT-5.x, GPT-4.1, o3/o4-mini, Gemini 2.5). Unknown models now log a warning with the model name instead of failing silently. Gemini fallback uses Flash pricing instead of free tier.
- **Dashboard Polling Waste**: Dashboard now polls adaptively — 2s when agents are active, 5s when idle, 10s with no agents — instead of a fixed 2s interval that wasted CPU even with zero agents running.
- **Cost Lock Safety**: Replaced bare `costLock.lock()/unlock()` pairs with `defer` pattern to prevent lock leaks on unexpected errors.
- **Commit Success Stale**: The "Committed successfully" banner now auto-dismisses after 3 seconds instead of persisting indefinitely.
- **IPC Data Loss**: Proxy IPC socket now retries once on a broken connection before giving up, preventing silent data loss after app restarts.
- **Event Buffer Performance**: Replaced O(n) `insert(at: 0)` in ProxyIPCServer's event buffer with O(1) append + reverse-on-read.
- **DB Query Performance**: Added compound index `(timestamp, cost_usd)` for `dailyTrend()` queries. Added `ANALYZE` after migrations to update SQLite's query planner. Added automatic pruning of API call records older than 180 days.
- **Proxy Health Monitoring**: Dashboard now calls the proxy's existing (but unused) `/health` endpoint every 5th poll cycle and shows a warning triangle in the header when unhealthy.
- **Dashboard Sheet Sizing**: Start Agent and Review Commits sheets now use adaptive widths (min/ideal/max) instead of hardcoded pixel values that broke on small displays.
- **Timeline Pagination**: Dashboard timeline now shows a "Show more..." button when more than 50 events exist, instead of silently truncating.
- **Bug Report Success Feedback**: The in-app issue reporter now formats the relay-returned issue number correctly in its success banner and falls back to a generic success message if no number is returned.
- **Inherited Repo Group Stickiness**: Tabs created from a grouped tab now drop inherited repo-group membership once they move to a different repository, instead of staying stuck to the original group.
- **Directory-Based Inherited Repo Groups**: `newTab(at:)` now installs the same repo-group observer as standard new tabs, so grouped tabs opened directly into another directory also detach correctly when they resolve to a different repository.
- **Protected Repo Identity Collapse**: Tabs in protected folders now preserve known repo root and last-known branch even when live git probing is blocked, so passive UI stays repo-aware instead of falling back to “not a repo.”
- **Passive Protected Repo Chrome**: The selected-tab branch badge, tab git indicator, hover-card branch row, and repo path label now read cached repo identity when live git probing is blocked, so protected repos stay visible in passive tab chrome instead of disappearing after restore or focus changes.
- **Protected Repo Branch Persistence**: Recent-repo updates and settings import no longer downgrade known repo identities to root-only entries, so a protected repo's last-known branch survives recents reordering and settings import instead of regressing to `unknown`.
- **On-Demand Protected Git Access**: User-triggered git surfaces such as the repository pane, diff viewer, and diff-viewer launch fallback now request protected-folder access only when live git work is actually needed, instead of prompting during passive observation or silently failing.
- **Repo Dashboard Dismissal Consistency**: Clicking any tab in the overlay toolbar now dismisses the repo dashboard overlay, including clicks on the already-selected tab. The active repo badge is highlighted while its dashboard is open so the overlay state matches the rest of the tab bar.
- **Pre-Commit Review Hook Timeout**: `Scripts/pre-commit-review` now applies explicit Unix-socket timeouts for `start_review`, `wait_review`, and `get_review_result` calls so a stalled scripting server fails fast instead of hanging the whole git commit hook indefinitely.
- **Delegated Review Prompt Recovery**: Interactive delegated review sessions now retain their pending initial prompt until the backend is genuinely ready, and `runtime_turn_wait` re-attempts delivery instead of leaving sessions stranded forever in `starting` after the first readiness polling window expires.
- **Delegated Review Tab Cleanup**: The scripting review API now exposes `stop_review`, and the pre-commit hook always attempts best-effort teardown of its delegated review session so timed-out or malformed review runs do not leave orphaned Codex review tabs behind.
- **MCP Runtime Startup Robustness**: `runtime_session_create` now keeps pending initial prompts tied to real terminal readiness changes instead of a fixed retry loop, so slow interactive launches no longer give up while the session is still legitimately starting.
- **MCP Lifecycle Hot-Path Pressure**: Runtime-driven tab teardown now queues close work off the immediate stop path, and create/stop/close flows emit focused stall diagnostics so MCP-induced beachballs are easier to trace.
- **Release Workflow Secret Gate**: The GitHub release workflow no longer references `secrets.*` from a job-level `if`, so release runs parse cleanly and the Homebrew tap update step now skips gracefully when `HOMEBREW_TAP_TOKEN` is absent.
- **Release Tag Push Guard**: The local `pre-push` hook now rejects plain version tags like `0.1.1` when the release workflow is configured to trigger only on `v*`, preventing non-triggering release tags from being pushed.
- **Codex Resume Save Churn**: Repeated save-time Codex fallback scans now cache unresolved results per terminal session signature and reuse claimed explicit Codex sessions across history growth, which stops autosave from redoing the same replacement search and spamming identical unresolved resume-metadata logs when nothing materially changed.
- **Startup Stall Diagnostics**: Startup and restore now keep a scoped low-latency App Nap lease during relaunch recovery, coalesce duplicate Metal triple-buffer rebuild churn, and emit explicit main-thread stall telemetry when restore or rendering work blocks long enough to explain a beachball.
- **Startup Restore Churn Reduction**: Restore now coalesces protected-folder validation logs per root, debounces transient home-directory snippet-context refreshes, delays resume-prefill fallback until a pane view is actually ready, and emits one startup summary with protected-root, snippet, and resume-prefill counts. This keeps relaunch behavior reactive without dropping repo-aware grouping or snippets.
- **Blocked Dangerous Command Feedback**: Direct terminal input now shows the same explicit blocked-command alert as other dangerous-command paths when `Protect Chau7` denies a self-harming command, instead of failing to compile due to a missing guard method.
- **Dashboard Accessibility**: Agent cards now have combined accessibility labels (backend, state, tokens). Batch action buttons have accessibility hints. Health indicator uses localized strings.
- **Custom Pricing Documentation**: `~/.chau7/pricing.json` format is now documented with a JSON example in code comments. Malformed files now log a warning instead of being silently ignored.
- **Telemetry Active-Run Queries**: `run_list` and `run_get` no longer duplicate active runs that were already inserted into SQLite at `runStarted`. MCP telemetry responses now consistently annotate `run_state` (`active` or `completed`) and `content_state` (`missing`, `partial`, `final`) so orchestrators can distinguish live partial data from finalized runs.
- **Active Codex Transcript Visibility**: `run_transcript` now surfaces live Codex prompts from `~/.codex/history.jsonl` before `runEnded`, with PTY-log fallback for active sessions that do not yet have persisted turns. Active Codex runs no longer appear as empty shells while the session is still in progress.
- **Session Rollup Clarity**: `session_list` now includes `active_run_count`, `completed_run_count`, `latest_run_id`, and `latest_run_state`, making resumed session IDs with multiple historical runs easier to interpret.
- **Forced Shell Termination Diagnostics**: SIGTERM/SIGKILL escalation logs now capture close-to-signal timing, PTY log state, and a process-tree snapshot with command lines so stuck shell shutdowns are actionable instead of opaque.
- **Full Token Tracking**: Proxy now extracts cache creation, cache read, and reasoning tokens from Anthropic, OpenAI, and Gemini API responses (both streaming and non-streaming). Previously hardcoded to 0, causing dashboard to drastically underreport usage with prompt caching.
- **Accurate Cost Calculation**: Cost now accounts for provider-specific cache pricing — Anthropic cache reads at 0.1x input rate, cache writes at 1.25x; OpenAI cached tokens at 0.5x. Previously all tokens were billed at full input rate.
- **Token Estimation Fallback**: When metadata extraction fails on a 200 response, proxy estimates tokens from request/response body sizes (~4 chars/token) instead of silently recording 0.
- **Dashboard Token Display**: Agent cards now show total tokens including cache, with hover tooltip showing per-type breakdown (input/output/cache write/cache read). Per-agent and total cost shown in header.
- **IPC Cache Token Propagation**: `ProxyIPCServerData` and `APICallEvent` now carry `cacheCreationInputTokens`, `cacheReadInputTokens`, and `reasoningOutputTokens` through the full pipeline (proxy → IPC socket → Swift app → dashboard).

### Added
- **Telemetry Query Projection Helpers**: Added shared projection helpers for live-history Codex parsing, active/stored run deduplication, and telemetry content-state evaluation, with regression coverage for duplicate active runs and active transcript parsing.
- **Scripting Review Automation API**: The local scripting socket now exposes `start_review`, `wait_review`, and `get_review_result` so external tools can launch delegated code reviews, wait on completion, and fetch structured findings without speaking MCP directly.
- **Pre-Commit Delegated Code Review**: Added `Scripts/pre-commit-review` plus a `lefthook` pre-commit entry that reviews staged diffs through Chau7 when the scripting socket is available, prints structured findings in hook-friendly output, and can skip open when Chau7 is unavailable.
- **Repo-Level Pre-Commit Review Policy**: Repositories can now ship `.chau7/pre-commit-review.conf` to set the delegated review gate mode (`off`, `advisory`, `high`, `any`), timeout, backend, and optional model override, with environment-variable overrides for CI and local workflows.
- **Default Pre-Commit Reviewer Model**: Delegated staged-diff reviews now default to `gpt-5.3-codex` on the `codex` backend unless the repo config, environment, or CLI flags override the model selection.
- **Structured Delegated Results**: Runtime sessions can now carry JSON-schema-like result contracts, extract structured results from completed turns, and expose them via MCP `runtime_turn_result` with transcript-derived fallback when needed.
- **Delegated Session Policies**: Runtime sessions now support policy objects for max turns, max duration, child delegation, depth limits, and tool allow/block rules. Runtime-owned limits are enforced directly and policy metadata is propagated into child session environments.
- **Delegated Session Lifecycle Tools**: MCP now includes `runtime_session_children`, `runtime_session_cancel_children`, `runtime_session_retry`, and `runtime_turn_wait` so orchestrators can manage delegated task trees without polling raw event streams alone.
- **Dashboard Review Workflow**: The multi-agent dashboard now surfaces delegated lineage and structured-result summaries, and adds a built-in Codex commit-review launcher with a default review schema and review-safe policy defaults.
- **Delegated Runtime Session Metadata**: MCP-created runtime sessions now accept generic delegation fields (`purpose`, `parent_session_id`, `parent_run_id`, `task_metadata`, `delegation_depth`) so parent agents can launch child tasks with explicit lineage instead of repo-wide heuristics.
- **Delegated Telemetry Lineage**: Runtime-managed AI runs now persist delegation lineage and task metadata into telemetry, and MCP `run_list` can filter by `parent_run_id` to fetch exact child runs for a parent task.
- **Staged-Diff Review Templates**: The built-in code review task template now supports staged-diff prompts with explicit staged file lists and patch payloads, so orchestrators can review what is about to be committed instead of only previously created commits.
- **Locale Coverage Completion for New L() Keys**: English, French, Arabic, and Hebrew bundles now include the remaining shipped UI strings added during the recent localization sweep, including settings search/help copy, dashboard copy, alert text, snippets examples, and long-form in-app help topics. Localization parity and translation completeness are back to green with format-specifier safety checks passing.
- **Locale Identity Cleanup Pass**: Final locale polish translated the remaining user-facing labels, alerts, and help titles that were still left in English after the bulk sweep. The remaining identical strings are now limited to intentional identities such as product names, browser names, file paths, protocol literals, and placeholder-only formats.
- **Remote Docs Colocation**: Moved the remote protocol spec next to `services/chau7-remote` and split iOS-specific remote UX and Live Activity notes into `apps/chau7-ios/docs`, removing the old orphaned top-level `docs/remote-control` folder.
- **Doc Ownership Cleanup**: Added a canonical documentation map, collapsed the stale macOS-specific contributing guide into a pointer doc, and removed planning and assessment docs from the public repository so public docs and working notes stop competing.
- **Repository Pane**: Full git UI as a split pane (⌘⌥B). Stage/unstage files, commit (⌘Enter), switch/create/delete branches, push/pull, stash save/pop/drop, commit history with search, merge conflict resolution (accept ours/theirs). Ahead/behind indicator, branch/stash hover tooltips, conventional commit prefix chips, commit message persistence. Session-aware mode: when an AI agent is active, shows only agent-touched files with diff stats, turn summary (tools, tokens, duration), "Ask Agent" commit message button, and resets after push. All operations run via background `Process` with inline error display. Persists across tab restore.
- **Technology, Licenses & Acknowledgments Help Page**: New help topic documenting the monorepo layout, languages, Rust crates, bundled binaries, third-party dependencies (swift-atomics, RTK fork), system frameworks, and notice file locations. Accessible from Help menu and About settings.
- **Third-Party Notices**: Added `THIRD_PARTY_NOTICES.md` and `LICENSE-RTK-APACHE` for RTK dual-license tracking (MIT + Apache-2.0 upstream ambiguity).
- **Privacy-First Bug Report Dialog**: New in-app issue reporter (⌥⌘I) with all sensitive sections off by default, per-toggle tab pickers, live markdown preview, inline privacy warnings, and optional remembered contact info. Submits privately via Cloudflare Worker relay.
- **Issue Reporting Privacy Page**: In-app GDPR-compliant privacy disclosure accessible from the bug report dialog. Lists sub-processors (Cloudflare, GitHub) with data categories, retention, legal basis (Art. 6(1)(f)), international transfer coverage, DPA links, and data subject rights.
- **Relay /issue Endpoint**: Cloudflare Worker `POST /issue` proxies to GitHub Issues API with server-side PAT, Durable Object rate limiting (5/hour/IP), repo path sanitization, and CORS support.
- **Repo-Level Aggregated Metrics**: Per-repository stats (command count, success rate, AI runs, tokens, cost, providers, top tools) computed on demand from both SQLite stores. Surfaced in Debug Console "Repos" analytics tab, Data Explorer enriched rows, and TabHoverCard condensed line (togglable via `hoverCardShowRepoStats`).
- **Click-to-Copy Document Name**: Clicking the file name in the text editor pane header copies it to the clipboard.
- **Notification Delivery Ledger**: Every AI notification event now records an explicit delivery lifecycle (ingested, coalesced, retry scheduled, prepared, dropped, rate-limited, actions executed, completed) with resolved tab, drop reason, and banner/style outcomes.
- **Notification Reliability Dashboard**: Debug surfaces now summarize recent notification completions, drops, retries, rate limits, and authoritative deliveries for faster triage.
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
- **Debug Console Tab Labels**: Per-tab token and CTO sections now use repo-aware labels, and split sessions add a disambiguator when a tab title would otherwise collide.
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

### Changed
- **RTL Layout Direction at All Hosting Sites**: `.localized()` now applied at every `NSHostingView`/`NSHostingController` boundary (13 sites), propagating layout direction to all SwiftUI views. Previously only 4 settings views had it. Removed redundant inner `.localized()` from settings child views that now inherit from their hosting root.
- **Complete i18n Translation Coverage**: Filled all pre-existing translation gaps — French cognates reviewed (6 keys updated: snippets, tags, tokens), Arabic statusBar namespace fully translated (38 keys: session states, timeline events, tool names), Hebrew statusBar namespace fully translated (33 keys). All 4 locales now have zero English-identical values except for legitimate cognates and brand names.
- **Localize All Remaining Hardcoded Strings**: Wrap 75+ user-facing strings with L() across 16 files — NSMenuItem context menus (tab rename/close/move/group), terminal right-click menu, hover card section labels/status, agent dashboard, migration wizard, theme names, about settings, default tab titles, dev server names, and data explorer empty states.

### Fixed
- **Claude Strict Live-Tab Fallback**: When runtime-owned Claude session bindings are missing or stale, authoritative Claude events now fall back to a strict live-session resolver instead of dropping immediately. This recovers exact permission and waiting-input routing from current tab session metadata without reopening heuristic cross-tab matches.
- **Stale Style Delivery Suppression**: Tab-style delivery now checks whether an explicit target tab is still live before trying to style it, and quietly skips vanished tabs after exact-session recovery is exhausted. This removes spurious missing-tab warnings when a tab disappears between notification preparation and style execution.
- **Claude Exact Session Binding**: Claude notification routing now treats exact session IDs as authoritative even when the event cwd is a nested path under the tab repo root or when temporary live-tab metadata lacks `ai_provider=claude`. This prevents real `permission` and `waiting_input` events from dropping just because the tab and hook report slightly different working directories.
- **Notification Auto-Clear on Dead Tabs**: Delayed tab-style cleanup now checks whether the target tab still exists and retries once via exact session lookup before clearing. This removes follow-up `applyNotificationStyle ... not found` noise after a valid notification when a tab moved or closed.
- **Restored Session Prompt Fallback Leak**: Restored AI tabs now suppress terminal prompt `waiting_input` fallback as soon as their provider metadata is restored, not only after resume-prefill delivery. This stops startup tab highlights caused by restored Codex/Claude sessions before any real user command runs.
- **Notification Action Outcome Accounting**: Notification delivery no longer counts tab-scoped actions as successful just because they were requested. Focus, style, badge, and snippet actions now report real success/failure into the delivery ledger and logs, so a notification is always explainable end-to-end.
- **Bug Report Hardening**: Fixed rate limit bypass in relay `/issue` endpoint (DO errors no longer skip throttle), added title length cap, HTTPS enforcement on submission endpoint, removed AI session fallback that leaked all sessions, tab title path redaction, stale window reference cleanup on close, and background-thread terminal history capture.
- **Restore Prefill Notification Noise**: System-injected resume prefills no longer arm prompt-return `waiting_input` notifications during launch/restore. Fallback waiting-input delivery stays suppressed until a real user command runs after the restore flow.
- **Tailed `terminal_session` Notification Spam**: Terminal-session events replayed from the event log no longer re-enter user-facing notification delivery. They still appear in the unified event stream, but live notifications now only come from canonical ingress, not from tailed echoes.
- **History Monitor False Finishes**: Prompt-only Codex and Claude history entries no longer synthesize `finished` events after the idle timeout. History-monitor completions now require response-side activity instead of treating every new user prompt as completed work.
- **Default AI Notification Policy**: AI-facing notification defaults are now stricter. Finished, failed, and permission requests remain enabled by default, while noisy events-log passthrough triggers like `needs_validation`, custom `notification`, and wildcard `other` no longer ship enabled.
- **Runtime Failure Classification**: Non-success runtime exits now emit `failed` instead of generic `error`, so they follow the same default notification and tab-style policy as other AI task failures.
- **Persistent History Clear Ordering**: `clearAll()` now runs on the history queue so queued async inserts cannot repopulate the database after a wipe.
- **Stale Window State Cleanup**: Quitting after all overlay windows are hidden or closed now clears persisted tab/window state and backup files instead of restoring stale windows on next launch.
- **Native Text Pane Edit Shortcuts**: Cut, copy, and paste now try the focused responder first, restoring standard macOS shortcuts inside split-pane text editors before falling back to terminal behavior.
- **International Option Text Input**: Option-based programming characters such as brackets now flow through macOS text input instead of being forced into Meta/Alt escape sequences, fixing entry on international keyboard layouts.
- **TabResolver Session Precedence**: Notification routing now resolves exact AI session IDs before broad tool-label matching and most-recent fallback, which reduces ambiguous matches and helps Codex events reach the correct tab.
- **History Monitor Tab Routing**: Claude and Codex history-monitor idle/finished events now resolve their working directory from session metadata before notifying, so tab styling and notifications can target the correct repo tab.
- **Runtime Session Startup**: Newly created MCP runtime sessions now transition to `ready` after launch, and `attach_tab_id` sessions start usable immediately instead of staying stuck in `starting`.
- **MCP Command Filter Parsing**: Permission checks now split on background operators, tabs, and newlines, closing command-separator bypasses such as `cmd & dangerous` and multiline payloads.
- **Backend Launch Environment Validation**: Runtime backends now ignore invalid environment variable names before building shell launch strings, closing command injection through hostile JSON-RPC env keys.
- **Notification Identity Scoping**: Notification coalescing and rate limiting are now scoped by tab, session, or directory identity instead of only trigger/tool matching. One noisy tab no longer suppresses the same notification on another tab.
- **Approval Attention Lifecycle**: Persistent approval styling now clears when the approval is actually resolved, and split-created terminal sessions inherit the same owner/callback wiring as the original pane so permission indicators do not get stuck.
- **File Conflict Notifications**: Cross-tab file conflicts now emit real `app.file_conflict` events for each affected tab, so the configured notification trigger and orange tab styling actually fire on first detection.
- **Data Explorer Refresh**: Reopening the singleton Data Explorer window now rebuilds its SwiftUI content instead of showing stale history and telemetry from the first time the window was opened.
- **Session Explorer Metadata**: Session rows now derive provider and repo from the latest run for that session instead of SQLite's arbitrary non-grouped values, fixing incorrect badges in the Sessions explorer.
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
- **SwiftTerm References Removed**: All docs, README, architecture diagrams, and code comments now reference the native Rust terminal backend. `SWIFTTERM_FORK.md` deleted. `ARCHITECTURE.md` dependency table updated from SwiftTerm to swift-atomics.
- **RTK License Provenance**: `UPSTREAM-SYNC.md` now documents the MIT/Apache-2.0 ambiguity in RTK upstream and the dual notice file strategy.
- **CI gofmt Check**: `ci-lib.sh` gofmt check now uses explicit binary paths to avoid PATH shadowing.
- **Canonical Notification Coverage for All Sources**: The provider adapter layer now covers every notification source, including shell, app, terminal-session, history-monitor, events-log, and API-proxy events. The shared notification system no longer has pass-through sources outside the canonical adapter boundary.
- **Single Notification Ingress Handoff**: `AppModel` now ingests events once and hands accepted canonical events directly to `NotificationManager`, eliminating the previous double-ingest path between the unified event stream and notification delivery.
- **Strict Notification Delivery Boundaries**: Notification ingress now runs through one shared adapter-backed contract, and tab-targeting actions (`styleTab`, `badgeTab`, `focusTab`, snippet insertion, persistent-style clearing) require an explicitly resolved `tabID`. Notification delivery no longer falls back to late `TabResolver` heuristics inside overlay styling or NotificationCenter side channels.
- **Provider Adapter Notification Layer**: AI provider events are now canonicalized before they enter the shared notification stream. App-level event publishing, event-log tailing, and Claude hook delivery now all flow through provider adapters so settings, history, and tab styling operate on one semantic event model instead of mixed raw provider events.
- **Canonical Notification Name Normalization**: Shared semantic notification mapping now preserves word boundaries when normalizing provider hook names, so values like `permission prompt`, `idle-prompt`, and `auth success` consistently map onto the canonical trigger keys used by adapters and settings.
- **Canonical Notification Ingress**: Provider events are now canonicalized before the delivery ledger and coalescing queue record them, so notification history, debug views, and timeline surfaces keep canonical semantics plus raw-type notes instead of mixing raw provider event names into shared state.
- **Claude Hook Ownership**: Claude `notification` hooks are now the sole user-facing owner for waiting-input and attention-required delivery. Raw Claude `response_complete` events are treated as state-only and no longer light up tabs or fire notifications by themselves.
- **Notification Routing Hardening**: Core AI attention events (`finished`, `failed`, `permission`) now prefer authoritative runtime/hook producers, retry exact routing before fallback, and suppress later fallback duplicates when an authoritative delivery already fired for the same session/tab.
- **AI Notification Settings Simplification**: Notifications settings now open on an AI-first overview with direct controls for Finished, Failed, and Permission Request behavior. The raw trigger/source matrix remains available under Advanced instead of leading the screen.
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
  - Terminal emulation
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

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 0.5.33 | 2026-04-09 | Protected-folder repos now persist repo identity and last-known branch in tab restore state, so restored tabs keep their git badge even when live Downloads/Desktop/Documents access is unavailable |
| 0.5.32 | 2026-04-04 | App termination now reuses a recent cached multi-window snapshot instead of re-exporting every visible tab during quit, reducing synchronous shutdown stalls and beachball risk |
| 0.5.31 | 2026-04-04 | Ambiguous same-repo Codex save-time resolution now preserves a tab's explicit session metadata instead of clearing it, so restored tabs can keep their last-known resume command |
| 0.5.30 | 2026-04-03 | Localization bundles now include the missing shipped UI strings that were still being requested from Swift source, reducing fallback-to-key behavior across English, Arabic, French, and Hebrew |
| 0.5.29 | 2026-04-03 | Public docs now have a canonical ownership map, stale onboarding duplicates and planning artifacts were removed, and staged doc checks reject absolute filesystem links, stale repo URLs, and TODO markers in the public README |
| 0.5.28 | 2026-04-02 | Codex resume metadata now clears claimed stale explicit session IDs when no deterministic replacement exists, preventing repeated save/restore conflicts across same-repo tabs |
| 0.5.27 | 2026-04-02 | Tab-style delivery now revalidates stale explicit tab IDs against an exact live session match before failing, so banners can still highlight the recovered tab after window/tab registration drift |
| 0.5.26 | 2026-04-02 | Authoritative Claude notification events now keep exact runtime/session binding only, and fail closed instead of inheriting heuristic tab resolution when the owning tab is ambiguous |
| 0.5.25 | 2026-04-02 | Amp is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.24 | 2026-04-02 | Mentat is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.23 | 2026-04-02 | Goose is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.22 | 2026-04-02 | Devin is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.21 | 2026-04-02 | Amazon Q is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.20 | 2026-04-02 | Cody is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.19 | 2026-04-02 | ChatGPT is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.18 | 2026-04-02 | Gemini is now a first-class normalized AI notification source with dedicated triggers, settings coverage, and source labeling |
| 0.5.17 | 2026-04-02 | Codex notify-hook events now export the owning overlay tab UUID, and authoritative stale tab IDs are corrected via exact session binding before notification delivery |
| 0.5.16 | 2026-04-02 | Arabic, French, and Hebrew localizations now include the new acknowledgments/about stack summary, license summary, and open-acknowledgments strings |
| 0.5.15 | 2026-04-02 | The website compare page now points directly at the hosted Chau7 DMG download and the shared footer test count reflects the latest suite size |
| 0.5.14 | 2026-04-02 | The issue-intake relay now serves a small landing page on issues.chau7.sh while keeping POST issue submission at the root endpoint for the app |
| 0.5.13 | 2026-04-02 | Restore-time shell commands now preserve waiting-input suppression, notification action delegates return real cross-window outcomes, and bug-report issue intake defaults to issues.chau7.sh |
| 0.5.12 | 2026-04-02 | Pre-release DMG packaging now defaults to an Apple Silicon artifact with a styled drag-to-install layout, removes duplicate proxy bundling, and keeps the larger universal helper build optional |
| 0.5.11 | 2026-04-02 | Claude runtime binding now fails closed on ambiguous same-repo tabs and uses exact tab session metadata before adopting or routing notification events |
| 0.5.9 | 2026-04-01 | Transcript-derived Claude/Codex run telemetry can now be rebuilt in place from the debug console to repair historical token corruption |
| 0.5.10 | 2026-04-02 | Codex notify hook installation now preserves existing user hooks, retains authoritative opaque thread IDs, and only disables prompt fallback when the Codex hook is actually installed |
| 0.5.8 | 2026-04-01 | Debug analytics now separates proxy API-call data from AI run telemetry, and proxy settings expose explicit OpenAI-compatible routing control |
| 0.5.7 | 2026-04-01 | Transcript-derived AI run metrics now use canonical token fields, run-local slicing, Claude usage deduplication, and invalidation of implausible historical totals |
| 0.5.6 | 2026-03-29 | Remote relay control frames now require encryption after handshake, and remote push registration uses HTTP(S) relay endpoints instead of websocket URLs |
| 0.5.5 | 2026-03-29 | Runtime Claude events now bind to exact session IDs and preserve multiple same-directory agent tabs without cwd collisions |
| 0.5.4 | 2026-03-29 | History store clears now serialize with queued async writes so pending inserts cannot resurrect deleted rows |
| 0.5.3 | 2026-03-29 | Reopen Closed Tab now preserves tab identity metadata, including tab ID, creation time, and repo grouping |
| 0.5.2 | 2026-03-29 | Shell runtime launch preserves argument boundaries; notification pipeline respects disabled single-action rules |
| 0.5.1 | 2026-03-19 | Richer remote approval context on iPhone: directory, recent command, project/branch, and MCP source notes |
| 0.5.0 | 2026-01-21 | Tab notification styling, major tab bar fixes |
| 0.4.0 | 2026-01-20 | Smart scroll, watchdog recovery, enhanced logging |
| 0.3.0 | 2026-01-19 | Tab reordering, notification events, selection fixes |
| 0.2.1 | 2026-01-15 | Shell integration, baseline metrics |
| 0.2.0 | 2026-01-14 | API proxy, task lifecycle, terminal header |
| 0.1.0 | 2026-01-11 | Initial release with core features |

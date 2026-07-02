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
- [Quality Gates](#quality-gates)
- [Architecture](#architecture)
- [Additional Notes](#additional-notes)

---

## AI Detection & Integration

### Auto-Detection

Chau7 recognizes AI CLIs the moment they launch — no configuration required. The detection engine uses a combination of process-tree signals and terminal output scanning with strictly tuned patterns to minimize false positives:

- **Claude** (claude, claude-code, claude-cli)
- **Codex** (codex, codex-cli, codex-pty)
- **Gemini** (gemini, gemini-cli)
- **ChatGPT** (chatgpt, gpt, openai)
- **GitHub Copilot** (copilot, copilot-cli, github-copilot)
- **Aider** (aider)
- **Cursor** (cursor)
- **Windsurf** (windsurf)
- **Cline** (cline)
- **Cody** (cody)
- **Amazon Q** (amazon-q)
- **Devin** (devin)
- **Continue** (continue)
- **Goose** (goose)
- **Mentat** (mentat)
- **Amp** (amp)
- Custom-defined tools with display name and tab color.

Detection methods:
- Live process-tree resolution. Each session polls `ps` descendants of its shell PID and matches executable basenames against the registry — the OS is the ground truth for identity. A tab labeled Codex that starts running Claude updates to Claude within ~1.5s without requiring user action.
- Command line tokenization with wrapper skipping (env, sudo, command, builtin, exec, noglob, time). Command detection gates output scanning to prevent false positives.
- Output banner matching for all supported CLIs. Patterns require tool-specific context to avoid substring collisions, and exclude API-endpoint/website substrings (e.g. `openai.com/v1`) that appear in ordinary project code rather than CLI banners.
- Corroborated output origination. An output-pattern match can only *originate* a new tool identity on a tab that has none when a live process-tree signal corroborates it; otherwise output matching only *confirms* an already-established identity. This prevents incidental output — an API URL printed by a `git push` in a repo that uses that API — from flipping a plain shell to an AI tool.
- Custom detection rules with display name and tab color.

### AI Features

- **MAGI multi-agent decision protocol** — CLI-first council mode that launches three isolated agents through Chau7 MCP, applies editable member personas, shares only controlled council packets between rounds, collects user-approved evidence, resolves majority/veto verdicts, and writes replay/share artifacts.
- **MAGI command surface** — `magi`/`MAGI` supports direct questions, `ask`, `doctor`, `config`, `replay <run-id>`, and `share <run-id>` with local artifacts only in v1.
- **MAGI local installer** — `Scripts/install-magi-cli.sh` builds the SwiftPM CLI and installs `magi` into `~/.local/bin` by default, with uppercase `MAGI` invocation supported through case-insensitive resolution or a case-sensitive alias.
- **MAGI production artifacts** — failed, interrupted, vetoed, deadlocked, and partial runs carry checkpoint/failure metadata across decision markdown, decision JSON, transcript/replay JSONL, graph JSON, and local share HTML (a terminal replay is rendered on demand by the `replay` command).
- **MAGI hardened CLI runtime** — missing Chau7/MCP, provider launch failures, agent timeouts, malformed structured output, denied evidence, veto/deadlock outcomes, interrupts, and partial artifact replay paths are surfaced as clean statuses with useful local logs.
- **MAGI per-run technical log** — each run writes `technical.jsonl` next to the required artifacts with correlated run/member/tab events for launches, prompt visibility, prompt submission, agent-running checks, polling, parsing, repairs, checkpoints, and failures.
- **MAGI resilient launch verification** — launch checks accept raw running status and provider output when the effective tab status lags, so a member is not failed after its prompt was submitted and the agent is visibly active.
- **MAGI prompt injection readiness** — `agent_launch` waits for a recognizable provider input surface in the live tab buffer before typing, and launch verification no longer treats provider-level PTY logs as proof that a specific tab received the prompt.
- **MAGI launch exit detection** — `agent_launch` caps prompt-injection waits and reports `agent_exited_before_prompt` when a provider command exits before receiving the prompt, avoiding opaque MAGI MCP socket timeouts.
- **MAGI event-backed result capture** — MAGI polls Chau7's tab-scoped AI completion events alongside PTY output, so completed council responses can be parsed from agent turn notifications when terminal scrollback does not expose the final marked JSON block.
- **MAGI MCP contract preflight** — `magi ask` verifies that the running Chau7 MCP socket supports filtered, full-message repo events before launching agents, failing immediately with a restart instruction when the app process is stale.
- **MAGI home TUI** — running `magi`/`MAGI` without arguments opens an interactive terminal home screen with progressive boot output, ASCII art, colored member panels after boot, boot-status lines ending on the selected council, an ask prompt, help, doctor access, and `--config` navigation.
- **MAGI config panel** — `--config` opens an editable terminal panel for member provider/class settings, global evidence/web/deadlock/veto switches, provider checks, and persona file checks.
- **MAGI visible first-run wizard** — `magi config` renders provider and model-class choices as numbered lists in interactive terminals and explains stdin/stdout TTY state when the wizard cannot open.
- **MAGI shared first-run setup** — `magi config` can apply one provider/class choice to Melchior, Balthasar, and Casper, with a per-member path still available for mixed-provider councils.
- **Branded tab logos** — detected agents show their brand logo in the tab when one is bundled; the rest fall back to their brand tab color.
- **Auto tab theming** — tabs adopt the brand color of the active AI agent.
- **LLM error explanation** — one-click error analysis via OpenAI, Anthropic, Ollama, or custom endpoint.
- **Claude Code deep integration** — monitor hook events: prompts, tools, permissions, responses.
- **AI event notifications** — finished, failed, permission, needs_validation, tool_complete, session_end, idle. Default policy scopes notifications to two moments: the agent is waiting on you (permission / waiting_input / attention_required / elicitation) and the agent has finished working (finished / failed / response_failed). All of those bounce the Dock icon by default — once for completion, continuously (critical) until focused for approval/feedback. Noise sources — shell `command_finished`/`command_failed`, AI `idle`, and `tool_failed` — are off by default and toggleable in settings. Banners include repo/tab/directory context in the subtitle when available.
- **Resilient waiting-input attention** — waiting-input and attention-required events keep persistent tab highlights even when duplicate suppression, rate limits, or disabled idle actions suppress the follow-up notification path.
- **State-driven tab attention** — terminal session state is reduced through a pure policy so `waitingForInput` / `approvalRequired` tabs have a single source of truth independent of banner delivery. The overlay reconciler repairs missing highlights from live state without replaying native notifications, and `attentionReport` diagnostics expose state/style mismatches in snapshots and tab summaries.
- **Terminal wait-pattern backstop** — terminal-side AI prompt detection emits lower-confidence attention events as soon as a TUI appears blocked, closing provider-hook delays while preserving authoritative hook precedence.
- **Attention events reopen terminal-marked sessions** — an authoritative interactive-attention observation reopens a session the reconciler had already marked terminal, so providers that emit no raw lifecycle events between turns (notably Codex) still surface permission prompts that arrive after the first turn instead of being swallowed.
- **Multi-provider event normalization** — Claude, Codex, and terminal sources translate provider-specific events into one shared semantic layer. Authoritative events from runtime and hooks take priority over history-derived fallbacks.
- **Centralized event source adaptation** — generic AI, terminal-session, fallback-history, shell, app, API proxy, and unknown-source events share one tested mapped-source adaptation path while keeping source-specific routing and reliability policy explicit.
- **Event publisher abstraction** — app and shell event producers publish through a narrow `AIEventPublishing` boundary, keeping event detection decoupled from concrete `AppModel` storage and notification state.
- **Session-aware notification routing** — notifications route by exact AI session ID with fallback to provider/title heuristics. Handles tab restoration, split sessions, nested working directories, and cross-tab file conflicts.
- **Indexed AI session routing** — notification delivery, runtime strict-session lookup, and history adoption use a cached cross-window routing index built from live sessions and deferred restore metadata before falling back to recovery heuristics.
- **AI-first notification settings** — simplified overview for Finished, Failed, and Permission Request with direct controls for banner, tab highlight, sound, and dock bounce. Waiting-input and attention-required states surface as “needs me” attention. Per-tool overrides and advanced trigger plumbing available separately.
- **Notification delivery ledger** — lifecycle tracking for debugging: coalescing, retry scheduling, drop reasons, and real UI outcomes.
- **PTY output logging** — capture raw terminal output for AI tool sessions.
- **Codex session resolver** — maps Codex sessions to working directories with a bounded metadata cache.
- **Generation-tokened event drain** — drain runloops capture a generation at start; any start/stop invalidates older loops, and the log sink, deallocation flags, and poll diagnostics are lock-guarded.
- **Queue-confined monitors** — dev-server detection, file tailers, shell-event detection, the shared process-tree snapshotter, and the remote IPC server each confine mutable state to one owning queue, so UI calls can never race their timers.
- **Retry-not-give-up watchdogs** — file monitors re-arm with backoff after delete/replace, tailers re-arm on rename with bounded per-tick reads, and the terminal dylib loader retries after a cooldown instead of disabling terminals until relaunch.
- **Pane-owned AI restore** — split tabs restore resume commands from each saved terminal pane’s own metadata instead of inferring ownership from whichever pane is focused after layout rebuild.
- **Restore ownership validation** — pane resume prefills now verify directory and restored AI identity before insertion, so stale retries fail closed instead of landing in the wrong pane.
- **Restore delivery ledger** — pane resume restore now records scheduled, queued, delivered, rejected, and superseded outcomes per pane so stale retries are explicit in logs and tests instead of silent.
- **Restore supersession guard** — stale retry callbacks can no longer overwrite a newer pane’s delivered restore outcome, so the ledger keeps the winning pane state instead of regressing to `superseded`.
- **Identity-tolerant resume prefill** — resume-prefill validation treats unresolved current AI identity as a soft match instead of rejecting, so the prefill survives the post-launch window before output-derived provider/session corroboration completes. Confirmed mismatches still reject.
- **Canonical directory match for resume prefill** — directory-ownership comparison canonicalizes both expected and live paths via symlink resolution, tilde expansion, and standardization before comparing, so `/var` ↔ `/private/var`, trailing slashes, `..` segments, and historical `~/proj` saves no longer produce string-inequality rejection on equivalent paths.
- **Phase-independent idle scrollback flush** — warm-idle tabs flush their scrollback ring to disk losslessly (ANSI/SGR preserved via the lossless capture FFI) and shrink to the viewport floor without changing render phase. On reselection the cached ANSI buffer is replayed and the ring grows back to the configured capacity, so long-lived background tabs free history memory without losing colors or re-pour fidelity. TUI / alternate-screen tabs are skipped.
- **Restore-time re-resolution of AI session commands** — when autosave captured a pane's identity during the post-launch corroboration window, the saved `aiResumeCommand` is nil because `buildAIResumeCommand` correctly refuses synthetic session IDs. On restore the pipeline now scans the provider's transcript files (`~/.claude/projects/<dir-as-dashes>/*.jsonl`, `~/.codex/sessions/...`) for the best match against the saved directory + last-input recency and reconstructs a real `claude --resume <id>` / `codex resume <id>` from the result. When autosave captured **no** identity at all (provider AND session AND command all nil — fired before any corroboration), the helper scans BOTH providers' transcripts and picks whichever has a match closer to the saved activity timestamp, or the newest transcript overall when the activity timestamps didn't survive. The Codex resolver anchors its day-directory search at the saved activity timestamp (not "today") and walks up to 14 day folders, so tabs last used a week+ ago are recoverable. Tabs that previously came back blank after restart are now restored with the correct resume prefill.
- **Live process tree is authoritative for AI-running state** — `isAIRunning` (the predicate that drives logo opacity in the tab strip and hover card) now treats a non-nil `liveAgentName` as definitive proof an AI tool is active, regardless of whether `activeAppName` has been cleared by the state machine on prompt-return. Closes the regression introduced when output-detection corroboration tightened and URL fingerprints were purged — tabs running Codex / Claude whose output didn't contain a fresh corroborating signal were rendering at the dimmed opacity even though the agent was visibly in the process tree. The display chain (`aiDisplayAppName`) also picks up `lastDetectedAppName` as an additional fallback so future independent clearing of `lastAIProvider` can't strip the logo silently.
- **Dimmed AI tab logo stays legible** — the "not currently running" opacity for the tab-strip agent logo moved from 0.35 to 0.6. The previous value was effectively invisible against the dark tab background, so restored tabs with a correctly stored provider (e.g. an old "Debug 2" tab whose Claude process had exited) looked like they had no icon at all. The dimmed cue is preserved; it's just readable now.
- **AI display name reads a single canonical field** — `aiDisplayAppName` collapsed from a four-rung fallback (`liveAgentName → activeAppName → lastDetectedAppName → lastAIProvider`) to a single read of `lastAIProvider`. Every detection write path — process-tree subscription, output match, history adoption, restore — now writes through to `lastAIProvider` (via `updateLastDetectedApp`) so the canonical persisted field is always current. The previous chain had grown one rung per regression where some write path forgot to update another field; closing the writer holes makes the readers trivial and removes a recurring class of "icon disappears after restore" bugs.
- **Restore re-resolution refuses to fabricate identity from cwd alone** — when autosave landed with no provider, no session id, and no resume command on a pane, the restore pipeline used to ask "what is the newest claude or codex transcript in this directory?" and hand the answer back as the tab's identity. For directories with many tabs that collapsed every nil-identity sibling onto the same most-recent session — N tabs all restored with the same `claude --resume <id>`, including former codex tabs whose identity was lost. `reResolveResumeCommand` now refuses to guess when the saved trio is entirely nil, and even when at least the provider tag survives, it dedups its on-disk candidate against the session ids already claimed by other tabs' saved state. Tabs in a shared cwd are restored to distinct sessions or come back blank, never to a duplicate.
- **Resume prefill never silently abandons after retry exhaustion** — the queued resume command used to retry with an eager 0.3–3s backoff up to 20 times (~30s), then return `.queued` and reset the retry counter without scheduling another attempt. During a multi-tab cold boot many shells race for resources and the first selected tab's OSC 133 prompt can arrive well after that window — leaving `pendingPrefillInput` set but nothing actively trying to drain it, so the prefill only appeared if the user happened to switch tabs and back (recreating the view triggered `attachRustTerminal → flushPendingPrefillInputIfReady`). The retry pacer now falls through to a 5s heartbeat past retry 20, so the prefill is delivered the moment the shell becomes ready without requiring user interaction.
- **Tab selection drains queued resume prefill** — `selectTab` now walks the newly selected tab's terminal sessions and calls `flushPendingPrefillInputIfReady` on each. The user looking at a tab is a natural kick for any queued resume command that was waiting on a cold-boot shell — pairs with the 5s heartbeat above so users who do switch around see the prefill instantly, and users who don't still get it within 5s of the shell settling.
- **"Move to Idle Tabs" works on the selected tab** — the right-click action used to silently no-op when invoked on the currently selected tab (the previous guard rejected `id == selectedTabID` with no log line, no state change, no UX feedback). Selection now jumps to the immediate neighbor first, then the original tab moves into the idle dropdown. Refuses cleanly with a warning when this is the only tab in the window so the user is never left with an empty bar. The `idleTabs` view predicate also reads the observable `suspendedTabIDs` set directly so SwiftUI re-evaluates immediately on the manual move (the session's `lastInputAt` / `lastOutputAt` are `@ObservationIgnored` to avoid keystroke-frequency view thrashing).
- **Side-panel markdown editor defaults to source** — opening a `.md` / `.markdown` file in the text side panel now shows the raw source editor by default; the runbook preview is one toolbar-button click away. The previous default landed users in the rendered runbook view, which had no editor affordances and made simple edits awkward.
- **Source ⇄ Preview toggle with a keyboard shortcut** — the source/runbook toggle button is labeled **Preview** (and **Show Source** when previewing), and an editor-pane-scoped `⌘⇧P` shortcut flips between the two views without leaving the editor. (This is distinct from the global command palette on `Cmd+Option+P`; the Preview shortcut only fires while the markdown editor pane has focus.)
- **Interactive task checkboxes** — the runbook styler recognizes `- [ ]` / `- [x]` task items: the box is styled (green when checked, dimmed when not), completed task text renders struck-through and dimmed, and clicking a checkbox in the source edit pane toggles its state in place.
- **Hanging indents for wrapped list items and blockquotes** — wrapped lines in list items and blockquotes now hang under their text content instead of the marker, via a per-paragraph head indent measured in the body font, so multi-line bullets and quotes stay visually aligned.
- **Runbook view actually renders inline markdown** — every paragraph, heading, list item, and checkbox label now renders `**bold**`, `*italic*`, `` `inline code` ``, and `[link](url)` as styled glyphs via `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)`. The previous build called `Text(verbatim:)` on every line, so users saw literal `**` and `_` characters in the preview. Block-level constructs (headings, fences, lists, checkboxes) are still parsed first by the structural layer, so the inline-only mode never reinterprets a leading `#` as a heading marker. Code-block content is pinned to `Text(verbatim:)` so it can never be reinterpreted as markdown. Malformed inline markup falls back to a partially-parsed rendering so content is never silently dropped.
- **Autosaved side-panel notes** — default text side panels attach to the tab-scoped `.chau7/sessions/<tab-id>/note.md` as soon as they open, auto-save edits, and flush dirty content silently on close. Regular files (non-auto-save) prompt to save / discard / cancel via a single dialog hosted on the split-pane controller, so the X button and ⌃⌘W share one decision path and "Don't Save" actually discards.
- **Single Live Selected-Tab Surface** — selected tabs now render through one live surface only; the old snapshot/cursor handoff no longer stacks on top of the live terminal during tab switches.
- **On-Demand Deferred Restore** — non-selected restored tabs stay deferred until the user selects them, instead of auto-restoring and mutating visible tabs immediately after launch.
- **Identity-only background restore** — deferred background tabs hydrate provider/session facts for routing and titles without activating AI live-render state, restoring command blocks, or queuing resume input until selected.
- **Integrity-checked restore sidecar** — tab autosave also writes a split restore bundle with identity/layout/AI resume fields in a compact manifest and heavier scrollback/context data in SHA-256-verified sidecar files.

### Context Token Optimization (CTO)

Built-in token optimizer (`chau7_optim`, forked from [RTK](https://github.com/rtk-ai/rtk)) that rewrites CLI output to minimize LLM context consumption. ~40% token savings on average.

- Per-tab or global CTO mode with flag files that AI tools read.
- Runtime monitor: decision counts, mode changes, deferred operations, health assessment.
- MCP-controllable via `tab_set_cto`.
- Ultra-compact mode for maximum savings.
- Token savings tracking with daily/weekly/monthly graphs.
- Shared read pipeline: file-backed reads and stdin-backed reads use one tested filtering, truncation, non-empty-output preservation, and line-number formatting path to prevent parser drift.
- Non-empty read guard: `chau7-optim read` preserves original output if filtering would make a non-empty file, stdin payload, or selected range look empty, so optimized `cat`/read-style commands do not masquerade as broken shell output.

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

- Persistent SQLite-backed AI session and command history with reliable clear-all semantics. All store mutators are serialized on one queue, and age-based clears keep the cached record count honest so the size trim can never delete valid records.

## API Analytics & Token Tracking

- **TLS/WSS proxy** — Go-based `chau7-proxy` intercepts API calls to Claude, OpenAI (Codex), Gemini, Anthropic with TLS and WebSocket support.
- **Orphan-proof helpers** — chau7-proxy and chau7-remote exit when the parent app dies (no port-holding orphans after a crash), and the proxy's auto-restart backs off exponentially instead of crash-looping every 2 seconds.
- **Token counting & cost calculation** — full token breakdown per call: input, output, cache creation, cache read, and reasoning tokens. Accurate cost calculation using provider-specific cache pricing (Anthropic 0.1x cache-read / 1.25x cache-write; OpenAI per-model cache-read rates, 0.1x–0.5x). Fallback estimation when extraction fails.
- **Latency tracking** — total request duration and time-to-first-token (TTFT) per API call.
- **Echo-only input latency** — per-session input latency measures keystroke→echo responsiveness only; command submission (Enter) is excluded for every session, so a slow command's runtime is never miscounted as UI lag.
- **Configurable telemetry retention** — AI run history and full transcripts in `runs.db` are pruned at launch to a user-set window (default 30 days; `0` = keep forever, set in Settings → Logs & History), cascading to child rows and reclaiming disk with a full `VACUUM`, so the database can't grow without bound.
- **Bounded AI event queues** — the append-only hook event logs (`claude-events.jsonl`, `.ai-events.log`) are compacted to their most recent slice at monitor start (before tailing, while quiescent), so the transient event queues can't grow without bound; the durable record stays in the telemetry database.
- **Task detection & assessment** — auto-detect AI task candidates with confidence scoring; approve or fail with notes.
- **Baseline estimator** — calculate token savings from context caching.
- **Analytics dashboard** — command stats, error rates, API usage, and timing. Proxy health monitoring, timeline pagination, and per-agent cost display with cache/reasoning token breakdown (the analytics view refreshes on a fixed timer plus event-driven updates; the per-repo agent dashboard is the one with adaptive 2s active / 5s idle / 10s no-agents polling). Poll-cycle tracker state is confined to a serial refresh queue so commit actions and live polling can never race each other's bookkeeping.
- **Non-blocking session-event reporting** — prompt-injection session events post to the proxy asynchronously; a slow or wedged proxy can never freeze typing while the app waits for the local HTTP round-trip.
- **Background completion extraction for Codex/OpenAI runs** — run-end finalization no longer waits on heavy transcript extraction for OpenAI-family sessions. Completed rows are persisted immediately, then richer turns and tool calls are backfilled asynchronously when extraction finishes.
- **Recent proxy call context** — recent API calls in the Debug Console include local hour, repo name, and endpoint context for faster investigation.
- **Repo-level aggregated metrics** — per-repository stats (commands, success rate, AI runs, tokens, cost, providers, top tools) in Debug Console, Data Explorer, and hover card.
- **Repo-aware debug labels** — per-tab token and CTO rows use `provider/custom title + repo`, with split-session disambiguation when needed.
- **Timeline visualization** — scrubber timeline showing command blocks and metrics.
- **Provider filtering** — include or exclude specific API providers.
- **Correlation headers** — `X-Chau7-Session`, `X-Chau7-Tab`, `X-Chau7-Project` for tracing (plus `X-Chau7-Context-Pack` for baseline estimation).
- **Per-repository prompt injection** — inject content into API requests per repository via `~/.chau7/prompt-rules.json`. Rules match by repository name (portable) or absolute path, choose prepend to user message (default), append, or system prompt, and now control when injection fires: every prompt, the first matching prompt in a shell session, or the first matching prompt after `/compact` or `/clear`. Supports Anthropic Messages, OpenAI Chat Completions, OpenAI Responses (Codex), and Gemini, plus optional repo-local `.chau7/injection.json` overrides.

## MCP Server

Chau7 runs an embedded MCP (Model Context Protocol) server — your AI agents can see and control your terminal.

- Default MCP tab creation targets the active Chau7 overlay window, so new MCP tabs appear in the window currently in use without requiring an explicit `window_id`.
- Runtime launches that require a visible tab now fail explicitly when Chau7 cannot create one, instead of silently succeeding in a hidden PTY-only path.

### Architecture

- **Protocol**: JSON-RPC 2.0 over Unix domain socket (`~/.chau7/mcp.sock`).
- **Version negotiation**: The server now negotiates `2025-11-25` while remaining compatible with `2024-11-05`, and requires `initialize` then `notifications/initialized` before normal tool or resource calls.
- **Connection behavior**: Idle MCP client sockets stay open long enough for slower eval and manual-debug workflows instead of timing out after short pauses.
- **Bridge**: `~/.chau7/bin/chau7-mcp-bridge` (stdio-to-socket bridge for standard MCP clients).
- **Thread safety**: All terminal operations dispatch to main thread via `DispatchQueue.main.sync`.
- **Tool guardrails**: `tools/call` validates arguments against the advertised schemas, returns JSON-RPC protocol errors for malformed requests, marks execution failures with `isError`, and rate-limits per-tool bursts.

### Auto-Registration

On every launch, Chau7 automatically registers itself as an MCP server in:

| AI Tool | Config File | Format |
| --- | --- | --- |
| Claude Code | `~/.claude.json` | JSON (`mcpServers.chau7`) |
| Cursor | `~/.cursor/mcp.json` | JSON (`mcpServers.chau7`) |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | JSON (`mcpServers.chau7`) |
| Codex | `~/.codex/config.toml` | TOML (`[mcp_servers.chau7]`) |

Registration only occurs if the AI tool's config directory exists — no files are created for tools you don't use.

Every cross-window tab operation dispatches to the main thread before touching tab models, so MCP calls are safe from any dispatch queue.

### Safety Controls

- **Enable/disable toggle** — `mcpEnabled` setting (default: on).
- **Approval gate** — optional confirmation dialog before MCP operations (`mcpRequiresApproval`).
- **Tab limit** — configurable max MCP-created tabs (default: 4, hard cap: 50).
- **Tab indicator** — purple badge on MCP-controlled tabs (`mcpShowTabIndicator`).

## MCP Tools

### Tab Management (12 tools)

| Tool | Description |
| --- | --- |
| `tab_list` | List all tabs across all windows with status, cwd, git branch, CTO state, active app. Primary live discovery API for active AI tabs |
| `tab_create` | Open a new tab with optional directory and target window — respects approval gate and tab limit, and returns exec-acceptance plus prompt-readiness fields |
| `tab_exec` | Execute a command in a tab — auto-queues when shell/bootstrap state still needs to settle so launchers can submit deterministically without waiting for prompt-ready rendering |
| `tab_status` | Detailed live tab status: process state, child processes (PID/CPU/RSS), active telemetry run, git branch, `ai_provider`, `ai_session_id`, deterministic exec-acceptance fields (`can_accept_exec` / `exec_acceptance_mode`), and stricter prompt-ready fields (`ready_for_exec` / `readiness_reason`) |
| `tab_wait_ready` | Wait until `tab_exec` will be accepted (`can_accept_exec=true`) and return the last observed status snapshot on success or timeout |
| `tab_send_input` | Send raw input for interactive prompts — no auto-newline appended |
| `tab_press_key` | Send terminal key presses for interactive TUIs — Enter, Escape, arrows, backspace, delete, paging keys, and ctrl/alt combos |
| `tab_submit_prompt` | Submit the current interactive prompt by sending Enter as a key press |
| `tab_close` | Close a tab with optional force flag — checks for running processes |
| `tab_output` | Get recent terminal output (last N lines, max 10000) with 512KB cap. `source='pty_log'` returns ANSI-stripped PTY log (full AI session). `wait_for_stable_ms` polls buffer until stable. |
| `tab_set_cto` | Set per-tab CTO override (default/forceOn/forceOff) — recalculates flag files |
| `tab_rename` | Set a custom title for a tab — pass empty string to clear |

### Agent Orchestration (1 tool)

| Tool | Description |
| --- | --- |
| `agent_launch` | Launch one or more AI coding agents (Claude Code, Codex, …) in fresh tabs in a single call — composes `tab_create` + `tab_wait_ready` + `tab_exec` + verified prompt injection with throttles between launch actions. Params: `directory`, `agent_command` (default `claude`), `prompt`, `count`, `pr_number`, `window_id`, `ready_timeout_ms`. Returns per-agent prompt visibility/submission/running checks; collect each agent's output with `tab_output(source='pty_log')` |

Fan a review across N parallel agents — e.g. three agents reviewing PR #323:

```json
{
  "name": "agent_launch",
  "arguments": {
    "directory": "/path/to/repo",
    "count": 3,
    "pr_number": 323,
    "agent_command": "claude",
    "prompt": "Review this PR for correctness, security, and test coverage."
  }
}
```

- When `pr_number` is set, each tab runs `gh pr checkout <pr> && <agent_command>` before the agent starts.
- Prompt delivery is **best-effort**: the prompt is typed in once the agent attaches (reported per agent as `sent` / `agent_not_detected` / `skipped`). For full reliability, embed the task in `agent_command` if the CLI supports it.
- `count` is capped by the MCP tab limit; a creation failure (e.g. limit reached) stops the batch early.

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
| `session_list` | List telemetry/history AI sessions with run counts — filter by repo_path, active_only. Responses include `active_run_count`, `completed_run_count`, `latest_run_id`, and `latest_run_state`. Use `tab_list` / `tab_status` for live discovery |
| `session_current` | Get currently active telemetry-backed AI sessions. Use `tab_list` / `tab_status` for live discovery and control |

### Observability (6 tools)

| Tool | Description |
| --- | --- |
| `chau7_runtime_info` | Build and process identity for external observability: app version, build number, build sha/timestamp/channel, process id, launch time, and schema version |
| `chau7_runtime_events` | Recent Chau7 observability events with stable sequence ids. Includes app-owned lifecycle markers plus unified non-app AI events with optional `tab_id`, `session_id`, `run_id`, and `repo_path` |
| `chau7_timer_inventory` | Chau7-owned timer and display-link inventory for observability: stable timer ids, kind, subsystem, queue label, cadence, and active state |
| `chau7_state_snapshot` | Aggregated observer snapshot: runtime identity, live tabs, pending approvals, repo event summaries, active telemetry runs/sessions, timers, latest monotonic sequence, and observer contract metadata for deterministic eval clients |
| `chau7_subscribe` | Open one long-lived state subscription on the current MCP connection. Returns the initial snapshot plus optional replayed changes since a cursor, exposes subscription health metadata, and emits `notifications/chau7.event` deltas plus `heartbeat` keepalives |
| `chau7_unsubscribe` | Stop the active Chau7 state subscription for the current MCP connection |

Telemetry parsing also accepts pretty-printed Codex rollout JSON when extracting quota snapshots and rate-limit windows, so multiline history files produce the same quota data as one-line JSONL.

### Internal Runtime

The app still contains internal runtime orchestration used by dashboard and review flows, but `runtime_*` is not callable through MCP anymore. Public MCP clients should use `tab_*` for live control and `run_*` / `session_*` for telemetry/history.

### Resources (4 endpoints)

| URI | Description |
| --- | --- |
| `chau7://telemetry/runs` | Latest 20 telemetry run summaries |
| `chau7://telemetry/sessions` | AI session index with metadata |
| `chau7://telemetry/sessions/current` | Currently active AI sessions |
| `chau7://telemetry/runs/<run_id>` | Specific run details by ID |

`resources/list` advertises the first three static endpoints; `chau7://telemetry/runs/<run_id>` is a templated URI readable via `resources/read`.

## Terminal Core

- **Rust terminal backend** — custom emulator via FFI: fast, memory-safe, correct.
- **Pinned FFI contract** — the terminal dylib exports an ABI version and struct-layout probes that Swift verifies before binding any symbols, and an integration test exercises the real built dylib end-to-end on every test run.
- **Rust acceleration layer** — ANSI segment parsing, pattern matching, escape sanitizing, command-risk detection, and dim patching run in `chau7_parse` with Swift fallbacks; the dylib's symbol exports are verified at build time.
- **Lock-free PTY resize** — window resizes ioctl the PTY winsize on a dup'd fd, so a child that stops reading stdin can never stall the UI thread mid-drag.
- **Lossless PTY teardown** — kernel-buffered output is fully drained after the child hangs up (bounded runaway guard), so a fast-exiting command's final burst always reaches the screen.
- **Hostile-input-hardened FFI** — selection coordinates clamp to live grid bounds and reader-pool spawn failure degrades to a clean creation error, so no FFI-reachable input or resource exhaustion can abort the process.
- **Thread-safe FFI resize** — `chau7_terminal_resize` binds a shared reference (dimensions stored atomically), so a main-thread resize can never alias the drain threads' concurrent poll access.
- **Post-resize SIGWINCH nudge** — after each resize, Chau7 re-delivers `SIGWINCH` to the PTY foreground process group (`chau7_terminal_nudge_winsize`) a short, coalesced moment later, so a full-screen TUI that booted during the resize and missed the kernel's signal (e.g. Claude Code's Ink caching a stale width) still re-reads the authoritative size instead of corrupting its diff-repainted output for the rest of the session.
- **Owned C-string env marshalling** — terminal creation duplicates environment keys/values into C-owned buffers freed after the FFI call, so the spawned shell's environment never depends on Swift buffer pointers outliving their guaranteed scope.
- **Terminal runtime facts** — Rust exposes alternate-screen state through FFI/debug snapshots so Swift can reason about TUI surfaces generically instead of matching individual providers.
- **Generic TUI scroll policy** — a pure Chau7Core policy routes scrolls to normal scrollback, mouse-aware TUI apps, or transcript history based on runtime terminal state.
- **Per-tab transcript capture** — each terminal session keeps a bounded PTY transcript ring with command-boundary backfill so late AI detection can still seed accurate session logs.
- **TUI transcript overlay** — alternate-screen TUIs without normal scrollback can show recent transcript history on scroll-up, while mouse-reporting TUIs keep receiving wheel events.
- **Fixed-delay startup reveal** — Chau7 reveals restored windows after a short splash delay instead of waiting for the full restore queue to drain, matching the lighter release-era startup contract.
- **Stabilized tab restore path** — restored scrollback replays through the shell again, with restore-artifact filtering preserved, to avoid post-relaunch history corruption while keeping fast visible startup.
- **Corruption-tolerant persisted lookups** — dictionary builds over persisted keys (pane states, tab IDs, repo roots, shortcut actions) use first-wins uniquing, so duplicate keys in stored data degrade gracefully instead of crashing restore or settings.
- **Restore-time tab identity dedup** — every saved tab restores exactly once across all windows (first occurrence wins, within and across window snapshots), so duplicated-window snapshots from past incidents converge back to a single copy instead of cascading across restarts.
- **Change-aware quit snapshot** — quitting reuses the cached autosave snapshot only when a structural fingerprint of the live windows still matches; any tab/pane/title/directory/AI-session change since the last autosave forces a fresh capture, so the last seconds of work always survive a quit.
- **Freshest-wins restore arbitration** — every save stamps a shared token on the restore bundle and the UserDefaults index; at launch the source whose token reflects the latest save wins, so a bundle whose writes silently failed can never resurrect a stale session over fresher index data.
- **Crash-safe bundle swap** — the restore bundle directory is replaced with safe-save semantics (old bundle stays until the new one takes over), and manifest/sidecar corruption is logged instead of silently degrading restore to a weaker source.
- Full ANSI/VT100 with 16-color, 256-color, and 24-bit true color support.
- Emoji-aware glyph coloring renders real emoji, including achromatic FE0F symbols, with embedded color while keeping terminal UI symbols and box drawing tintable by ANSI foreground color in Metal.
- ASCII glyph fast path: single-byte printable cells (the vast majority of a text screen) resolve their Metal glyph through a flat style-indexed array, avoiding the per-cell `Data` allocation and dictionary hash the per-frame instance-buffer build previously incurred; multi-byte clusters (emoji, box-drawing, wide CJK, ligatures) keep the full cache path.
- International Option-key punctuation input preserved for programming characters like brackets and braces.
- Kitty keyboard protocol (full progressive enhancement).
- Inline images: iTerm2 (ESC ] 1337), Sixel, and Kitty image protocols.
- Configurable cursor styles (block, underline, bar) with optional blinking.
- Large configurable scrollback buffer with GPU-accelerated scrolling; active, passive-visible, and warm tabs preserve the configured capacity across render phase changes, while hidden tabs flush and verify the disk cache before RAM reclamation.
- Shell selection: Zsh, Bash, Fish, or custom path — Apple Silicon and Intel native. The passwd default shell is verified to exist before spawning (missing binaries fall back to `/bin/zsh`), and an outright terminal-creation failure shows a localized error card with a Retry button instead of a blank tab.
- Bash shell integration spawns interactive bash with `--rcfile` pointing at Chau7's integration bashrc, and every shell starts in its intended working directory via an explicit spawn cwd (no reliance on rc-file `cd`).
- Dead key and IME support with proper `NSTextInputClient` marked text handling.
- Shell integration via OSC 7 for working directory tracking.
- OSC 133 (FinalTerm) shell integration: prompt start (A), command start (B), output start (C), command finished with exit code (D). Parsed in Rust interceptor, feeds ShellEventDetector. When present, heuristic fallbacks are suppressed.
- File drag-and-drop: drop files to paste shell-escaped paths; Option+drop images for base64 data URIs.
- Markdown runbooks: open .md files in the editor pane with executable code blocks; Run All sends each block to the terminal only after the previous one finishes (succeeded or failed), so a long-running command never paste-bombs the next one into the shell. Parsed sections are cached, so the rich render does not walk the whole file again every time a code block flips state.
- Native macOS cut/copy/paste shortcuts are preserved inside split-pane text editors before terminal-specific fallbacks run.
- Show Changed Files (Cmd+Option+G): git diff snapshot per command shows which files were modified.
- Idle tabs dropdown: tabs idle beyond a configurable threshold (default 10 min) are grouped into a compact chip in the tab bar.
- Repository tab grouping: group tabs by git repo (Off/Auto/Manual). Shows inline repo-name tag chip with connecting line. Suppresses redundant repo path in tab titles, and inherited group membership auto-detaches when a tab moves to a different repo, including tabs opened directly at another directory.
- Repo-group tag healing: when a repository is moved or renamed on disk, a tab's stale repo-group tag reconciles to the live git root the next time the app regains focus, so grouped tabs don't keep pointing at a path that no longer exists.
- Branch detection keeps one shared repository model per root and swaps models on shell-reported repo-root changes, preventing branch labels from one repo leaking into another after `cd`.
- Branch, repo-root, exit, and foreign notification OSC 9 messages are buffered across PTY chunks before dispatch, so startup metadata survives split terminal reads.
- Detached HEAD is treated as a no-branch state instead of a branch named `HEAD`, and cached branch identity is cleared when the shell reports the detached sentinel.
- Split pane file preview: read-only viewer with syntax highlighting and image support (Cmd+Opt+O).
- Split pane diff viewer: unified git diff with colored additions/deletions and Working/Staged toggle (Cmd+Opt+Shift+D). Binary changes and pure renames show a dedicated empty-state explaining *why* there are no hunks instead of a misleading "no changes" panel.
- `chau7://` URL scheme: ssh, run, cd, and open actions from external apps (the `run` action requires confirmation).
- Default start directory and optional startup commands.
- Copy on select, Option+click cursor positioning, paste escaping.
- Speculative local echo now self-cleans when shell redraws or render-phase/interactivity changes make the optimistic overlay stale, preventing duplicated typed characters across live and passive shell surfaces.
- Full grapheme-cluster rendering — ZWJ emoji (👨🏽‍💻), regional-indicator flags (🇫🇷), VS16 emoji presentation (❤️), and combining marks (NFD `é`) all survive the Rust → Swift FFI snapshot intact. Cell width and continuation are now explicit, so the renderer no longer guesses from glyph advance. The Metal atlas + fragment shader render color-emoji RGBA directly via a dedicated color-glyph flag and shader branch.
- Dangerous-output highlighting now distinguishes executable command spans from prose mentions, so warnings still catch `$ rm -rf /tmp` but skip explanatory text like “do not run rm -rf”.
- iPhone remote approvals now keep polling alive across websocket relay URLs and background-task expiration edges, with explicit push-entitlement and iOS 18 deployment settings tracked in the app project.

## Performance

Chau7's rendering pipeline is purpose-built for latency-sensitive terminal work:

- GPU in-flight gating: shared Metal buffers and the glyph atlas are never rewritten while a committed frame is still reading them, and GPU-failed frames force a full-refresh redraw instead of stranding the view on stale content.
- Slot-clipped glyph rasterization: overhanging glyphs (combining marks, italic overhang, ligature swashes, emoji fallbacks) cannot paint into neighboring atlas slots and corrupt cached glyphs.
- Display-scale awareness: moving a window between Retina and non-Retina displays reconfigures the glyph atlas at the new backing scale and redraws immediately.
- Occlusion-aware rendering: fully covered windows stop live grid syncs and GPU presents (1Hz background drain), with an immediate refresh on re-expose.
- Wired memory reclamation: tab snapshots, scrollback-line duplicates, and search buffers clear on tab close, on `.hidden` demotion, and under OS memory pressure; orphaned scrollback cache files are swept at startup.
- Window-level GPU volatility: under critical pressure the glyph atlas and Metal buffers of fully invisible windows become OS-reclaimable, with reclaim-safe rebuild (including the static vertex quad) on the window's next draw.
- Self-imposed footprint ceiling: the app polls its own memory footprint against a quarter-of-RAM ceiling (clamped 4-12GB) and proactively flushes non-selected tabs' scrollback before the OS pressure signal would ever arrive.
- Bounded auxiliary caches: clipboard history items cap at 100KB each, session-resolver caches cap at 256 entries, closed AI-monitor sessions evict after a grace period, and aborted graphics sequences release their buffer capacity.

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
| **CPU/Metal layout parity** | Pure geometry contract and tests keep CPU and Metal rows, columns, cursor cells, mouse mapping, and remainder pixels aligned |
| **Render request coalescing diagnostics** | Latest-frame-wins sync/present counters expose how many obsolete intermediate frames were skipped during heavy AI-output bursts |
| **Shared Metal handoff reset** | Cross-view coordinator switches clear pending render work and retry/deferred-sync state so one tab cannot briefly present another tab's stale frame |
| **Scroll-storm full Metal refresh fallback** | Scroll storms, visible noninteractive windows, and near-full-row bursts force full Metal instance refreshes so stale incremental cell state cannot bleed into newly rendered shell text |
| **Typed Metal retry recovery** | Font, grid, zero-size, drawable, zero-cell, and commit failures retry safely with sampled diagnostics and recovery reset after the next committed frame |
| **Render surface diagnostics** | Bug reports include window content size, terminal/surface/grid geometry, rows/columns, cell size, point and pixel remainders, Metal view/drawable size, frame age, coalescing counters, and retry state |
| **Metal parity audit** | Tracked parity matrix for wide glyphs, emoji fallback, ligatures, OSC8 links, selection, local echo overlays, inline images, and command-block tinting, with covered/partial/external-overlay status |
| **Metal OSC8 and local-echo parity** | Metal sync overlays predicted local-echo cells before GPU conversion, immediately invalidates the active Metal surface on overlay updates and clears, and renders OSC8 link underlines when no explicit SGR underline is present |
| **Startup live-frame handoff** | Forced selected-tab reveal timeouts keep the next real Metal frame signal armed, so startup restore records the real visible frame instead of waiting for a synthetic fallback |
| **Bounded restoration scrollback snapshots** | Session autosave captures the recent ANSI-styled terminal tail through Rust and reuses the versioned snapshot while panes are idle, avoiding repeated multi-megabyte full-buffer work |
| **Tier-based graphics memory release** | Background tabs release NSImage snapshot caches and mark Metal textures/buffers volatile on demotion, letting the OS reclaim GPU memory under pressure and rebuilding on promotion |
| **Background window render backpressure** | Only the key window owns live selected-tab presentation; visible selected tabs in main-but-not-key or otherwise non-input-priority windows keep a retained passive surface and drain through the shared background path instead of driving full live Metal sync |
| **Adaptive render-loop throttling** | Active tab drops to ~10 Hz after idle, snaps back instantly on PTY data or user input — cuts wakeups and CPU on idle AI sessions |
| **Configurable active-tab refresh cap** | Display Native / 60 Hz / 30 Hz picker lets users trade scroll fluidity for battery; default follows the screen's native refresh |
| **LRU-backed syntax-highlight cache** | Terminal-output highlighter uses `NSCache` (bounded LRU with cost-based eviction and an OS-pressure hook) instead of a dictionary with order-unspecified prefix eviction, so hot lines stay cached on busy streams |

## Tabs, Panes & Windows

### Tabs

- Unlimited tabs per window — `Cmd+T` to create, and a configurable switch-to-tab shortcut mode (`Cmd+1–9`, `F1–F12`, or both) to jump (Settings → Tabs).
- Tab renaming (`Cmd+Option+R`), 12+ colors, reordering via drag or shortcuts with center-crossing snap thresholds.
- AI agent logos, git branch indicator, directory path, last command badge.
- Broadcast input to all tabs with per-tab exclusion and visual indicator.
- Background rendering suspension for inactive tabs (configurable delay).
- Retained-frame inactive tab handoff keeps the last rendered frame for suspended tabs so switching back shows an immediate snapshot while the live terminal catches up.
- Snapshot-backed tab switches stay on that retained frame until the selected terminal reports its first live sync, avoiding grey flashes during cold-tab reactivation.
- Cold tabs that still keep a retained Rust terminal view synthesize a retained frame on demand before selection, so reused terminal views do not fall back to a blank grey handoff.
- Close other tabs (`Cmd+Opt+W`), configurable new tab position.
- Shortcut helper hint box (`⌘/` and `⌥⌘I`) floats 4pt from tab bar bottom and window right edge.

### Split Panes

- Horizontal (`Cmd+D`) and vertical (`Cmd+Opt+D`) splits with draggable dividers.
- Arbitrary nesting via binary tree layout controller.
- Persisted split-pane trees carry a schema version, so a future Chau7 build that adds a new pane kind can't silently mis-decode through an older binary — older code surfaces a clear error and falls back to a default layout instead.
- Modal dialogs (close-confirm, Save As) and main-queue polling are injected through `Dialogs` and `MainScheduler` protocols, so the entire close-time decision path and the markdown runbook sequential runner are unit-driveable end-to-end without an AppKit modal loop or real sleeps.
- Each side-panel leaf (`TerminalPane`, `TextEditorPane`, `FilePreviewPane`, `DiffViewerPane`, `RepositoryPane`, `DashboardPane`) conforms to a single `PaneNode` protocol that owns its `kind`, `hasUnsavedWork`, and `dispose()` contract — adding a new pane kind no longer touches every traversal helper across the tree.
- `SplitNode` is a 2-case enum (`.leaf(any PaneNode)` / `.split`) with three visitor primitives (`collectLeaves`, `findLeaf`, `walkLeaves`); the dozens of per-kind accessors like `allTerminalIDs`, `findFirstEditor`, `firstPaneID(ofType:)` ride on top of those three visitors instead of duplicating a 7-case switch each.
- Each `PaneNode` conformer owns its `savedRepresentation()`, so persistence-side OCP is strictly additive — adding a new pane kind is a protocol method override instead of a central encode-switch edit.
- The split-pane controller delegates two responsibility clusters to focused types: `PaneCloseConfirmer` owns the close-time save/discard/cancel dialog policy (testable with a `FakeDialogs`), and `SessionNoteCoordinator` owns the tab-scoped `.chau7/sessions/<tabID>/note.md` path math and prepare-on-demand step (testable without any controller in the picture).
- The text editor model delegates two more clusters: `RunbookCodeBlockTracker` owns the markdown-runbook state machine and sequential runner (exposed as `editor.runbook` and observable directly), and `EditorAutoSaver` owns the debounced save and status-clear work-item bookkeeping. Both are unit-testable in isolation without touching the model.
- The repo pane delegates commit-draft persistence + conventional-prefix rules to a `RepoCommitDraftStore` value type that takes UserDefaults injection, so the per-directory `repoPaneDraft.*` round-trip is unit-driveable against a scratch suite.
- History section (commit log, stash list, search text, filtered-commits) is its own `RepoHistoryState` `@Observable` accessed as `repo.history`, so a search-text bump only re-renders the history view and leaves status / commit-composer / branches untouched.
- File preview and diff viewer headers share one `PaneHeaderBar` component (icon, title, close button + two `@ViewBuilder` slots for per-pane embellishments) instead of each spelling out its own `HStack`.
- Pane callbacks (`onFocus`, `onUpdateRatio`, `onClosePane`, `onFilePathClicked`, `onRunCommand`) ride on a single `PaneEnvironment` value exposed via SwiftUI's `@Environment` instead of being threaded through every `SplitNodeView` initializer.
- A Liskov-style test suite iterates every shipping `PaneNode` conformer and asserts the protocol invariants (id/kind agreement, dispose idempotency, persistence round-trip, hasUnsavedWork policy, existential round-trip) — adding a new pane kind extends one fixture and inherits every invariant automatically.
- A `PaneConformanceKit` test bundle exposes every PaneNode contract invariant as a reusable assertion function plus a single `assertContract` entry point; the parametrized driver runs the full kit over every pane kind × edit state × persistence round-trip, so a new pane kind extending the catalog inherits every check automatically.
- Every pane in the side-panel tree (Terminal / TextEditor / FilePreview / DiffViewer / Repository / Dashboard) renders its header chrome through one shared `PaneHeaderBar` component with a `title` ViewBuilder slot for interactive titles + `titleAccessory` and `trailing` slots for per-pane embellishments.
- The markdown runbook view takes one `RunbookHost` protocol instead of five separate closures; `TextEditorPaneView` builds a `RunbookHostAdapter` that bridges the editor and the send-to-terminal closure.
- The decode side of split-pane persistence routes through a `PaneFactoryRegistry` keyed on `PaneType`, mirroring the per-pane `savedRepresentation()` on the encode side — adding a new pane kind requires zero edits to existing files (one new pane file + one registry entry).
- The Repository pane model's five sections (Commit, Status, History, Branches, Session) each ride on their own `@Observable` sub-state (`repo.commit`, `repo.status`, `repo.history`, `repo.branchState`, `repo.session`), so a mutation in one section re-renders only the view subtree that reads it.
- Built-in text editor in split panes (`Cmd+Opt+E`) — syntax highlighting, line numbers, bracket matching (`()`, `[]`, `{}`, `<>` — UTF-16 in-place scan, no per-keystroke array allocation), auto-indent, scroll-to-line, find/replace.
- Word-wrap-aware scrolling: with word wrap on (the default) wrapped lines never show a horizontal scroll bar, and the line-number gutter re-tiles the scroll view when its width changes so it can't push content into a spurious lateral scroll; turning word wrap off restores the horizontal scroller for long-line editing.
- Repo-scoped session notes for the split text editor: untitled panes can save directly to `.chau7/sessions/<tab-id>/note.md` inside the active repository, and reopen the matching note for whichever repo the tab is currently in.
- Click-to-copy document name in the editor pane header.
- Multi-language syntax: HTML, CSS, JavaScript, Python, and more.
- Append terminal selection to editor (`Shift+Cmd+Opt+E`) — selecting text in the terminal and hitting the shortcut appends it to the side editor; if no editor pane is open, one is opened on demand so the shortcut never silently fails.
- Repository pane (`Cmd+Opt+B`): full git UI — stage, commit (⌘Enter), branch, push/pull, stash, history with search. Session-aware: shows only agent-touched files with diff stats when an AI is active, resets after push. Ahead/behind indicator, hover tooltips, conventional commit chips. Supporting value types live in a dedicated `RepositoryPaneTypes.swift` as a first scaffolding step toward separating status / commit / history into their own observable sub-states.

### Windows

- **Overlay / floating terminal** — on top of all apps with blur background.
- **Dropdown terminal** — `Ctrl+`` quake-style with configurable height.
- Multiple windows (`Cmd+N`), adjustable opacity, native fullscreen.
- Minimal mode — strip all chrome for maximum terminal space.
- Window position memory per workspace, session restoration on relaunch.
- Session restoration keeps production tab-state backups isolated from dev/test bundle writes and retains the multi-window recovery payload until the next save replaces it.
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
- Clipboard history (`Cmd+Shift+V`) — configurable, default 50 entries (up to 1000), LRU eviction, pinning.
- Paste escaping for shell-sensitive characters ($, backticks, quotes).

### Snippets

- Snippet manager (`Cmd+;`) — create, edit, delete, import, export.
- Three scopes: global (user), per-SSH-profile, per-repo (`.chau7/config.toml`).
- Placeholder support: numbered tab stops `${1:default}` (`${0}` = final cursor position) plus dynamic tokens `${cwd}`, `${home}`, `${date}`, `${time}`, and `${clip}`.

### History & Bookmarks

- Per-tab and global command history (arrow keys and `Cmd+Up/Down`).
- SQLite-backed persistence — searchable and fast.
- Session analytics: command frequency, timing, success rates.
- Terminal bookmarks — pin positions and navigate back.

### Command Palette

- `Cmd+Option+P` — fuzzy-searchable command palette (VS Code style).

### Notifications

- Native macOS desktop notifications for task completion, failures, permissions.
- Notification subtitles show repo, tab, or directory context so concurrent agent sessions are easier to distinguish.
- Dock badge and bounce (critical/non-critical).
- Configurable sounds (Glass, Purr, etc.) with volume control.
- Command idle detection with configurable threshold. Fires once per session, resets only on real user activity.
- Auto tab styling on events. The completion (green) highlight now stays until you open the tab instead of auto-clearing after a timeout — opening a tab clears its non-persistent highlight, while permission highlights persist until the prompt is resolved. Deduplicates redundant re-applies, clears persistent approval styling as soon as the approval is resolved, and can highlight every affected tab for file conflicts. The live-tab lookup, deferred-retry scheduler, auto-clear timer, and redundant re-apply suppression all live on a dedicated `StyleTabCoordinator` so the path is unit-testable in isolation.
- Visual bell mode (screen flash), combinable with audible bell.
- Bell rate limiting with configurable minimum interval, scoped per trigger and tab/session/directory identity.
- Rate limiting and per-trigger enable/disable.
- Authoritative-routing retry, post-close suppression, fallback-shadow suppression, and repeat suppression all run through one `NotificationDeliveryPolicy` per-step verdict (`pass` / `drop` / `scheduleRetry`) so the manager's `processEvent` stays a thin orchestrator.
- Per-repo event filtering and notification routing key off the `AIEvent.repoPath` field; explicit-tab rebinds round-trip every field via `AIEvent.replacingTabID(_:)` so `repoPath` survives even when the session-resolver corrects an explicit tab ID to a different one.
- Action `runScript` enforces its configured timeout with SIGTERM → SIGKILL escalation via a shared `ProcessRunner` so trap-immune or I/O-blocked scripts can't hang past the timeout.
- Webhook / Slack / Discord notification actions use a dedicated ephemeral `URLSession` (15s request timeout, 30s resource timeout, no cookie storage) instead of `URLSession.shared`, so bad endpoints fail fast and can't pollute the shared cookie jar.
- Every notification action is implemented as a `NotificationActionHandler` registered in a per-type registry (25 actions grouped into 7 category files: Basic / Automation / Integration / DevOps / Productivity / Accessibility / TimeTracking). The executor is a thin dispatcher; adding a new action requires one handler type + one registry entry, no edits to the executor.
- The notification system consults a single `NotificationDeliveryHost` protocol for tab title, repo name, active-tab check, and tab routing — `TerminalControlService` conforms, and the app wires it via `NotificationManager.setHost(_:)` at startup. Replaces five separate closure properties that all routed to the same service.
- Notification manager + action executor are constructed via a single `NotificationServices` composition root (no `.shared` singletons): `init()` wires the executor as the manager's action dispatcher and the manager as the executor's publisher, then AppModel holds the bundle as `notifications: NotificationServices?` injected at app startup. View-layer callsites that can't easily thread an explicit reference find the same instance via `NotificationServices.current`.
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
- Optional iCloud sync across devices — freshness-guarded: only blobs strictly newer than this Mac's last synced state apply, newer-format exports are refused, and fields absent from a blob keep their local value instead of resetting to defaults.
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
- Hardened relay authentication — scoped, single-use HMAC tokens (per device/role/endpoint) carried in the `Authorization` header defeat replay and connection-takeover; the relay fails closed when no secret is configured, rate-limits per device, validates and size-caps every request, and applies WebSocket backpressure. The relay uses Cloudflare Hibernatable WebSockets so idle sessions no longer pin the Durable Object in memory.
- iOS 18 minimum target — the Chau7 Remote app and widget extension deploy to iOS 18.0 (`IPHONEOS_DEPLOYMENT_TARGET = 18.0`); the shared SwiftPM package declares an `.iOS(.v17)` floor for library targets.
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
- Review automation is built from tab-first scripting primitives such as `create_tab`, `run_command`, `get_tab`, `send_input`, `submit_prompt`, `get_output`, `close_tab`, and `get_repo_events`.
- Repo-local pre-commit review automation via `scripts/pre-commit-review`, which creates a review tab, launches Codex, waits for the app to become interactive, sends the staged-diff prompt, validates and submits it, polls PTY output for the final structured JSON block, and prints findings in hook-friendly terminal output.
- Repo-scoped event retrieval for automation via `get_repo_events`, which returns recent AI events with full stored messages plus filters for tab, type, producer, and session. The pre-commit reviewer now prefers this authoritative stored result path before falling back to terminal transcript scraping.
- Per-repo pre-commit review policy via `.chau7/pre-commit-review.conf` with gate modes (`off`, `advisory`, `high`, `any`), timeout, backend, and model selection. The shipped default reviewer model is `gpt-5.3-codex`.
- Optional verbose tracing for the hook via `--verbose` or `CHAU7_PRE_COMMIT_REVIEW_VERBOSE=1`, including per-step scripting timings and fallback decisions.

### Debugging

- Debug console (`Cmd+Option+L`) — 10 tabs: State, Token Optimizer, Events, Lag, Perf, Logs, Report, Analytics, Health, Repos.
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
| Cmd+Shift+T | Reopen closed tab |
| Cmd+Option+R | Rename tab |
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
| Cmd+Option+P | Command palette |

### View and Terminal

| Shortcut | Action |
| --- | --- |
| Cmd+K | Clear screen |
| Cmd+Option+K | Clear scrollback |
| Cmd+= | Zoom in |
| Cmd+- | Zoom out |
| Cmd+0 | Actual size |
| Cmd+Up | Previous input line |
| Cmd+Down | Next input line |
| Cmd+Ctrl+F | Toggle full screen |

### App and Tools

| Shortcut | Action |
| --- | --- |
| Cmd+, | Settings |
| Cmd+Option+L | Debug console |
| Cmd+Shift+D | Data Explorer |
| Cmd+Shift+O | SSH connections |
| Cmd+Shift+S | Export text |
| Cmd+P | Print |
| Cmd+Option+I | Report issue |
| Esc | Close overlays (search, rename, snippets, etc.) |
| Ctrl+` | Toggle dropdown terminal (if enabled) |

### Panes

| Shortcut | Action |
| --- | --- |
| Cmd+D | Split horizontally |
| Cmd+Option+D | Split vertically |
| Cmd+Option+E | Open text editor |
| Cmd+Option+O | Open file preview |
| Cmd+Option+Shift+D | Open diff viewer |
| Cmd+Option+B | Repository pane |
| Cmd+Option+Shift+E | Append selection to editor |
| Cmd+Control+G | Agent dashboard |
| Cmd+Control+W | Close pane |
| Cmd+Option+] | Focus next pane |
| Cmd+Option+[ | Focus previous pane |
| Cmd+Option+G | Show changed files |

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

## Quality Gates

- The full XCTest suite (3,000+ tests) compiles and runs under `swift test` — no test files are gated out of the package build, and a pre-commit guard rejects new `#if !SWIFT_PACKAGE` gates.
- Distribution versions derive from git tags and fail loudly when underivable; the Rust toolchain is pinned; app signing is strictly inside-out (no `--deep`); and the pre-commit guard rejects new `#if !SWIFT_PACKAGE` test gates so dead tests cannot be reintroduced.
- Persistence paths follow the `Persist` logged-failure convention end to end: settings, SSH profiles, remote approval frames, telemetry responses, repo injection rules, and scrollback reloads log corruption and write failures instead of silently degrading.

- **Registry-driven hook policy** — `.husky/pre-commit` and `.husky/pre-push` only select `pnpm quality:staged` or `pnpm quality:prepush`; the gate contract lives in `scripts/quality/registry.mjs`.
- **Affected-surface pre-push** — pre-push reads Git update lines, resolves changed files against the pushed remote SHA or a conservative fallback base, and automatically upgrades to `prepush-full` for high-impact infrastructure, dependency, config, generator, workflow, or shared-contract changes.
- **Reproducible failures** — failed gates print stable ids, scope, wave, rerun commands, cache/attestation status, and per-gate log paths under `.aeptus-cache/quality/outputs/`.
- **Content-sensitive cache** — cache keys include runner/registry/cache code, lockfiles, tool versions, gate inputs, changed file contents, relevant env vars, and untracked files inside declared input directories; failed gates are never cached.
- **Security-first staged checks** — staged commits block high-signal secrets, unsafe dependency changes, Python exception/debug placeholders, JS/TS debug and unsafe DOM patterns, and legacy design/docs/source-policy violations before commit.
- **Live dependency audits** — full-suite quality mode runs non-cacheable npm audits for tracked Node lockfiles at the repository's high-severity threshold, with a Python dependency audit gate registered for future `pyproject.toml` or `requirements*.txt` inputs.
- **Registry-tested quality logic** — runner, registry, cache, impact, dirty-worktree, filtering, JSON output, and attestation behavior are covered by a `quality-runner-tests` gate.
- **Feature-inventory schema gate** — a `staged-features-csv` gate runs `scripts/check-features-csv.mjs`, deterministically rejecting any `features.csv` row that isn't exactly five well-formed columns with a valid `Status`/`Differentiator`, so the machine-readable inventory can't silently rot (the failure mode that once let dozens of malformed rows land unnoticed).
- **Generated feature inventory** — `docs/features.json` is the single source of truth; `features.csv` is generated from it (`pnpm features:generate`) and a `staged-features-csv-generated` gate `--check`s that the committed CSV matches the manifest, so the two can't drift and the CSV can't be hand-corrupted.

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
│   ├── chau7-issues/            # Cloudflare Worker bug-report intake (issues.chau7.sh)
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
## Additional Notes

- SwiftPM package metadata excludes each directory's `README.md` from resource scanning so per-directory docs aren't bundled as app resources.
- Background terminal snapshots can fall back to cached remote transcript text when the live terminal view is detached, and notification trigger/style logic now treats elicitation plus tool/response failures as first-class interactive events.
- `tab_output` can read a fresher active AI PTY log tail for MCP-driven tabs, improving retrieval of live Codex and Claude responses.
- PTY log tail parsing normalizes terminal control sequences and backspaces before downstream consumers read the transcript.
- Deferred restore scheduling backs off during rapid tab switching, prioritizes tabs nearest to the selected tab, and logs per-tab restore stage timings with RSS deltas.

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
- Live process-tree resolution. Each session polls descendants of its shell PID and matches executable basenames against the registry — the OS is the ground truth for identity. The nearest AI descendant owns the terminal, so a nested child agent cannot replace its outer agent's tab identity; a tab labeled Codex that starts running Claude still updates to Claude within ~1.5s without requiring user action.
- Claude cross-repo cwd writeback. Claude hook and idle events carry the session's authoritative cwd even when the host shell cannot see a `cd` performed inside Claude's TUI; when the live Claude session id matches the tab, Chau7 lets that cwd cross repo boundaries so path display, snippet context, and automatic repo grouping follow the real project.
- Pre-notification AI identity adoption. Validated Claude hook and idle events atomically hydrate the tab's provider, session ID, and identity source before notification filtering, so they can fix both Shell-labeled tabs and stale cross-provider tuples immediately while still staying out of user-facing notification history.
- Command line tokenization with wrapper skipping (env, sudo, command, builtin, exec, noglob, time). Command detection gates output scanning to prevent false positives.
- Output banner matching for all supported CLIs. Patterns require tool-specific context to avoid substring collisions, and exclude API-endpoint/website substrings (e.g. `openai.com/v1`) that appear in ordinary project code rather than CLI banners.
- Corroborated output origination. An output-pattern match can only *originate* a new tool identity on a tab that has none when a live process-tree signal corroborates it; otherwise output matching only *confirms* an already-established identity. This prevents incidental output — an API URL printed by a `git push` in a repo that uses that API — from flipping a plain shell to an AI tool.
- Custom detection rules with display name and tab color.

### AI Features

- **Aethyme pull-request activity delivery** — a background adapter polls Aethyme only for repositories represented by live tabs, advances due PR watches, and claims provider-neutral outbox items with generation fencing. Delivery requires the exact subscribed tab, AI session, repository, idle/done state, ready prompt, and empty staged MCP input; busy targets retry and identity drift fails closed. Aethyme retains observation, deduplication, authorization policy, and durable delivery ownership so Chau7 remains one replaceable delivery client.
- **Live AI session binding validation** — provider hook events must agree with the AI provider currently displayed in their stamped terminal tab. A stale Claude mapping is quarantined when that tab is visibly running Codex, preventing obsolete CWD and lifecycle updates from mutating the live tab while preserving shell returns and same-provider restarts.
- **Accurate terminal scan diagnostics** — dangerous-output timer lateness is labeled `scan_queue_delay` in warnings rather than implying that row scanning took that long. Structured lag compatibility is preserved, and actual visible-row refresh duration remains independently profiled.
- **Mature latency warning signals** — every threshold-crossing terminal latency event remains in structured telemetry, while warning logs require a mature sample window and either sustained p95 degradation or a three-times-threshold event. Startup and isolated moderate outliers remain measurable without becoming operational noise.
- **Expected event log severity** — routine multiline-paste interception remains auditable at info level, while idempotent attention-style cleanup for an already-closed tab is debug-only. Warning severity remains reserved for actual confirmation, blocking, homoglyph, and operational failure paths.
- **Provider status outage backoff** — application-wide provider polling collapses an all-provider transport outage into one classified summary and exponentially backs off from one to fifteen minutes. Partial or successful refreshes reset the backoff and existing fresh observations remain available.
- **PTY startup activity detection** — shell readiness counts both rendered grid changes and metadata-only terminal events such as OSC-7. All drain modes cancel the startup watchdog on first activity, so a responsive shell whose control sequences are consumed before raw-output capture is not mislabeled as hung.
- **Approval timeout isolation** — every runtime approval timeout carries its request ID and can expire only that request. Late callbacks cannot touch a newer approval, and multiple independently unanswered approvals fail their turns without escalating an otherwise healthy runtime session to failed.
- **Owned terminal shutdown escalation** — every graceful-close escalation revalidates the shell's PID plus kernel start time, direct app parent, and non-zombie state before signaling. PID reuse, process reparenting, completed-but-unreaped shells, and permission failures stop escalation instead of risking an unrelated direct-PID kill.
- **Single-instance ownership** — Chau7 takes a process-lifetime lock before restoring tabs, redirects duplicate launches to the existing process, and makes Unix socket cleanup conditional on the listener still owning the bound filesystem identity. An older process can therefore neither duplicate restored shells nor remove a newer MCP or scripting endpoint during shutdown.
- **Menu Bar Command Center** -- the macOS status item summarizes live AI sessions across all overlay windows, prioritizes approval-required, waiting-input, and stuck sessions, opens the exact terminal pane, exposes pinned snippets as Insert actions with clipboard fallback, and deep-links Monitoring and Snippets settings.
- **Codex feedback prompt detection** — each active Codex session tails its rollout for structured `request_user_input` calls, publishes authoritative waiting-input attention and clears it on the matching result; bounded catch-up, asynchronous rollout lookup retries, call-id deduplication, and failed-tool debounce keep the lifecycle deterministic. Completed turns that conservatively end in an explicit choice or confirmation request remain a heuristic fallback instead of false completions.
- **Crash-safe Codex resume recovery** — autosave resolves a known Codex pane's missing session ID from its existing rollout before publishing restore state. If a crash leaves only provider evidence, restart preserves that evidence for a provider-scoped transcript lookup; rejected, duplicate, foreign-project, and all-nil identities remain ineligible so tabs sharing a repository cannot collapse onto one session.
- **Cross-provider resume identity repair** — autosave and restore correct a stale Claude/Codex provider only when its exact session artifact is absent and the alternate provider has an exact artifact for the same session ID and repository. Chau7 preserves the session ID, rebuilds the canonical resume command, and keeps provider-scoped ownership deduplication intact.
- **Confidence-tiered Codex prose classification** — completed-turn prose is assessed as high, medium, or low confidence with explicit evidence. Enumerated choices and direct terminal questions request attention; conversational questions stay low-confidence and retain completion semantics.
- **Codex feedback monitor health** — the debug console exposes whether rollout discovery is active or exhausted and, once attached, the rollout name, total lines observed, structured interaction records parsed, and unresolved prompt count.
- **Optional Codex App Server interaction ingestion** — an opt-in transport can feed request-user-input, approval, and resolved JSON-RPC messages into the same authoritative attention publisher used by rollout monitoring. Shared question parsing and pending-request tracking handle overlapping interactions without changing the default PTY launch path.
- **Fresh Codex rollout discovery retries** — the global session-file index refreshes after a miss, allowing asynchronous monitor discovery to recover when Codex creates a rollout after the first lookup instead of repeating one stale cached result.
- **Provider service-health borders** — one application-wide monitor polls the official Anthropic, OpenAI, GitHub, and Google Cloud status feeds, maps their provider-specific payloads to a shared health model, and outlines the focused AI tab's window in orange for degraded service or red for an outage. Five-minute freshness expiry prevents stale observations from masquerading as current incidents, and the border can be disabled in Tabs settings.
- **Chau7CLI repo skills support** — `chau7-cli skills --scope repo` validates `.chau7/skills/<skill-id>` sources, installs/syncs them into repo-local `.claude/skills/<skill-id>` and `.codex/skills/<skill-id>` targets, and resolves relative skill paths from the command working directory for repo-specific agent setup.
- **Chau7CLI skills commands** — `chau7-cli skills` provides `list`, `doctor`, `install`, `update`, `uninstall`, `validate`, `diff`, and `sync` commands over built-in Agent Skills, using shared Chau7Core validation, install inspection, planning, and installer logic for Claude/Codex user targets, with `all` reporting invalid source directories instead of silently skipping them.
- **Chau7CLI local installer** — `Scripts/install-chau7-cli.sh` builds the SwiftPM `chau7-cli` product and installs both `chau7-cli` and a `chau7` wrapper into `~/.local/bin` by default, enabling the documented `chau7 skills ...` command surface without a conflicting lowercase SwiftPM product.
- **Chau7 built-in Agent Skills** — Chau7 ships `chau7-magi` and `chau7-mcp` Agent Skills under `Resources/Skills`, covering MAGI usage, CLI invocation, verdicts, artifacts, replay/share, council-output integrity, direct-answer versus council decisions, safe Chau7 MCP orchestration, diagnostics, permission boundaries, and the rule to never kill Chau7 itself.
- **Chau7 Skills installer** — `Chau7Core` installs managed Agent Skills by validating the canonical source, building the install plan, staging a copied skill, injecting `.chau7-skill.json`, validating the staged directory, verifying existing managed manifests match the requested target, backing up replaced targets, swapping the provider install directory with rollback on replacement failure, and returning a structured final state without mutating the source skill.
- **Chau7 Skills install planner** — `Chau7Core` computes pure Agent Skills install plans from source validation, provider availability, target presence, managed manifests, source hashes, and installed file hashes, covering missing/install, installed/no-op, stale/update, modified/refuse, unmanaged conflict/refuse, invalid source/refuse, and unsupported provider/refuse outcomes.
- **Chau7 Skills manifest hashing** — `Chau7Core` deterministically hashes managed Agent Skill files, excludes Chau7/Finder metadata, and builds/writes `.chau7-skill.json` manifest data with source/target metadata, aggregate source hashes, and per-file hashes.
- **Chau7 Skills provider targets** — `Chau7Core` resolves Claude and Codex user/repo Agent Skills install targets and conservatively detects provider availability from provider roots, provider CLIs on `PATH`, or explicit user provider requests, with the CLI treating `--provider` as the explicit override.
- **Chau7 Agent Skills validator** — `Chau7Core` validates the shared Agent Skills folder contract, including `SKILL.md` YAML frontmatter, required `name`/`description`, lowercase kebab-case names, folder/name matching, and optional `scripts`, `references`, and `assets` directories while allowing unknown provider-specific frontmatter.
- **Chau7 skills model foundation** — `Chau7Core` defines the pure model layer for managing standard Agent Skills across providers and repositories, including skill IDs/sources, providers, user/repo scopes, install targets, lifecycle states, file hashes, Chau7 management manifests, install plans, and validation issues.
- **MAGI multi-agent decision protocol** — CLI-first council mode that launches three isolated agents through Chau7 MCP, applies editable member personas, shares only controlled council packets between rounds, applies explicit ask/auto-deny/preapproved evidence policy, resolves majority/final-vote-veto verdicts using canonical decision IDs plus material conditions, and writes replay/share artifacts.
- **MAGI command surface** — `magi`/`MAGI` supports direct questions, `ask`, `doctor`, `config`, `replay <run-id>`, and `share <run-id>` with local artifacts only in v1, plus `--mode engineering|generic` for explicit verdict mode selection. The CLI entrypoint is split into focused parser, home TUI, config panel, first-run wizard, doctor, and replay/share command modules.
- **MAGI local installer** — `Scripts/install-magi-cli.sh` builds the SwiftPM CLI and installs `magi` into `~/.local/bin` by default, with uppercase `MAGI` invocation supported through case-insensitive resolution or a case-sensitive alias.
- **MAGI production artifacts** — running stages write lightweight decision JSON plus manifest checkpoints with artifact status and SHA-256 hashes, while failed, interrupted, vetoed, deadlocked, and completed terminal states carry checkpoint/failure metadata across decision markdown, decision JSON, transcript/replay JSONL, graph JSON, local share HTML, manifest JSON, and terminal replay rationales.
- **MAGI hardened CLI runtime** — missing Chau7/MCP, provider launch failures, agent timeouts, malformed structured output, denied evidence, veto/deadlock outcomes, interrupts, and partial artifact replay paths are surfaced as clean statuses with useful local logs, with orchestration split across focused round, capture, evidence, checkpoint, terminal rendering, and typed MCP-boundary DTO components.
- **MAGI per-run technical log** — each run writes `technical.jsonl` next to the required artifacts with correlated run/member/tab events for launches, prompt visibility, prompt submission, agent-running checks, polling, parsing, repairs, checkpoints, and failures.
- **MAGI MCP launch contract** — MAGI trusts the structured `agent_launch` `prompt_input_visible`, `prompt_submitted`, and `agent_running` fields instead of duplicating provider readiness heuristics in the CLI, failing clearly when the launch contract is incomplete.
- **MAGI prompt injection readiness** — `agent_launch` waits for a recognizable provider input surface in the live tab buffer before typing, then reports structured prompt verification fields that MAGI consumes as the launch contract.
- **MAGI launch exit detection** — `agent_launch` caps prompt-injection waits and reports `agent_exited_before_prompt` when a provider command exits before receiving the prompt, avoiding opaque MAGI MCP socket timeouts.
- **MAGI event-backed result capture** — MAGI polls Chau7's tab-scoped AI completion events before PTY output and collects pending council members as soon as each finishes, so one slow member no longer blocks parsing completed responses from the other tabs.
- **MAGI bounded structured repair** — structured-output repair ignores stale prior completion events, uses small PTY tails during normal progress, escalates to full stable output only for parse/repair/failure paths, sends only the relevant transcript excerpt to the repair prompt, and waits for idle/stable output before repairing echoed prompt markers or partial blocks.
- **MAGI MCP contract preflight** — `magi ask` verifies that the running Chau7 MCP socket supports filtered, full-message repo events before launching agents, failing immediately with a restart instruction when the app process is stale.
- **MAGI home TUI** — running `magi`/`MAGI` without arguments opens an interactive terminal home screen with progressive boot output, ASCII art, colored member panels after boot, boot-status lines ending on the selected council, an ask prompt that returns after each run, help, doctor access, and `--config` navigation.
- **MAGI config panel** — `--config` opens an editable terminal panel for member provider/class/model settings, resolved launch commands, supported provider reasoning flags, global evidence policy/web/deadlock/veto switches, provider checks, and persona file checks.
- **MAGI council configuration split** — global `~/.chau7/magi/config.toml` stores runtime policy and the selected council, while `~/.chau7/magi/councils/<council-id>.toml` stores member provider/class/model bindings, persona-file mapping, weights, display name, and majority threshold with legacy global member sections still accepted for migration.
- **MAGI visible first-run wizard** — `magi config` renders provider and model-class choices as numbered lists in interactive terminals and explains stdin/stdout TTY state when the wizard cannot open.
- **MAGI shared first-run setup** — `magi config` can apply one provider/class choice to Melchior, Balthasar, and Casper, with a per-member path still available for mixed-provider councils.
- **MAGI evidence collector cleanup** — approved collectors run in temporary Chau7 tabs that close through immediate cleanup defers, nonzero collector exits create failed evidence packets, and disabled-web, unsupported, or missing collectors are skipped before approval prompts instead of silently falling back to repo status.
- **MAGI deliberation transcript** — live `magi ask` output renders the council as staged debate, frames fact gathering as approved deliberation material, and records vague uncollectible requests as `skipped`.
- **MAGI run presentation** — `magi ask` uses ANSI color when available, member accents, compact collector status markers, a single high-speed in-place processing line while waiting, light phase member-status lines, inferred mode explanations, and a final verdict summary with decision, confidence, rationale, member votes, vetoes, and artifact path.
- **MAGI council ASCII art** — interactive home and ask flows show the MAGI ASCII logo plus editable council launch art from `~/.chau7/magi/councils/<council-id>.md`.
- **MAGI council tab lifecycle** — council agent tabs are named for Melchior, Balthasar, and Casper during launch, then auto-close after checkpointing unless `auto_close_agent_tabs` is disabled.
- **Branded tab logos** — detected agents show their brand logo in the tab when one is bundled; the rest fall back to their brand tab color.
- **Auto tab theming** — tabs adopt the brand color of the active AI agent.
- **LLM error explanation** — one-click error analysis via OpenAI, Anthropic, Ollama, or custom endpoint.
- **Claude Code deep integration** — monitor hook events: prompts, tools, permissions, responses.
- **AI event notifications** — finished, failed, permission, needs_validation, tool_complete, session_end, idle. Agent defaults cover the two moments that matter: the agent is waiting on you (permission / waiting_input / attention_required / elicitation) and the agent has finished working (finished / failed / response_failed). All of those bounce the Dock icon by default — once for completion, continuously (critical) until focused for approval/feedback. Noisy generic shell `command_finished`/`command_failed`, AI `idle`, and `tool_failed` events remain off by default and toggleable in settings. Banners include repo/tab/directory context in the subtitle when available.
- **Shell script outcome attention** — authoritative shell exit statuses surface conservative package scripts, executable script files, and build/test task runners by default: success gets a green tab highlight, failure gets red, and an inactive tab gets a native notice. Outcome highlights remain until the tab is opened. Dev-server starts use the existing output/listening-port monitor so green means the server is ready; missing heuristic exit codes and intentional Ctrl-C/SIGTERM shutdowns stay quiet.
- **Resilient waiting-input attention** — waiting-input and attention-required events keep persistent tab highlights even when duplicate suppression, rate limits, or disabled idle actions suppress the follow-up notification path.
- **DND-independent tab attention** — Focus modes suppress banners, sound, and other intrusive actions while retaining configured or default tab styling. Explicitly disabled notification rules remain fully disabled.
- **Canonical notification semantic precedence** — provider-native event types remain available for audit, but the canonical trigger selected by the adapter is the single behavioral meaning used by tab attention and resolution. Codex turn-complete payloads reclassified as feedback requests cannot regress to completion downstream.
- **State-driven tab attention** — terminal session state is reduced through a pure policy so `waitingForInput` / `approvalRequired` tabs have a single source of truth independent of banner delivery. The overlay reconciler repairs missing highlights from live state without replaying native notifications, and `attentionReport` diagnostics expose state/style mismatches in snapshots and tab summaries.
- **Terminal wait-pattern backstop** — terminal-side AI prompt detection emits lower-confidence attention events as soon as a TUI appears blocked, closing provider-hook delays while preserving authoritative hook precedence.
- **Completed-turn tab styling** — a finished Claude turn styles its tab with the green success preset (non-persistent, retained until the tab is viewed) rather than the orange "waiting" style, so a completed agent no longer glows as if it were still blocked on you. The turn-completion fallback resolves to `task_finished` (not a synthetic `waiting_input`), and the PTY wait/approval heuristic matches only the trailing output region so a reply that merely contains a trigger word ("Proceed?", "[y/N]") can't flip a finished turn back to waiting-for-input.
- **Canonical completion highlight fallback** — producer-specific completion aliases without a direct presentation row resolve through the canonical finished trigger, guaranteeing the same non-interactive success highlight for low-confidence Codex prose and normalized completion events.
- **Attention events reopen terminal-marked sessions** — an authoritative interactive-attention observation reopens a session the reconciler had already marked terminal, so providers that emit no raw lifecycle events between turns (notably Codex) still surface permission prompts that arrive after the first turn instead of being swallowed.
- **Turn-aware reconciliation without lifecycle hooks** — later interactive observations reopen a new turn after the terminal coalescing window, while immediate fallback signals remain classified as lagging evidence from the completed turn. Long-lived Codex sessions no longer stay terminal forever when no start event is emitted.
- **Multi-provider event normalization** — Claude, Codex, and terminal sources translate provider-specific events into one shared semantic layer. Authoritative events from runtime and hooks take priority over history-derived fallbacks.
- **Centralized event source adaptation** — generic AI, terminal-session, fallback-history, shell, app, API proxy, and unknown-source events share one tested mapped-source adaptation path while keeping source-specific routing and reliability policy explicit.
- **Event publisher abstraction** — app and shell event producers publish through a narrow `AIEventPublishing` boundary, keeping event detection decoupled from concrete `AppModel` storage and notification state.
- **Session-aware notification routing** — notifications route by exact AI session ID with fallback to provider/title heuristics. Handles tab restoration, split sessions, nested working directories, and cross-tab file conflicts.
- **Indexed AI session routing** — notification delivery, runtime strict-session lookup, and history adoption use a cached cross-window routing index built from live sessions and deferred restore metadata before falling back to recovery heuristics.
- **AI-first notification settings** — simplified overview for Finished, Failed, and Permission Request with direct controls for banner, tab highlight, sound, and dock bounce. Waiting-input and attention-required states surface as “needs me” attention. Per-tool overrides and advanced trigger plumbing available separately.
- **Notification delivery ledger** — lifecycle tracking for debugging: coalescing, retry scheduling, drop reasons, and real UI outcomes.
- **Structured notification delivery outcomes** — each ledger transition is projected as a correlated runtime event with semantic/raw type, trigger, actions, banner/style results, routing, suppression reason, and Codex prose confidence evidence.
- **Replay-based notification attention tests** — versioned Codex and Claude fixtures exercise the full pure notification engine from provider payload through canonical semantics, turn reconciliation, and style choice, including known missed-input and false-positive completion patterns.
- **PTY output logging** — capture raw terminal output for AI tool sessions.
- **Codex session resolver** — maps Codex sessions to working directories with a bounded metadata cache.
- **Generation-tokened event drain** — drain runloops capture a generation at start; any start/stop invalidates older loops, and the log sink, deallocation flags, and poll diagnostics are lock-guarded.
- **Queue-confined monitors** — dev-server detection, file tailers, shell-event detection, the shared process-tree snapshotter, and the remote IPC server each confine mutable state to one owning queue, so UI calls can never race their timers.
- **Retry-not-give-up watchdogs** — file monitors re-arm with backoff after delete/replace, tailers re-arm on rename with bounded per-tick reads, and the terminal dylib loader retries after a cooldown instead of disabling terminals until relaunch.
- **Pane-owned AI restore** — split tabs restore resume commands from each saved terminal pane’s own metadata instead of inferring ownership from whichever pane is focused after layout rebuild.
- **Restore ownership validation** — pane resume prefills now verify directory and restored AI identity before insertion, so stale retries fail closed instead of landing in the wrong pane.
- **Rejected Claude resume state stays cleared** — autosave derives fallback resume commands only from provider/session metadata that passed transcript validation, so an obsolete raw `claude --resume` command cannot reappear across later save cycles while valid Claude and Codex restores keep using their canonical command builders.
- **Deduplicated Claude resume rejection diagnostics** — a missing-transcript warning is emitted once per canonical session-and-directory identity across candidate validation and repeated autosaves, while different rejected identities still produce their own warning.
- **Corroborated Codex resume identity** — an authoritative Codex notify hook addressed to an exact tab may replace that tab's stale restored identity after a checkout moves only when the local rollout corroborates the reported session and directory. Another pane's ownership still wins.
- **Codex rollout-validated persistence** — UUID-shaped Codex session identities must resolve to a local rollout before autosave or restore can trust them, so obsolete resume commands are dropped instead of surviving another relaunch. Exact persisted IDs search the complete dated rollout archive, while directory-based identity guesses keep their bounded recency window. Opaque legacy IDs remain compatible, and resolver caches are isolated by the effective Codex sessions root.
- **Precise resume-injection diagnostics** — restore logs distinguish inserting the resume command into the terminal from the provider actually accepting or running it, so investigations do not mistake a prefill delivery for a successful session resume.
- **Lossless live-TUI suspension** — memory-pressure demotion keeps a live TUI's uncached scrollback ring resident instead of shrinking it to the hidden 50-line floor, because flattened text replay cannot reconstruct alternate-screen state. Canonical restored-session identity protects Claude and Codex before process-tree detection catches up, including normal-screen TUI modes, and transient detector misses cannot clear that protection while lifecycle evidence remains active; dormant-to-visible transitions and late TUI identification both deliver a coalesced `SIGWINCH` redraw without requiring a manual pane resize.
- **Restore delivery ledger** — pane resume restore now records scheduled, queued, delivered, rejected, and superseded outcomes per pane so stale retries are explicit in logs and tests instead of silent.
- **Restore supersession guard** — stale retry callbacks can no longer overwrite a newer pane’s delivered restore outcome, so the ledger keeps the winning pane state instead of regressing to `superseded`.
- **Identity-tolerant resume prefill** — resume-prefill validation treats unresolved current AI identity as a soft match instead of rejecting, so the prefill survives the post-launch window before output-derived provider/session corroboration completes. Confirmed mismatches still reject.
- **Canonical directory match for resume prefill** — directory-ownership comparison canonicalizes both expected and live paths via symlink resolution, tilde expansion, and standardization before comparing, so `/var` ↔ `/private/var`, trailing slashes, `..` segments, and historical `~/proj` saves no longer produce string-inequality rejection on equivalent paths.
- **Phase-independent idle scrollback flush** — warm-idle tabs flush their scrollback ring to disk losslessly (ANSI/SGR preserved via the lossless capture FFI) and shrink to the viewport floor without changing render phase. On reselection the cached ANSI buffer is replayed and the ring grows back to the configured capacity, so long-lived background tabs free history memory without losing colors or re-pour fidelity. TUI / alternate-screen tabs are skipped.
- **Terminal background-work profiler** — backend output reads, grid snapshots, cursor-mode checks, persistence captures, and terminal-state processing are aggregated by render phase, visibility, and caller. Thirty-second diagnostics include processed bytes plus total, main-thread, and maximum duration, making hidden-tab work measurable without per-poll trace spam.
- **Off-main background terminal snapshots** — the shared drain consumes backend state and raw PTY bytes on its utility queue, then applies only UI state and callbacks on main. Drain-only tabs skip presentation grids and visible-buffer callbacks, while repeated scrollback flush requests reuse their verified cache.
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
- Tiered wrapper surface: read-only inspection commands (`cat`, `ls`, `find`, `tree`, `grep`, `rg`, `diff`, `sed`) plus a hardened set of executables (`git`, `cargo`, `swift`, `go`, `curl`) are shadowed on `PATH`. Executables are gated to idempotent read subcommands (e.g. `git status`/`diff`/`log`, `cargo build`/`test`) so mutations (`git commit`, `cargo publish`) and interactive/piped invocations pass straight through with a single exec; interpreters (`python`, `node`, `npm`, …) remain deferred. The former no-op exec-only wrappers (`head`/`tail`/`wc`) were removed.
- Hardened executable optimization: executable wrappers resolve the real binary at runtime from the live `PATH` (honoring venv/nvm/rustup, never a path baked at setup), gate on a per-command read-only subcommand allowlist for single-execution safety (the optimizer can never double-run a side-effecting command), bypass interactive (TTY) callers, and are protected against recursion by a `CHAU7_CTO_OPTIM_ACTIVE` sentinel plus a hardened `cto_bin` PATH strip inside `chau7-optim`.
- Wrapper PATH precedence: the zsh/bash/fish shell integration re-asserts `cto_bin` at the front of `PATH` after the user's rc files run (e.g. `brew shellenv`, which would otherwise prepend Homebrew), so Homebrew-installed commands (`git`, `go`, `rg`) are actually shadowed.
- Recent-window savings: the settings panel reports a rolling 7-day token-savings window (average savings and response time) alongside a lifetime tokens-saved total, so current performance is not masked by the cumulative all-time average.
- Safe wrapper installation: a wrapper is installed only when the command's real binary resolves (never shadowing a bare name with no target into a branded exit 127, which previously fired even with CTO off), and unsupported wrappers are pruned on setup so upgrades heal previously-installed names.
- Shell-accurate binary resolution: the wrapper's hardcoded real binary is resolved from the same login-shell `PATH` terminals launch with (Homebrew/volta/cargo/`~/bin` ahead of the system dirs), not the GUI app's minimal `PATH`, so a wrapped command never execs a different interpreter than the one the user's shell would (e.g. Xcode's `python3` instead of Homebrew's).
- Fail-safe optimizer: an internal `chau7-optim` error or panic exits 3 (the wrapper's fall-through code) so the real binary still runs and the reason is printed to stderr, instead of the wrapper mistaking the failure for optimized output and suppressing the command. Deliberate handler exit codes that follow real output (e.g. `grep`/`diff` no-match/differ) are preserved.
- Install diagnostics: setup logs an installed/skipped wrapper summary (with the skipped-command list) so a missing real binary is visible in the logs rather than surfacing only as a runtime failure. Real-binary PATH resolution — including the junction that it scans the login-shell PATH rather than the app's — and the wrapper exit-code fall-through contract are locked by unit and integration tests.

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
- **Unbounded active inference streams** — active provider requests are not capped by a proxy-wide total or response-write deadline, and every SSE chunk is flushed immediately so provider events and keepalives reach the CLI without buffering; requests remain open until completion or originating-client cancellation, while request-read and idle-connection protections remain bounded.
- **Orphan-proof helpers** — chau7-proxy and chau7-remote exit when the parent app dies (no port-holding orphans after a crash), and the proxy's auto-restart backs off exponentially instead of crash-looping every 2 seconds.
- **Durable call recording under lock contention** — API call writes that lose SQLite's WAL write lock are retried with backoff rather than discarded, so a checkpoint on a large analytics database cannot silently erase calls from the dashboards. Constraint and disk errors still fail fast, and an exhausted retry budget logs an explicit dropped-record warning.
- **Billable-endpoint token accounting** — token and cost estimation runs only for endpoints that return model output. Anthropic SSE parsing accepts spec-valid whitespace/framing variants and gateway-rewritten event types; fallback estimates produce bounded five-minute extraction summaries instead of one warning per request. Catalog listings (`/v1/models`), token counters, and other non-completion routes record no usage, while unrecognized routes fail closed rather than inventing an estimate.
- **OpenAI Responses usage normalization** — Codex request metadata and usage accounting recognize Responses API `input`, `max_output_tokens`, `input_tokens`/`output_tokens`, cached/reasoning detail fields, and nested `response.completed` SSE envelopes while retaining Chat Completions compatibility, so valid provider usage does not degrade into body-size estimates.
- **Token counting & cost calculation** — full token breakdown per call: input, output, cache creation, cache read, and reasoning tokens. Accurate cost calculation using provider-specific cache pricing (Anthropic 0.1x cache-read / 1.25x cache-write; OpenAI per-model cache-read rates, 0.1x–0.5x). Fallback estimation when extraction fails.
- **Cache-aware usage dashboards** — Usage Monitor, Debug Console analytics, and API analytics keep cache creation/read, output, and reasoning token buckets distinguishable while still showing aggregate billable traffic and cost.
- **Async usage analytics loading** — usage dashboards coalesce overlapping refreshes, run proxy analytics database reads off the main thread, and expose model-level cost rows.
- **Regional number formatting** — usage dashboards and cost displays use a configurable regional number format (French default, European, or US) independently of the app language.
- **Latency tracking** — total request duration and time-to-first-token (TTFT) per API call.
- **Deterministic latency-sample reads** — equal-timestamp samples retain their monotonic ingestion order through canonicalization, while throttled SQLite preparation diagnostics expose schema/query failures without flooding logs.
- **Versioned latency-sample sequencing** — telemetry schema v5 gives provider latency samples the same shared monotonic ingest sequence as runs, usage evidence, and remote events; v4 trigger definitions are replaced atomically so upgraded and fresh databases behave identically.
- **Echo-only input latency** — per-session input latency measures keystroke→echo responsiveness only; command submission (Enter) is excluded for every session, so a slow command's runtime is never miscounted as UI lag.
- **Configurable telemetry retention** — AI run history and full transcripts in `runs.db` are pruned at launch to a user-set window (default 30 days; `0` = keep forever, set in Settings → History), cascading to child rows and reclaiming disk with a full `VACUUM`, so the database can't grow without bound.
- **Bounded AI event queues** — the append-only hook event logs (`claude-events.jsonl`, `.ai-events.log`) are compacted to their most recent slice at monitor start (before tailing, while quiescent), so the transient event queues can't grow without bound; the durable record stays in the telemetry database.
- **Task detection & assessment** — auto-detect AI task candidates with confidence scoring; approve or fail with notes.
- **Baseline estimator** — calculate token savings from context caching.
- **Analytics dashboard** — command stats, error rates, API usage, and timing. Proxy health monitoring, timeline pagination, and per-agent cost display with cache/reasoning token breakdown (the analytics view refreshes on a fixed timer plus event-driven updates; the per-repo agent dashboard is the one with adaptive 2s active / 5s idle / 10s no-agents polling). Poll-cycle tracker state is confined to a serial refresh queue so commit actions and live polling can never race each other's bookkeeping.
- **Non-blocking session-event reporting** — prompt-injection session events post to the proxy asynchronously; a slow or wedged proxy can never freeze typing while the app waits for the local HTTP round-trip.
- **Background completion extraction for Codex/OpenAI runs** — run-end finalization no longer waits on heavy transcript extraction for OpenAI-family sessions. Completed rows are persisted immediately, then richer turns and tool calls are backfilled asynchronously when extraction finishes.
- **Recent proxy call context** — recent API calls in the Debug Console include local hour, repo name, and endpoint context for faster investigation.
- **Repo-level aggregated metrics** — per-repository stats (commands, success rate, AI runs, tokens, cost, providers, top tools) in Debug Console, Data Explorer, and hover card.
- **Indexed repository proxy summaries** — one project-indexed aggregate returns proxy totals, providers, and last-call time under a single database lock; repositories with no attributed rows skip hourly aggregation entirely, while populated summaries reuse the same connection for their trend.
- **Repo-aware debug labels** — per-tab token and CTO rows use `provider/custom title + repo`, with split-session disambiguation when needed.
- **Timeline visualization** — scrubber timeline showing command blocks and metrics.
- **Provider filtering** — include or exclude specific API providers.
- **Correlation headers** — `X-Chau7-Session`, `X-Chau7-Tab`, `X-Chau7-Project` for tracing (plus `X-Chau7-Context-Pack` for baseline estimation).
- **Reliable repository attribution** — Claude receives supported custom correlation headers and Codex carries its project through a proxy-only encoded path; both store the exact repository path without leaking Chau7 metadata upstream. New-call attribution ratios expose regressions, and repository/timestamp lookups use an index installed for both fresh and existing databases. Historical unattributed rows are deliberately left untouched because their repository cannot be inferred safely.
- **Proxy version-skew detection** — the proxy advertises its wire capabilities on `/health` and the app verifies them at startup, so a bundled binary older than the app is named as such (with the rebuild command) rather than appearing as a provider-side error. A proxy predating capability advertisement reads as missing all of them; an unreachable proxy is never reported as a mismatch.
- **Reliable concurrent persistence** — SQLite busy handling is configured for every pooled proxy connection, so overlapping API-call writes wait for the active writer instead of silently losing analytics records.
- **Freshly built bundled proxy** — the app build compiles `chau7-proxy` rather than copying whatever artifact was last left in `build/darwin`, so the bundled binary always understands the correlation path its paired Codex wrapper emits. The two halves are individually valid and only wrong together, so nothing else catches the skew before Codex sees a 404 from the upstream provider.
- **Subscription-safe Codex routing** — a shell-scoped wrapper invokes Codex with its supported `openai_base_url` configuration while preserving the built-in subscription-aware provider. Chau7's local proxy certificate is scoped to that Codex process and combined with an existing user CA bundle; missing trust fails open to direct Codex instead of breaking the CLI. HTTPS and WebSocket requests preserve ChatGPT authorization while Chau7's private repository correlation stays local to the proxy.
- **Claude gateway compatibility** — Chau7 appends its correlation headers after user shell configuration instead of replacing existing Anthropic organization or gateway headers. Proxy routing enables MCP tool search when the user has not chosen a value, preserves explicit preferences, and never replaces Claude subscription credentials.
- **Per-repository prompt injection** — inject content into API requests per repository via `~/.chau7/prompt-rules.json`. Rules match by repository name (portable) or absolute path, choose prepend to user message (default), append, or system prompt, and now control when injection fires: every prompt, the first matching prompt in a shell session, or the first matching prompt after `/compact` or `/clear`. Supports Anthropic Messages, OpenAI Chat Completions, OpenAI Responses (Codex), and Gemini, plus optional repo-local `.chau7/injection.json` overrides.

## MCP Server

Chau7 runs an embedded MCP (Model Context Protocol) server — your AI agents can see and control your terminal.

- Default MCP tab creation targets the active Chau7 overlay window, so new MCP tabs appear in the window currently in use without requiring an explicit `window_id`.
- Runtime launches that require a visible tab now fail explicitly when Chau7 cannot create one, instead of silently succeeding in a hidden PTY-only path.

### Architecture

- **Protocol**: JSON-RPC 2.0 over Unix domain socket (`~/.chau7/mcp.sock`).
- **Version negotiation**: The server negotiates the finalized `2025-11-25`, `2025-06-18`, and `2024-11-05` revisions, echoing a supported client revision exactly, and requires `initialize` then `notifications/initialized` before normal tool or resource calls.
- **Connection behavior**: Idle MCP client sockets stay open long enough for slower eval and manual-debug workflows instead of timing out after short pauses.
- **Bridge**: `~/.chau7/bin/chau7-mcp-bridge` (stdio-to-socket bridge for standard MCP clients).
- **Codex config self-healing**: Codex registration rewrites stale shell-wrapper commands and multi-line `args` arrays to direct bridge execution while preserving per-tool approval subsections.
- **Session diagnostics**: Initialization emits non-secret client/version/protocol/status/error breadcrumbs, and `chau7_mcp_session_info` exposes the successful connection's negotiated protocol plus resolved bridge and socket paths.
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

### Tab Management (14 tools)

| Tool | Description |
| --- | --- |
| `tab_list` | List all tabs across all windows with status, cwd, git branch, CTO state, active app. Primary live discovery API for active AI tabs |
| `tab_create` | Open a new tab with optional directory and target window — respects approval gate and tab limit, and returns exec-acceptance plus prompt-readiness fields |
| `tab_request_control` | Request control of an existing user-opened tab — always requires an explicit Chau7-owned local confirmation before MCP terminal mutations are enabled |
| `tab_release_control` | Revoke MCP control of a tab without closing it and clear any staged MCP input |
| `tab_exec` | Execute a command in a tab — auto-queues when shell/bootstrap state still needs to settle so launchers can submit deterministically without waiting for prompt-ready rendering |
| `tab_status` | Detailed live tab status including authorization-aware exec/prompt readiness; user tabs expose `mcp_control_required` and terminal-only readiness until control is granted |
| `tab_wait_ready` | Wait until `tab_exec` will be accepted (`can_accept_exec=true`); fail immediately with `mcp_control_required` for unauthorized user tabs, otherwise return the last status snapshot on success or timeout |
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
- **TUI-owned arrow navigation** — Chau7's shell-history layer intercepts Up/Down only when the plain shell owns input; known terminal UIs and alternate-screen applications receive their arrow keys even if an OSC 133 prompt marker is stale.
- **Generic TUI scroll policy** — a pure Chau7Core policy routes scrolls to normal scrollback, mouse-aware TUI apps, or transcript history based on runtime terminal state.
- **Per-tab transcript capture** — each terminal session keeps a bounded chunked PTY transcript ring with command-boundary backfill so late AI detection can still seed accurate session logs. Capacity eviction drops old chunks instead of rebuilding the full retained transcript, keeping long-running background output off the main-thread copy path.
- **TUI transcript overlay** — alternate-screen TUIs without normal scrollback can show recent transcript history on scroll-up, while mouse-reporting TUIs keep receiving wheel events.
- **Fixed-delay startup reveal** — Chau7 reveals restored windows after a short splash delay instead of waiting for the full restore queue to drain, matching the lighter release-era startup contract. Each hidden-to-visible reveal, including a restored window's first presentation, recreates the native toolbar host so an off-screen SwiftUI tab bar cannot remain uncomposited until resize or fullscreen.
- **Stabilized tab restore path** — restored scrollback replays through the shell again, with restore-artifact filtering preserved, to avoid post-relaunch history corruption while keeping fast visible startup.
- **Corruption-tolerant persisted lookups** — dictionary builds over persisted keys (pane states, tab IDs, repo roots, shortcut actions) use first-wins uniquing, so duplicate keys in stored data degrade gracefully instead of crashing restore or settings.
- **Restore-time tab identity dedup** — every saved tab restores exactly once across all windows (first occurrence wins, within and across window snapshots), so duplicated-window snapshots from past incidents converge back to a single copy instead of cascading across restarts.
- **Change-aware quit snapshot** — quitting reuses the cached autosave snapshot only when a structural fingerprint of the live windows still matches; any tab/pane/title/directory/AI-session change since the last autosave forces a fresh capture, so the last seconds of work always survive a quit.
- **Freshest-wins restore arbitration** — every save stamps a shared token on the restore bundle and the UserDefaults index; at launch the source whose token reflects the latest save wins, so a bundle whose writes silently failed can never resurrect a stale session over fresher index data.
- **Crash-safe bundle swap** — the restore bundle directory is replaced with safe-save semantics (old bundle stays until the new one takes over), and manifest/sidecar corruption is logged instead of silently degrading restore to a weaker source.
- **Crash-consistent restore publication** — autosave commits the full bundle before publishing the stripped index and writes the index token last. The bundle records the prior index token so an interrupted publication recovers the one-transaction-newer full bundle while unrelated token mismatches still choose the fresher index.
- **Palette-before-replay terminal restore** — terminal startup installs the selected 16-color palette in the Rust renderer before persisted ANSI scrollback enters the VTE parser, preventing restored named colors from being materialized and later re-saved as grayscale.
- Full ANSI/VT100 with 16-color, 256-color, and 24-bit true color support.
- Emoji-aware glyph coloring renders real emoji, including achromatic FE0F symbols, with embedded color while keeping terminal UI symbols and box drawing tintable by ANSI foreground color in Metal.
- Low-contrast glyph rescue keeps visible text readable when a TUI resolves foreground and background colors too close together, while hidden text and wide-cell continuations still render as background-only cells.
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

- **Bounded scrollback cache I/O** — per-tab ordering is preserved through one shared serial operation lane, so simultaneous demotions cannot multiply full-buffer capture/compression peaks. Atomic verified writes classify capacity, permission, corruption, and generic I/O failures, and a failed cache never permits ring shrinkage.

Chau7's rendering pipeline is purpose-built for latency-sensitive terminal work:

- GPU in-flight gating: shared Metal buffers and the glyph atlas are never rewritten while a committed frame is still reading them, and GPU-failed frames force a full-refresh redraw instead of stranding the view on stale content.
- Slot-clipped glyph rasterization: overhanging glyphs (combining marks, italic overhang, ligature swashes, emoji fallbacks) cannot paint into neighboring atlas slots and corrupt cached glyphs.
- Display-scale awareness: moving a window between Retina and non-Retina displays reconfigures the glyph atlas at the new backing scale and redraws immediately.
- Occlusion-aware rendering: fully covered windows stop live grid syncs and GPU presents (1Hz background drain), with an immediate refresh on re-expose.
- Wired memory reclamation: tab snapshots, scrollback-line duplicates, and search buffers clear on tab close, on `.hidden` demotion, and under OS memory pressure; orphaned scrollback cache files are swept at startup.
- Window-level GPU volatility: under critical pressure the glyph atlas and Metal buffers of fully invisible windows become OS-reclaimable, with reclaim-safe rebuild (including the static vertex quad) on the window's next draw.
- Self-imposed footprint ceiling: the app polls its own memory footprint against a quarter-of-RAM ceiling (clamped 4-12GB) and proactively flushes non-selected tabs' scrollback before the OS pressure signal would ever arrive.
- Bounded auxiliary caches: clipboard history items cap at 100KB each, session-resolver caches cap at 256 entries, closed AI-monitor sessions evict after a grace period, and aborted graphics sequences release their buffer capacity.
- Proactive scrollback reclamation: idle warm tabs flush their ring to disk and shrink to the viewport floor, agent TUI tabs compact without ever being replayed into while live, and an aggregate scrollback budget flushes the largest warm tabs early — while the viewport plus a resident tail always stays in RAM so tab switching paints instantly.
- Checksummed scrollback disk cache: flush payloads carry uncompressed size and CRC32 for exact-size decode and verification, are written atomically, and preserve CRLF/SGR fidelity so restored history keeps its columns and colors.
- Per-tab memory attribution: an on-demand Debug Console Memory tab breaks resident bytes down per pane (Rust ring, session caches, CPU-fallback copies) and per window (atlas, instance and triple buffers), with replay and tab-switch-to-first-paint latency instruments.

| Layer | What It Does |
| --- | --- |
| **Metal GPU rendering** | Hardware-accelerated text via Apple Metal |
| **Direct CAMetalLayer presentation** | Minimal-latency drawable presentation without extra compositing passes |
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
| **Repository stats snapshot cache** | Shared repository models refresh analytics on a dedicated utility queue with a 30-second TTL, coalesce overlapping requests, retain stale values during refresh or failure, and preserve invalidations that race an in-flight query |
| **Database-free tab hover cards** | Hover-card view rendering consumes only in-memory active-run and cached repository snapshots; completed-run and tool-summary SQLite reads run on a utility queue and generation-check publication when the pointer changes tabs |
| **Off-main background terminal snapshots** | Shared background drains extract cursor state, output bytes, shell events, and lifecycle facts under the terminal poll lock on a utility queue; AppKit receives an immutable snapshot, and drain-only tabs skip presentation grids and callbacks |
| **Tier-based graphics memory release** | Background tabs release NSImage snapshot caches and mark Metal textures/buffers volatile on demotion, letting the OS reclaim GPU memory under pressure and rebuilding on promotion |
| **Background window render backpressure** | Only the key window owns live selected-tab presentation; visible selected tabs in main-but-not-key or otherwise non-input-priority windows keep a retained passive surface and drain through the shared background path instead of driving full live Metal sync |
| **Adaptive render-loop throttling** | Active tab drops to ~10 Hz after idle, snaps back instantly on PTY data or user input — cuts wakeups and CPU on idle AI sessions |
| **Configurable active-tab refresh cap** | Display Native / 60 Hz / 30 Hz picker lets users trade scroll fluidity for battery; default follows the screen's native refresh |
| **LRU-backed syntax-highlight cache** | Terminal-output highlighter uses `NSCache` (bounded LRU with cost-based eviction and an OS-pressure hook) instead of a dictionary with order-unspecified prefix eviction, so hot lines stay cached on busy streams |

## Tabs, Panes & Windows

- **Render-pass-safe tab-bar geometry** — SwiftUI preference updates are coalesced onto the next main-loop turn before changing hit-test or recovery state, so multi-window restoration avoids undefined render-pass mutation. The toolbar item's own allocation still comes from `minSize`/`maxSize`: they are deprecated with no replacement that works for custom views, and constraints govern only the hosting view's internal layout, so dropping them collapses the item to 0x0 on every toolbar recreation even though `intrinsicContentSize` stays correct.

### Tabs

- Unlimited tabs per window — `Cmd+T` to create, and a configurable switch-to-tab shortcut mode (`Cmd+1–9`, `F1–F12`, or both) to jump (Settings → Tabs).
- Tab renaming (`Cmd+Option+R`), 12+ colors, reordering via drag or shortcuts with center-crossing snap thresholds.
- Repository-group drags move one layer-backed AppKit snapshot at the display's native cadence over an invisible stable SwiftUI placeholder; previews, edge autoscroll, and final reorders share the complete label-plus-tabs geometry, with attached-view coverage for transaction handoff and teardown.
- Repository-group dragging autoscrolls an overflowing tab bar while the pointer remains near either horizontal edge, allowing groups to reach the true beginning or end while preserving pointer alignment and destination-slot accuracy.
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
- Terminal splits share one focused-pane interaction policy across SwiftUI construction and imperative refreshes: only the focused leaf owns keyboard input and the window-level Metal renderer, while visible siblings retain their lifecycle and render through an immediately refreshed CPU fallback. Native AppKit first-responder changes are the authoritative focus signal, and delayed SwiftUI updates must revalidate renderer claims against the split controller's live focused-pane ID.
- Headerless terminal panes expose the shared accessible pane-close control whenever the tree has a sibling, while `Ctrl+Cmd+W`, focus navigation, and menu validation use the same all-pane capability regardless of whether the sibling is a terminal, editor, preview, diff, repository, or dashboard. Split/close logs include tab, pane, direction, before/after count, and resulting focus.
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
- Closing a window closes it for real — its shells are gracefully torn down (like closing a tab) and its host is removed from `overlayHosts`, so a closed window is no longer re-persisted or restored on the next launch. No privileged "main" window: any window is fully closeable, closing the last one clears persisted window state, and the status-bar summon opens a fresh window when none remain.
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
- Missing bare filenames are searched asynchronously within the enclosing repository and open only when exactly one match exists; ambiguous and missing results show feedback instead of guessing. Generated/dependency trees (`.git`, `.build`, `node_modules`) are excluded.
- URL click targets discard surplus trailing `)` sentence punctuation while preserving balanced parentheses that belong to the URL.
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
- The palette mirrors the main menu command surface, including Open Location, Data Explorer, pane tools, diagnostics, release notes, acknowledgments, tab recovery, and issue reporting with current shortcuts.

### Notifications

- Native macOS desktop notifications for task completion, failures, permissions.
- Notification subtitles show repo, tab, or directory context so concurrent agent sessions are easier to distinguish.
- Dock badge and bounce (critical/non-critical).
- Configurable sounds (Glass, Purr, etc.) with volume control.
- Command idle detection with configurable threshold. Fires once per session, resets only on real user activity.
- Auto tab styling on events. Outcome highlights (green completion/readiness and red failure) stay until you open the tab instead of auto-clearing after a timeout — opening a tab clears its non-persistent highlight, while permission highlights persist until the prompt is resolved. User-configured timeout actions remain supported. Deduplicates redundant re-applies, clears persistent approval styling as soon as the approval is resolved, and can highlight every affected tab for file conflicts. The live-tab lookup, deferred-retry scheduler, optional auto-clear timer, and redundant-re-apply suppression all live on a dedicated `StyleTabCoordinator` so the path is unit-testable in isolation.
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

- Comprehensive settings UI with fuzzy search coverage for every routed settings pane, including app/window chrome, display rendering, tabs, performance, keyboard, AI detection, Agent Control, Context Optimization, AI Context, API Tracking, History, Diagnostics, Command Safety, repository metadata, hover card, and About support/diagnostics surfaces.
- Settings profiles — save, load, export, import named configurations, and auto-switch the live runtime profile by directory/glob, repository name, SSH host, process name, or environment variable.
- Per-folder config: `.chau7/config.toml` in any repo for project-specific settings.
- Config file watcher — auto-reload on changes, no restart needed.
- Launch at Login installs/removes the user LaunchAgent plist for the next macOS login without loading it in the current session, so toggling the setting does not relaunch Chau7 immediately.
- Responsive settings shell opens on a Start Here dashboard for launch/profile/Agent Control/Remote Access/Alerts/permission/path health, organizes panes into goal-oriented groups (General, Appearance, Terminal, AI Workflows, Automation, and Safety & Privacy), keeps General focused on startup/language/default-directory basics with config files under Advanced, keeps Sync & Backup focused on export/import, iCloud sync, and recovery reset with profile automation under Advanced, moves Debug Console into Diagnostics, and keeps the sidebar, actionable search results, section copy, and form controls usable while resizing, with every page starting on a compact shared status strip for enabled/disabled state, health, active values, counts, paths, and warnings; search matches scroll to and highlight stable row/section anchors, adaptive rows wrap text for longer localized labels and accessibility descriptions, a compact native titlebar profile selector defaults to "Default Settings" and owns profile load/save actions, tighter shared golden-ratio SwiftUI style tokens, small-control row defaults, shared nested indentation, reusable status summaries with top-left aligned grid cells for consistent icon gutters/text starts, aligned action rows/empty states/list rows across pages, and Advanced disclosures for protocol internals, raw diagnostic paths, proxy details, Agent Control limits, and runtime/debug surfaces.
- Overloaded settings panes are split by task: Remote Access and SSH Profiles are separate Automation entries, History and Diagnostics are separate Safety & Privacy entries, Alerts keeps the existing tabbed alert-rule editor, and Context Optimization keeps runtime/debug detail under Advanced.
- Appearance settings are organized by visible surface: Windows owns app theme, opacity, floating/fullscreen/overlay behavior, and split panes; Tabs and Hover Card split their controls into task-focused sections; Font & Colors stays focused on terminal text and palettes; Display stays focused on output readability and interactivity.
- Windows settings are a first-class Appearance pane for menu bar only mode, floating-window mode, overlay/fullscreen behavior, and split-pane defaults instead of being mixed into Display.
- Optional iCloud sync across devices — freshness-guarded: only blobs strictly newer than this Mac's last synced state apply, newer-format exports are refused, fields absent from a blob keep their local value instead of resetting to defaults, Sync Now performs an immediate push, sync/restore/import/export actions report visible status in the pane, and destructive restore/import/reset paths require confirmation with a backup-first escape hatch.
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

- **Display-paced iPhone terminal rendering** — a serial actor ingests PTY bytes and extracts Rust grids off-main, while a one-shot 60/120 Hz display link publishes only the newest immutable frame; overloaded ordered output fast-forwards safely to a checkpoint and correlated metrics identify sender, queue, decode, and publication latency.
- **Media-style terminal transport** — PTY bytes use a 4 ms binary micro-batch, snapshots act as keyframes for initial state and recovery, authenticated timing metadata measures sender/network latency, and a side-effect-free checkpoint request resynchronizes overloaded clients.
- **Loss-aware relay backpressure** — relay soft pressure drops only replaceable terminal grids while preserving ordered output and control frames; the hard pressure limit closes the connection instead of allowing an unrecoverably incomplete encrypted stream.
- **Responsive iPhone streaming pipeline** — socket receive and ordered frame application are decoupled, replaceable grids coalesce without breaking encrypted sequence order, visible text refreshes run on a bounded cadence, hidden renderer work is skipped, and rolling metrics expose where receive-to-publish latency accumulates.
- **Negotiated terminal representations** — iPhone clients select plain text, styled replay, or full-grid streaming; current clients receive one representation while older clients retain the compatible dual stream, and grid capture is coalesced to a latest-wins 15 FPS cadence.
- **Classified helper diagnostics** — remote-helper stderr is sanitized and classified by message semantics: routine reconnect lifecycle is informational, the known disabled `MallocStackLogging` notice is suppressed, and unknown output or actual connection failures retain warning severity.
- **Correlated transport status** — the helper reports its live relay WebSocket state independently from local IPC and encrypted phone-session readiness. Remote settings expose all three layers, and transition-only snapshots add tab inventory and stream mode to durable logs so an empty phone tab list can be attributed without reconstructing separate log systems.
- Read-only remote terminal sharing with viewer approval flow.
- Cloudflare Workers relay — no port forwarding required.
- Session recording with timestamps and timeline scrubber.
- Remote activity projection — macOS reduces AI event streams into one authoritative activity state for remote clients.
- iPhone Live Activity / Dynamic Island support via the Chau7 Remote app for running, waiting-input, completed, and failed states.
- Interactive remote prompts — detected Claude and Codex terminal prompts appear in the iPhone Approvals tab with option buttons that reply to the correct tab. Destructive options require a second confirmation before sending.
- iPhone menu key driving — the terminal control key row includes Return and Shift-Tab, auto-surfaces when the active tab has a pending prompt or waiting-input/approval activity, and digit sends answering a pending menu drop their trailing Enter to avoid double-acting on the next screen.
- Structural prompt detection — selection menus are recognized by shape (cursor-glyph-marked option rows at the snapshot tail) rather than only by prompt keywords, so agent-authored questions like AskUserQuestion surface as iPhone prompt cards; arrow-only menus answer with synthesized arrow-navigation responses.
- Menu waiting-status gating — a cursor-marked menu row ("❯ 1.") flips the session to waiting-for-input so keyword-less menus get scanned, and a 1-second recheck while prompt cards are live keeps arrow-navigation responses tracking the on-screen cursor.
- Structured AskUserQuestion prompts — Claude Code hook events carry the exact question and options (PreToolUse tool_input), producing authoritative iPhone prompt cards that bypass status gating, suppress the scraped duplicate, answer with a bare digit, and clear on PostToolUse when answered from any surface.
- Semantic remote key presses — the KEY_INPUT frame (0x24) carries enter/escape/arrows/control combos as named keys resolved by the Mac's terminal key encoder (DECCKM-correct), advertised via a tab-list capability with automatic escape-text fallback against older Macs.
- Remote menu interaction refinements — waiting patterns match ANSI-stripped output, ExitPlanMode plan reviews drive waiting status structurally, multi-select AskUserQuestion cards toggle live with a separate submit (multi_select wire flag), and arrow-navigation prompt responses ride KEY_INPUT when supported.
- Reliable remote input delivery — remote submit Enters use a dedicated non-cancellable work-item pool, submitted phone sends replace the input line (^U first) instead of appending to pending prefills or stale drafts, and unconfirmed resume prefills surface on the iPhone as Run/Clear cards that retire once the line runs, is replaced, or is discarded.
- iPhone control key row layout — one in-flow key row above the input bar (no keyboard-accessory overlay), with an authoritative show/hide button that dismisses auto-surfaced rows per waiting episode.
- Remote sends always submit — Codex submits press the Enter key (raw LF parses as Ctrl-J in current Codex TUIs and never submits), and the iOS Send action always carries the submit terminator (the Append Newline toggle is removed).
- Repo-grouped iPhone tab menu — the tab dropdown sections tabs under their repo name and keeps each section alphabetized with a stable tab-ID tie-breaker, so activity updates cannot reshuffle the open menu; repo-less tabs remain under "Other".
- Truthful and stable iPhone tab inventory — Chau7 Remote distinguishes encrypted-session readiness from tab-inventory readiness, shows syncing until the first live or cached inventory arrives, logs its source and count, and suppresses duplicate or reorder-only observable updates so shell activity cannot rebuild an open picker.
- Single-flight iPhone connection recovery — launch, foreground, push, URL-action, and approval-delivery requests coalesce behind the active transport, only one delayed reconnect owns the next attempt, manual retries remain authoritative, and structured logs attribute each transition without retaining raw network errors.
- Durable iPhone operational diagnostics — sensitive input/keystroke capture has its own 2,000-entry ceiling with amortized batch trimming so it cannot evict most connection history, while a persisted foreground marker records unobserved launch endings without labeling them as confirmed crashes.
- Crash-resilient Mac/helper session replay — when the Chau7 app reconnects to a helper that retained an encrypted iPhone session, the helper replays current session readiness so macOS republishes initial tabs and activity instead of leaving the phone indefinitely syncing.
- iPhone issue reporting — Chau7 Remote can submit a private issue from Settings with a description, environment snapshot, optional remembered contact, an exact Markdown preview, and a share-sheet fallback; its bounded recent-diagnostics excerpt is off by default and carries an explicit keystroke privacy warning.
- Background keepalive mode — when Chau7 Remote backgrounds, the session can briefly stay alive in approvals-only mode instead of streaming full terminal traffic.
- Push-backed remote approvals — the relay and remote helper can register an iPhone push token and wake the Chau7 Remote app when new approvals or interactive prompts appear; relay encryption operates on a frame copy so local APNs decoding always retains the original JSON payload.
- Hardened relay authentication — scoped, single-use HMAC tokens (per device/role/endpoint) carried in the `Authorization` header defeat replay and connection-takeover; the relay fails closed when no secret is configured, rate-limits per device, validates and size-caps every request, and applies WebSocket backpressure. The relay uses Cloudflare Hibernatable WebSockets so idle sessions no longer pin the Durable Object in memory, while a signing-key-scoped token broker prevents paired-device sessions from independently rotating the shared APNs credential.
- iOS 18 minimum target — the Chau7 Remote app and widget extension deploy to iOS 18.0 (`IPHONEOS_DEPLOYMENT_TARGET = 18.0`); the shared SwiftPM package declares an `.iOS(.v17)` floor for library targets.
- Experimental Rust iPhone renderer — Chau7 Remote can render a true terminal grid on iPhone using the shared Rust terminal core, with a text fallback kept available.
- Selected-tab-only streaming — macOS streams terminal output and snapshots only for the tab currently selected on iPhone; background tabs stay metadata/activity/approvals-only until switched to.
- Remote profiling hooks — the iPhone app emits `os_signpost` intervals for frame processing, output append, and ANSI stripping so receive/render lag can be measured in Instruments.

### Isolated Testing

- Isolated test app builder creates a separate `Chau7 Test.app` with its own bundle ID and embedded home root.
- Chau7-owned state is redirected: `UserDefaults`, `~/Library/Application Support`, `~/Library/Logs`, `~/.chau7`, and keychain service names.
- Safe for side-by-side manual testing of Chau7 itself without touching the main app's local storage.

## Scripting & Debugging

- **Test-run log isolation** — XCTest processes route app logs and terminal captures to a process-scoped temporary Library/Logs tree by default, keeping expected fixture warnings out of the user's operational audit history while preserving explicit test-home and log-file overrides.

- **Complete restore phase attribution** — per-tab restore telemetry names setup, lookup, command-block, focus, metadata, resume, repository-grouping, and startup-finalization costs, including completed phases on early returns, so launch stalls can be assigned before changing thread ownership.

- **Privacy-safe network attribution** — provider-status requests log a short correlation ID, component name, normalized host, and outcome while deliberately excluding URL paths, queries, fragments, credentials, and tokens. Redacted TLS diagnostics can therefore be correlated with an app-owned subsystem without expanding diagnostic data exposure.
- **Independent component identity** — the app, bundled proxy, and Cloudflare relay expose distinct build/deployment identities. `chau7_runtime_info` includes the app plus identities actually observed from helper health checks, so rebuild verification cannot accidentally validate the wrong component.
- **Launch-preserving log rotation** — `Chau7.log` retains five bounded archive generations plus a line-aligned active tail. High-frequency read-side terminal traces are omitted in favor of state-change logs, and startup activity records byte counts rather than terminal text, preserving deeper parseable audit history without unbounded storage or transcript leakage.

### Scripting API

- JSON-RPC Unix socket API — control tabs, run commands, query history, manage snippets, modify settings.
- Review automation is built from tab-first scripting primitives such as `create_tab`, `run_command`, `get_tab`, `send_input`, `submit_prompt`, `get_output`, `close_tab`, and `get_repo_events`.
- Repo-local pre-commit review automation via `scripts/pre-commit-review`, which creates a review tab, launches Codex, waits for the app to become interactive, sends the staged-diff prompt, validates and submits it, polls PTY output for the final structured JSON block, and prints findings in hook-friendly terminal output.
- Repo-scoped event retrieval for automation via `get_repo_events`, which returns recent AI events with full stored messages plus filters for tab, type, producer, and session. The pre-commit reviewer now prefers this authoritative stored result path before falling back to terminal transcript scraping.
- Per-repo pre-commit review policy via `.chau7/pre-commit-review.conf` with gate modes (`off`, `advisory`, `high`, `any`), timeout, backend, and model selection. The shipped default reviewer model is `gpt-5.3-codex`.
- Optional verbose tracing for the hook via `--verbose` or `CHAU7_PRE_COMMIT_REVIEW_VERBOSE=1`, including per-step scripting timings and fallback decisions.

### Debugging

- **Semantic event log levels** — Claude session-start hooks are explicitly consumed after adoption, and deliberate non-user-facing/state-only notification adapter drops are trace-only after coalescing. Unsupported or novel ingress failures remain durable info diagnostics.
- **Launch continuity marker** — after acquiring the single-instance lock, Chau7 records build and start time beside a running marker and clears it on normal AppKit termination. The next launch reports clean, abrupt, or unknown continuity without mislabeling force-quit or power loss as a confirmed crash.
- Debug console (`Cmd+Option+L`) — scoped sidebar surfaces for Diagnostics, Runtime Inspector, Usage Monitor, and the full console, covering Health, Logs, Perf, Lag, State, Events, Report, Usage, Analytics, Repos, and Token Optimizer, with direct menu/palette/settings entry points, privacy-first issue reporting, aligned performance/usage analytics tables, and surface/tab routing kept in a dedicated model file.
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

- File watches are owner-scoped: closing a text-editor pane cancels its watch and pending autosave work even when the model remains retained, invalidates late load completions, and app/history-monitor teardown explicitly stops owned tailers and timers.
- Missing-file recovery uses bounded exponential retries during likely atomic replacement, then becomes event-driven by watching the nearest existing parent. Canonically identical paths share one underlying filesystem source; parent events get an immediate target check plus one bounded delayed handoff for rapidly assembled nested directories, and repeated monitor lifecycle changes release every subscription without permanent polling.
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

The Window menu disables unavailable tab and pane actions, lists tabs from the active Chau7 window, and exposes Diagnostics, Usage Monitor, Runtime Inspector, and Debug Console as scoped diagnostics entry points.

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

Shipped menu shortcuts stay on the macOS menu/responder-chain path before custom overlay keybindings run, so default actions receive exactly one dispatch while non-default custom keybindings still work.

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

- Cloudflare Worker toolchains are pinned to audit-clean compatible Wrangler and Workers-types releases; both services must pass dependency audit and dry-run build validation.
- Process-resource monitor lifecycle tests inject deterministic snapshots, isolating timer start/stop behavior from OS process-enumeration latency under full-suite load.
- Swift formatting/lint and Go static analysis run across the complete source and test trees; test fixture guards terminate explicitly before optional values are dereferenced.
- Quality-runner tests isolate process-wide environment overrides, preserving fail-closed dirty-worktree coverage even when the parent pre-push invocation explicitly acknowledges local changes.

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
- **MCP tool coverage gate** — a `staged-feature-coverage` gate (`scripts/check-feature-coverage.mjs`) hard-fails when a tool registered in `MCPSession.swift` has no canonical `MCP Tools —` inventory row, forcing new tools to be documented; it warns (not fails) on removed tools and has a deliberate `CHAU7_SKIP_FEATURE_COVERAGE=1` escape hatch.
- **MAGI orchestration regression coverage** — fake-MCP and CLI-runtime tests pin pending-member collection, echoed-marker repair avoidance, engineering decision identity grouping, final-vote veto propagation, evidence policy states, collector failure cleanup, stale artifact replay/share fallback, and provider command construction.

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

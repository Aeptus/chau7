# Parity inventory

What "full parity on macOS" means for Chau7 Next, feature by feature. One file
per Swift module (format: [FORMAT.md](FORMAT.md)). The original April baseline
has 1,175 rows; current-source delta rows are appended without renumbering. The
summary with counts per module is generated into
[`../PARITY.md`](../PARITY.md).

The goal is full parity on macOS first. Linux and Windows only need to keep
building and passing CI until then (see "Platform traits" in `AGENTS.md`).

## How agents use it

1. Pick rows: `apps/chau7-next/scripts/parity.py --todo <Module>` lists the
   rows that are not done. Take rows from the current wave, fix-first items
   first.
2. Re-check each row against the Swift source before porting it. An
   independent check of 40 sampled rows found 4 wrong (about 10%), so treat a
   row as a strong lead, not as a spec. Fix the row if it is wrong.
3. Port the feature, with the Swift tests that cover it (the Tests column).
4. In the same PR: set the row to `done` (or `partial` with what is missing),
   fill the Rust column, run `scripts/parity.py --write`.
5. A row with a value in the macOS API column goes behind a platform trait.

Never renumber IDs. New features found later get the next free number.

## ID prefixes

| Module | Prefix | Module | Prefix | Module | Prefix |
|---|---|---|---|---|---|
| AI | AIX | Keyboard | KBD | Rendering | RND |
| Analytics | ANL | Localization | L10 | Repository | REP |
| App | APP | Logging | LOG | Runtime | RUN |
| Appearance | APR | MCP | MCP | RustBackend | RBK |
| Chau7Core | COR | Migration | MIG | Scripting | SCR |
| Commands | CMD | Monitoring | MON | Settings | SET |
| DataExplorer | DEX | Notifications | NOT | Snippets | SNP |
| Debug | DBG | Overlay | OVL | SplitPanes | SPL |
| Editor | EDT | Performance | PRF | StatusBar | STB |
| Events | EVT | Profiles | PRO | Telemetry | TEL |
| History | HIS | Proxy | PRX | Terminal | TRM |
| | | Remote | RMT | TokenOptimization | TOK |
| | | | | Utilities | UTL |
| Dashboard | DSH | Usage | USG | Skills | SKL |
| CLI | CLI | Observability | OBS | Views | VWS |

## Waves

Modules in the same wave are independent and can be ported in parallel.
`Chau7Core` rows follow the wave of the module that uses them.

| Wave | Theme | Modules |
|---|---|---|
| 1 | Daily terminal use | RustBackend, Rendering, Performance, Terminal, Keyboard, Appearance, Settings, Overlay, SplitPanes (terminal splits), Snippets, Commands, Profiles, App, Utilities |
| 2 | AI CLI features | AI, Notifications, History, Monitoring, Repository, Events |
| 3 | Services | MCP, Runtime, Scripting, Remote, Proxy, TokenOptimization, Telemetry, Analytics |
| 4 | Extra panes | Editor, DataExplorer, SplitPanes (editor, diff, preview, runbook panes) |
| 5 | macOS integration and shipping | StatusBar, Debug, Logging, Views, Localization, Migration; Developer ID signing, notarization, updates |

## Current baseline and regression priorities

Compare official main `7733b1f0c4440c0193915b036c38d5b83f31a1b3` with Next
`3e1639a85fe9bb7a4cc9873996b8fade14525ac4`, then verify each integrated batch.
The historical fix-first list is removed: source inspection confirms Cmd+C
interrupt fallback, background PTY writer, Option punctuation routing, split
shortcut mapping, last-tab dialog, quit confirmation, Ctrl+Tab and startup
command are implemented now (`terminal/input.rs`, `terminal/pty_writer.rs`,
`actions/keymap.rs`, `workspace/mod.rs`, `app_actions.rs`,
`terminal/session.rs`). These remain regression checks, not open rows.

Current gaps have explicit delta rows. No `missing` or `partial` row may be
silently excluded from a full-parity claim. In particular:

- OVL-043 / OVL-120: repository seeding and regrouping were fixed in e78f2790 and remain regression checks. Default remains Off as in Swift.
- PRF-002: On frozen source `68294293`, scoped native Software/Auto unavailable-device and localized Settings acceptance pass, as do the signed feature-free normal-package MCP/performance/quit flow and isolated synthetic-run persistence. The inventory row is done for this scope; full quality/CI on the final docs-only head and the separate Mac hand-test checklist are tracked separately. See the Performance inventory, package evidence and current recovery record.
- MCP-053 to MCP-063 / OBS-001 to OBS-005: current MCP observation, control
  ownership, readiness and repository event contracts.
- PRF-014 to PRF-018 / DBG-026: durable performance and memory diagnostics,
  hang detection and recovery, scrollback budget behaviour.
- SPL-016 / SPL-017: shell fence filtering and completion-driven sequencing were ported in b23ce32b and remain regression checks.

New modules: Dashboard (DSH), Usage (USG), Skills (SKL), CLI (CLI),
Observability (OBS). These are current Swift surfaces, separate from the
existing Analytics, Telemetry, MCP and Notifications equivalents.

## Coexistence rules for wave 3

Found while inventorying; each must hold when the module is ported (see
`../DUAL-SHIP.md`).

- Remote (RMT): the Go agent keeps its state in `CHAU7_REMOTE_STATE`, default
  `~/.chau7/remote/state.json`, and (since the Aeptus rebase) its relay
  credentials in `CHAU7_REMOTE_CREDENTIALS`, default beside the state file.
  Chau7 Next must always set both to paths in its own data root, or both apps
  share pairing state, keys and relay credentials. It also passes
  `CHAU7_PARENT_PID` so the agent exits with it.
- Proxy (PRX): Swift defaults to ports 18080 (HTTP) and 18081 (TLS). Chau7 Next
  needs its own defaults so both proxies can run at once. The proxy reads its
  global prompt injection rules from `CHAU7_INJECTION_RULES` (default: the
  Swift app's `~/.chau7/prompt-rules.json`) and watches `CHAU7_PARENT_PID`:
  Chau7 Next passes both. `~/.chau7/pricing.json` is read only, by both.
- TokenOptimization (TOK): `chau7-optim` strips `$HOME/.chau7/cto_bin` and every
  folder in `CHAU7_CTO_BIN_DIR` from `PATH`; Chau7 Next's wrappers pass their
  own folder there. The Swift wrappers also check `CHAU7_CTO_OPTIM_ACTIVE`
  (set by `chau7-optim` for its children); porting that check is part of the
  TOK delta.
- Shells (TRM): a Chau7 Next started from a Chau7 tab inherits what the Swift
  shell wrappers export: `HISTFILE` in `~/.chau7/history/`, the Codex proxy
  wrapper folder on `PATH`, `BASH_ENV` and fish `XDG_CONFIG_HOME` in the Swift
  temporary shell folder, `X-Chau7-*` lines in `ANTHROPIC_CUSTOM_HEADERS` and a
  local proxy `OPENAI_BASE_URL`. `shell_env::inherited_cleanup` drops or
  restores each of them at startup.

## Historical Swift reachability notes

This table describes the April Swift reachability audit. It must not be read
as a claim about current Swift callers. The earlier decision to port designed
features remains recorded, but re-check current sources before changing a row.
Current Next implementations are already present for many of these features.
The verified current TUI prompt-injection TODO is recorded separately in REP-018.

| Rows | Feature |
|---|---|
| AIX-015 | "Explain This Error" (the LLM settings page, AIX-012, does run) |
| CMD-034 | Confirmation dialog before running a dangerous command (highlighting does run) |
| HIS-015, ANL-001 to ANL-007 | Session recorder and timeline scrubber, terminal analytics dashboard |
| MIG-003 to MIG-006 | Terminal.app and iTerm2 import wizard |
| SCR-001 to SCR-015 | Scripting socket server (whole module) |
| RMT-027, RMT-028 | Remote viewer mode |
| EDT-004 to EDT-012 | IDE-style editor (its settings tab runs, but nothing reads the values) |
| PRO-004, PRO-005 | Profile auto-switch rules on SSH host and environment variables |
| APR-008, APR-009, KBD-016 | Minimal mode, high contrast, Kitty keyboard protocol |
| PRF-002 | April 2026 historical claim, superseded by the current-source evidence above: "Metal Renderer" on/off setting (GPUI always renders on the GPU) |

## Audit evidence

The pinned source manifest is [`audit/current-swift-sources.tsv`](audit/current-swift-sources.tsv).
It indexes every current Swift source file and direct row citations; absence of
a direct citation flags module-level review, not feature completion. Cohesive
implementation batches, source mappings, Next seams and validation are in
[`../REBASE-ON-AEPTUS.md`](../REBASE-ON-AEPTUS.md#6-current-source-inventory-audit-2026-10-11).

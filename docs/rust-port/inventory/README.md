# Parity inventory

What "full parity on macOS" means for Chau7 Next, feature by feature. One file
per Swift module (format: [FORMAT.md](FORMAT.md)), 1,175 rows in total. The
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
| | | | | Views | VWS |

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

## Fix first

Differences between what Chau7 Next already ships and the Swift app, checked
against both sources. These come before new features.

| Row | Issue |
|---|---|
| KBD-035, RBK-021 | Cmd+C with no selection should send Ctrl-C (interrupt); Chau7 Next does nothing |
| RBK-052 | Typed and pasted input is written to the PTY on the UI thread; a program that stops reading input freezes the window. Swift writes on a background queue |
| KBD-013 | Option key: Swift sends ESC+key for Option+letter and types the character for Option+printable non-letter, with no setting. Chau7 Next's `option_as_meta` is all or nothing and off by default |
| Keyboard.md notes | Custom `[keybindings]`: `splitHorizontal` and `splitVertical` are swapped in `action_for_swift_name` (Swift: horizontal = side by side) |
| App.md notes | Default shortcuts differ: Swift Cmd+Shift+D = Data Explorer, Cmd+Shift+S = Export Text, Cmd+Opt+W = Close Other Tabs, Cmd+K = Clear Screen (Ctrl+L), Ctrl+Cmd+W = Close Pane. Chau7 Next binds Split Down, Snippets, Close Pane and Clear Scrollback |
| OVL-083, SET-044 | Closing the last tab: Swift asks "Close Window / New Tab"; Chau7 Next closes the window |
| APP-006 | Cmd+Q: Swift asks when processes are running; Chau7 Next quits |
| APP-075 | Ctrl+Tab and Ctrl+Shift+Tab are not bound on macOS |
| SET-062 | Startup command is parsed but never run |

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

## Never-run Swift features (all to be ported)

These Swift features exist in the code but never run in the Swift app today (no
caller or no way to open them), checked by an independent pass. Decision
(user, 2026-10-10): port all of them, none is dropped. Port them as designed
and wire them where the design intends (for example "Explain This Error" on a
failed command), since there is no working Swift behavior to copy.

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
| PRF-002 | "Metal Renderer" on/off setting (GPUI always renders on the GPU) |

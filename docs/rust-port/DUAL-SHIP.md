# Shipping the Swift and Rust apps side by side on macOS

Status (2026-10-23): The legacy SwiftUI/AppKit macOS app (`apps/chau7-macos`) has been removed from
the tree. It remains available in git history and in prior release tags.
`apps/chau7-next` is the macOS app, and the `Release` workflow publishes its
production build (`CHANNEL=production`) from `v*` tags. The shared Rust crates
moved to `crates/`, the Go proxy to `services/chau7-proxy`, and `Chau7Core` to
`apps/chau7-ios/Chau7Core`. Paths to `apps/chau7-macos` below are historical.
The side-by-side plan below is kept as a record of the transition; users who
still have the Swift app installed keep its separate data.

Previous status: phase 1 is implemented. Parity inventory and revision-scoped
evidence are tracked in [`PARITY.md`](PARITY.md).

## 1. Goal

Ship two macOS apps at the same time until the Rust (GPUI) app is complete:

| | Published stable app | Parallel port | Planned production package |
|---|---|---|---|
| Name | Chau7 | Chau7 Next | Chau7 |
| Bundle id | `com.chau7.app` | `com.chau7.next` | `com.chau7.app` |
| UI | SwiftUI + AppKit | GPUI | GPUI |
| Role | current public release | isolated development/preview app | upcoming release, not yet published |
| Writable state | existing Swift paths | isolated Next paths | versioned Rust v1 paths; legacy Swift and Next data remain intact |

Both apps must be installable and running at the same time on one Mac without
breaking each other. The Swift app needs no changes for this; all isolation is
done on the Rust side.

## 2. Why two apps and not one

AppKit and GPUI each own the process's main event loop on macOS. They cannot
share a process, so "both at the same time" means two bundles.

The repo already does a lighter version of this: `Scripts/build-and-run.sh`
builds a dev bundle (`com.chau7.app.dev`) and refuses to build the production
bundle id while Chau7 is running.

## 3. Shared state inventory

Found by reading the Swift sources. Each line says what the Rust app does in
phase 1 (side by side, isolated).

Where the table says "own copy", the path lives in
`apps/chau7-next/crates/chau7_next_core/src/data_root.rs`. The MCP server
binds its own socket and registers its own `chau7-next` entry; remote control
and the API analytics proxy use their own sockets, state and (for the proxy)
ports 18090 / 18091 and certificate trust entry.

| Resource | Used by the Swift app for | Rust app, phase 1 |
|---|---|---|
| `~/.chau7/config.toml` | Settings | Own copy in its data root; one-time import on first launch |
| `~/.chau7/snippets.json`, `~/.chau7/snippets/` | Snippets | Own copy; one-time import |
| `~/.chau7/mcp.sock` | MCP server socket | Own socket in its data root |
| `~/.chau7/bin/` (`chau7-mcp-bridge`, `chau7-optim`), `~/.chau7/cto_bin/`, `~/.chau7/cto_active/` | Bridge and token optimisation binaries | Own `bin/` in its data root |
| `~/.chau7/claude-events.jsonl`, `~/.ai-events.log` | Reads AI CLI events | Read only; never truncate or rotate |
| `<repo>/.chau7/metadata.json`, `<repo>/.chau7/snippets/`, `<repo>/.chau7/snippets.json` | Repository metadata and repo snippets (Swift migrates the old single file) | Read only; edits are kept in its own data root (`repo-overlays/<repo key>/`) and merged over the repo's files on read |
| MCP registration in `~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`, `~/.codeium/windsurf/mcp_config.json` (`MCPServerManager`) | Registers an MCP server named `chau7` | Registers a separate server named `chau7-next`; never touches the `chau7` entry |
| `~/Library/Application Support/Chau7/` (`remote.sock`, `proxy.sock`, `chau7-remote`) | Remote control and proxy IPC | `~/Library/Application Support/Chau7 Next/` |
| Keychain items `com.chau7.llm.<provider>.apikey` | LLM API keys | Prefixed `com.chau7.next.` (same idea as `RuntimeIsolation.keychainServiceName`); offer import with user consent |
| UserDefaults (`com.chau7.savedTabState`, etc.) | Tab restore | Separate automatically: different bundle id means a different defaults domain |
| LaunchAgent label `com.chau7` | Launch at login | Label `com.chau7.next` |
| Shell integration (`ZDOTDIR` path in `TerminalSessionModel`) | Shell hooks | Own path in its data root |
| Remote pairing with the iOS app | Pairing code per host | Paired separately; host shows as "Chau7 Next" so the iOS app can tell them apart |
| `~/.chau7/remote/credentials.json` (`CHAU7_REMOTE_CREDENTIALS`, relay credentials provisioned with `chau7-remote provision`) | Relay admission | Own `~/.chau7-next/remote/credentials.json`, always passed explicitly to the agent |
| `~/.chau7/prompt-rules.json` (`CHAU7_INJECTION_RULES`, proxy default) | Proxy prompt injection rules | Own `~/.chau7-next/prompt-rules.json`, passed to its proxy |
| `~/.chau7/history/<tab>.{zsh,bash}_history` (`HISTFILE` exported by the shell wrappers) | Per-tab shell history | Not used; an inherited `HISTFILE` pointing there is dropped at startup |
| `$TMPDIR/smartoverlay/` (`ZDOTDIR`, `BASH_ENV`, fish `XDG_CONFIG_HOME`, Codex proxy wrapper in `bin/` put on `PATH`) | Shell integration and Codex proxy routing | Own shell folder in its data root; inherited values restored or dropped at startup |
| `~/.chau7/usage/`, `~/.chau7/sessions/`, `~/.chau7/cto_state.json`, `~/.chau7/bin/chau7-claude-hook`, `chau7-claude-statusline`, `chau7-codex-notify` and their entries in `~/.claude/settings.json` and `~/.codex/config.toml` | Usage tracking, plans, Claude Code hooks and status line, Codex notify hook | Not touched. The hooks are global, so they also run for AI CLIs started in Chau7 Next tabs and write to the Swift app's files: that is the Swift app's doing, not Chau7 Next's |
| Skill installs (`.chau7-skill.json` markers, `.chau7-backups`, `~/.chau7/backups/skills`) | Installing skills into `~/.claude/skills`, `~/.codex/skills` | Not ported yet; must use its own markers and backups when it is |

`~/.codex/`, `~/.ssh/config`, iTerm2 and Terminal preference files are only read
by the Swift app and can be read by both.

## 4. How the Rust app enforces this

1. One `DataRoot` type in the Rust core owns every path above. It mirrors
   `RuntimeIsolation` (home root override, Application Support, keychain prefix)
   and defaults to the "Chau7 Next" locations.
2. No other module builds a path by hand. A CI test greps the Rust sources and
   fails on `.chau7/`, `Application Support/Chau7/` (without " Next"),
   `com.chau7.` (without `.next`), `mcp.sock`, `remote.sock`, `proxy.sock`,
   `credentials.json`, `smartoverlay`, the Swift skill markers and the Swift
   AI CLI hook helper names outside `DataRoot`.
3. A second CI test starts the Rust app's services with a temporary home root and
   asserts nothing is created outside it.
4. First-launch import is copy-only and never writes back to the Swift app's files.

## 5. Phases

| Phase | What ships | Exit criteria |
|---|---|---|
| 0. Spike | Nothing; tab bar spike only | Spike verdict Go |
| 1. Side by side | Chau7 (default) and Chau7 Next (beta), fully isolated as in section 3 | Both run together for a week of daily use with no interference |
| 2. Parity | Chau7 Next gains features module by module | Every row of the parity table (section 6) is done |
| 3. Migration | The production Rust build uses a versioned Rust-owned state root and copies supported data from the Swift app without modifying the source. The isolated Next profile remains separate. | Exact-source migration checks pass on a copy; originals are verified unchanged |
| 4. Swap | The Rust app is released as "Chau7" with the production bundle identity | Release-candidate, signing, migration, and manual acceptance gates pass before distribution changes |

Migration remains a release gate: test the one-time copy on a disposable profile
and verify the Swift source and isolated Next profile are unchanged. The production
Rust v1 root remains separate from both.

## 6. Parity tracking

`docs/rust-port/PARITY.md`, one row per Swift module in
`apps/chau7-macos/Sources/Chau7/` (Settings, Overlay, Terminal, RustBackend,
SplitPanes, MCP, Remote, Proxy, Notifications, Snippets, StatusBar, History,
Profiles, Keyboard, TokenOptimization, Monitoring, Editor, DataExplorer, and the
rest), plus `Chau7Core`. Columns: status, owner agent, Rust location, tests
ported, manual check done. Agents update it in the same PR as the code.

## 7. Production cutover (phase 4)

The planned production Rust package uses the production Cargo feature, bundle id
`com.chau7.app`, and display name `Chau7`. It writes to versioned Rust-owned
state roots (`~/.chau7/rust-v1` and
`~/Library/Application Support/Chau7/RustV1`). The existing Swift data and
the isolated `com.chau7.next` profile remain intact; migration copies supported
Swift data into the Rust v1 root without repurposing either source.

This package has not been published. Keep the current stable release workflow,
Homebrew cask, and website download link on the existing Swift release until the
exact-source release candidate passes packaging, migration, CI, and manual
acceptance. The [production release guide](PRODUCTION-RELEASE.md) owns the
release sequence and detailed migration behavior.

## 8. Testing with a Mac only

- macOS: both apps tested by hand side by side, plus CI on `macos-latest`.
- Linux and Windows: CI only (`ubuntu-latest`, `windows-latest`) running the same
  build and headless GPUI interaction tests as the spike. No human testing on
  those platforms until someone has a machine or VM for it.
- The isolation tests in section 4 run on all three platforms.

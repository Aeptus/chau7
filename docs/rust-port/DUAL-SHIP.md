# Shipping the Swift and Rust apps side by side on macOS

Status: phase 1 implemented (`apps/chau7-next`). Parity is tracked in
[`PARITY.md`](PARITY.md).

## 1. Goal

Ship two macOS apps at the same time until the Rust (GPUI) app is complete:

| | Current app | Rust app |
|---|---|---|
| Name | Chau7 | Chau7 Next |
| Bundle id | `com.chau7.app` | `com.chau7.next` |
| UI | SwiftUI + AppKit | GPUI |
| Role | default, stable | opt-in beta |

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

`~/.codex/`, `~/.ssh/config`, iTerm2 and Terminal preference files are only read
by the Swift app and can be read by both.

## 4. How the Rust app enforces this

1. One `DataRoot` type in the Rust core owns every path above. It mirrors
   `RuntimeIsolation` (home root override, Application Support, keychain prefix)
   and defaults to the "Chau7 Next" locations.
2. No other module builds a path by hand. A CI test greps the Rust sources and
   fails on `.chau7/`, `Application Support/Chau7/` (without " Next"),
   `com.chau7.` (without `.next`), `mcp.sock`, `remote.sock`, `proxy.sock` outside
   `DataRoot`.
3. A second CI test starts the Rust app's services with a temporary home root and
   asserts nothing is created outside it.
4. First-launch import is copy-only and never writes back to the Swift app's files.

## 5. Phases

| Phase | What ships | Exit criteria |
|---|---|---|
| 0. Spike | Nothing; tab bar spike only | Spike verdict Go |
| 1. Side by side | Chau7 (default) and Chau7 Next (beta), fully isolated as in section 3 | Both run together for a week of daily use with no interference |
| 2. Parity | Chau7 Next gains features module by module | Every row of the parity table (section 6) is done |
| 3. Shared data | Chau7 Next switches to the shared `~/.chau7` layout with a versioned schema, and owns `mcp.sock` and the `chau7` MCP entry; Swift app becomes read-only or is retired | Migration tested on a copy of a real `~/.chau7` |
| 4. Swap | The Rust app ships as "Chau7" | See section 7 |

Phase 3 is the risky one: two apps writing the same config is where corruption
happens. Until then, isolation is strict.

## 6. Parity tracking

`docs/rust-port/PARITY.md`, one row per Swift module in
`apps/chau7-macos/Sources/Chau7/` (Settings, Overlay, Terminal, RustBackend,
SplitPanes, MCP, Remote, Proxy, Notifications, Snippets, StatusBar, History,
Profiles, Keyboard, TokenOptimization, Monitoring, Editor, DataExplorer, and the
rest), plus `Chau7Core`. Columns: status, owner agent, Rust location, tests
ported, manual check done. Agents update it in the same PR as the code.

## 7. Swap (phase 4)

macOS ties several things to the bundle id and signing identity, so the final
swap needs care:

- Shipping the Rust app under `com.chau7.app` keeps the user's UserDefaults domain
  and any permissions granted to that bundle id, as long as it is signed with the
  same team identity.
- The app currently requests notification authorization; check that it carries
  over after the swap on a test machine.
- `com.chau7.next` users get a one-time migration of their data root into the
  shared layout, then the Next bundle is retired.

## 8. Testing with a Mac only

- macOS: both apps tested by hand side by side, plus CI on `macos-latest`.
- Linux and Windows: CI only (`ubuntu-latest`, `windows-latest`) running the same
  build and headless GPUI interaction tests as the spike. No human testing on
  those platforms until someone has a machine or VM for it.
- The isolation tests in section 4 run on all three platforms.

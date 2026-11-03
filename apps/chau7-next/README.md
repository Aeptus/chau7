# Chau7 Next

Picking this up? Start with [`docs/rust-port/HANDOFF.md`](../../docs/rust-port/HANDOFF.md).

Chau7 for macOS, built with Rust and GPUI. The former SwiftUI/AppKit app has
been removed from the repository; it remains in git history and prior release
tags.

Two channels build from this directory:

- **Next** (default for local and CI builds): "Chau7 Next.app", bundle id
  `com.chau7.next`, its own data folders, so it runs next to an installed
  production app.
- **Production** (`CHANNEL=production`): "Chau7.app", bundle id `com.chau7.app`,
  versioned Rust data under the stable folders. The `Release` workflow publishes
  this build from `v*` tags.

See the [production release guide](../../docs/rust-port/PRODUCTION-RELEASE.md)
and [parity status](../../docs/rust-port/PARITY.md).

## Install on macOS

### From CI (no toolchain needed)

1. Open the latest **Chau7 Next** workflow run on this branch (GitHub, Actions tab).
2. Download the `Chau7-Next-macOS-arm64` artifact and unzip it.
3. The build is ad-hoc signed, not notarized, so macOS quarantines it. Either
   right-click the app and choose Open the first time, or run:
   ```bash
   xattr -dr com.apple.quarantine "Chau7 Next.app"
   ```
4. Move `Chau7 Next.app` to `/Applications` (or `~/Applications`) and open it.

The CI build is for Apple Silicon. On an Intel Mac, build locally.

### Optional command-line tools

The app bundle includes an installer for the standalone `chau7-next` command and
its bundled skills. Run it from Terminal only if you want those commands:

```bash
"/Applications/Chau7 Next.app/Contents/Resources/install-chau7-next-cli.sh"
```

For an app in `~/Applications`, use that path instead of `/Applications`. The
installer places `chau7-next` and `chau7-next-cli` in `~/.local/bin` and copies
the built-in skills to `~/.local/share/chau7-next/skills`; add `~/.local/bin` to
`PATH` if needed. Installing is opt-in: opening Chau7 Next does not install
commands or change another Chau7 installation's helpers or data.

### Build locally

Requires the repository-pinned Rust 1.99 toolchain and Apple developer
tools with the macOS SDK, compiler and linker. The macOS app enables GPUI's
`runtime_shaders` feature: its build script writes a stitched Metal source
file, which GPUI compiles through the Metal API at runtime. `bundle-macos.sh`
does not invoke `xcrun metal` or `metallib`; the separate MetalToolchain
download is not a prerequisite for this bundle.

```bash
cd apps/chau7-next
./scripts/bundle-macos.sh                      # fast optimized build
OUT_DIR=~/Applications ./scripts/bundle-macos.sh   # or build straight into ~/Applications
```

The default keeps `opt-level=3`, turns LTO off, uses 64 codegen units and
incremental compilation for repeat local builds. The higher codegen-unit count
favors build parallelism and can trade away some runtime optimization; no timing
or runtime-performance claim is made without measurements. CI's explicit
`CARGO_INCREMENTAL=0` remains in force. Fast mode shares this worktree's
`target` directory across both Rust workspaces by default; diagnostic mode uses
`target/diagnostic` so symbol-rich artifacts stay separate. Set
`OPTIM_TARGET_DIR` to give the helpers a separate cache; an explicit
`CARGO_TARGET_DIR` selects the cache for both workspaces in either mode.
`CARGO_BUILD_JOBS`
passes through unchanged if you want to set a worker limit. Run one integrated
Cargo gate at a time against its frozen source revision; Cargo can parallelize
compilation within that invocation. For concurrent worktrees, keep each
writable `CARGO_TARGET_DIR` and `OPTIM_TARGET_DIR` private to its worktree.

If the fast build fails, request a single symbol-rich release rebuild:

```bash
BUILD_MODE=diagnostic ./scripts/bundle-macos.sh
```

It keeps the optimized release profile and LTO off, includes Rust DWARF
symbols and unstripped Go symbols, and does not enable debug assertions. After
signing, the packager creates a UUID-matched dSYM for the main Rust app binary
beside the app bundle. Its absolute path, UUID, architecture, and DWARF size are
recorded in the build metadata JSON with a SHA-256 for the DWARF file and the
resolved Apple tool paths. The Xcode toolchain's dsymutil and dwarfdump are
required; packaging fails if either tool is missing or the dSYM UUID or
architecture does not match the signed app binary. Fast mode does not run these
symbol tools. It runs only when explicitly requested. `CARGO_BUILD_VERBOSE=1 BUILD_LOG=target/logs/fast.log` adds verbose
Cargo commands and captures their output. After a successful package build,
`target/bundle/Chau7-Next-<target>-<mode>.json` records the source revision,
working-tree status, compiler versions, compile settings and SHA-256 values for
the seven expected executables. Missing optional local helpers are recorded as
`null`; CI requires and verifies all seven. The sidecar is outside the signed
bundle. Set `BUILD_METADATA_DIR` to put it elsewhere.

For development: `cargo run` from `apps/chau7-next` (logs go to the state
folder below; set `CHAU7_NEXT_LOG_STDOUT=1` to also print them).

## Data and coexistence

| | Former Chau7 (Swift) app | Chau7 Next |
|---|---|---|
| Config, snippets | `~/.chau7/` | `~/.chau7-next/` |
| Window and tab restore | UserDefaults | `~/Library/Application Support/Chau7 Next/session.json` |
| Log | `~/Library/Logs/Chau7.log` | `~/Library/Application Support/Chau7 Next/chau7-next.log` |
| Shell integration files | temporary `ZDOTDIR` | `~/.chau7-next/shell/` |
| MCP socket and bridge | `~/.chau7/mcp.sock`, `~/.chau7/bin/chau7-mcp-bridge` | `~/.chau7-next/mcp.sock`, `~/.chau7-next/bin/chau7-next-mcp-bridge` |
| MCP entry in Claude Code, Codex, Cursor, Windsurf configs | `chau7` | `chau7-next` (the `chau7` entry is never touched) |
| Remote control (iOS pairing, relay credentials, agent socket) | `~/.chau7/remote/state.json`, `~/.chau7/remote/credentials.json`, `~/Library/Application Support/Chau7/remote.sock` | `~/.chau7-next/remote/state.json`, `~/.chau7-next/remote/credentials.json`, `~/Library/Application Support/Chau7 Next/remote.sock` |
| API analytics proxy (ports, database, socket, TLS certificate, prompt rules) | 18080 / 18081, `~/Library/Application Support/Chau7/Proxy/`, `~/.chau7/prompt-rules.json` | 18090 / 18091, `~/Library/Application Support/Chau7 Next/Proxy/`, `~/.chau7-next/prompt-rules.json` |
| Per-tab shell history | `~/.chau7/history/` | the shell's own default |
| AI run telemetry | `~/.chau7/telemetry/runs.db` | `~/.chau7-next/telemetry/runs.db` |

On Unix hosts, Codex and Claude Code connect directly to one authenticated
loopback Streamable HTTP MCP listener in the app. This avoids a bridge process
per client while retaining each client's permission and subscription session.
Cursor and Windsurf keep the stdio bridge. If HTTP startup fails, registration
falls back to the bridge where it is installed. Existing clients must reconnect
or restart to load the updated configuration; running bridges are not killed.

The HTTP listener binds only `127.0.0.1`, validates Host and Origin, and requires a
bearer token. Its stable port and token live in `mcp.http.json` beside the profile's
`mcp.sock`, with owner-only permissions. Client configs containing the token are
also made owner-only. Do not share either file. The endpoint implements MCP
2025-11-25 and 2025-06-18, including JSON replies, SSE notifications and session
DELETE. Sessions expire after 30 idle minutes; notification overflow closes the
session so the client can reconnect. SSE event replay is not implemented.
At most 32 sessions, 32 in-flight POSTs and 64 HTTP connections are admitted.
Closing a session immediately releases its backend socket and admission slot.
Closing or replacing an SSE stream cancels its connection even if the client
stops reading. There is no periodic HTTP connection poll or SSE heartbeat timer.

Open Help > Debug Console or press ⌥⌘L. In Perf, **Copy Performance JSON**
copies the current numeric snapshot, **Save Latest Snapshot** queues
`latest.json`, and **Open Performance Folder** opens the default performance
folder. The separate AI Terminal Logs window is available from the Command
Palette.

Numeric snapshots are collected every five seconds and exclude terminal
output and command text. The default performance folder is
`~/.chau7-next/reports/performance/`. MCP clients can read the same numeric snapshot
with `chau7_performance_snapshot`; `chau7_runtime_info` and
`chau7_state_snapshot` expose build/runtime and app-state diagnostics.

The API analytics proxy is the Go program
(`services/chau7-proxy`, built into the app bundle; needs Go), run
with Chau7 Next's own ports and files, so both proxies can run at once. Its
self-signed TLS certificate is trusted separately (Settings > API Proxy >
Trust Certificate).

Remote control pairs separately: Chau7 Next starts the same `chau7-remote`
agent (built from `services/chau7-remote` into the app bundle; Go is required
to build it) with its own state and credentials files, and shows up on the
iPhone as "<computer> (Chau7 Next)". Settings > Remote Control shows agent
status and its latest error; Settings > Start Here also summarizes Remote
Access status. If startup cannot validate credentials for the Next identity,
the status error includes the helper-specific `identity --state ...` and
`provision --bundle <file> --state ...` commands and the credentials-file
path. The relay admits only provisioned devices. Creating and deploying relay
credentials and provisioning the Mac remain CLI/operator steps; Settings does
not create device credential bundles or deploy relay keys. See
`services/chau7-remote/docs/CREDENTIALS.md` for the full workflow.

On first launch, `~/.chau7/config.toml` and `~/.chau7/snippets.json` are
**copied** (never modified). After that the two apps are independent. Every
path is defined in `chau7_next_core::data_root`; a test fails the build if any
other source file mentions a path owned by the former Swift app (users may
still have its data).

`CHAU7_NEXT_HOME_ROOT=/some/dir` redirects everything (used by tests).

Started from a Chau7 tab (`open -a "Chau7 Next"`, `cargo run`), Chau7 Next
first drops the variables Chau7 sets for its shells (`CHAU7_*`, its temporary
`ZDOTDIR`, `BASH_ENV` and fish `XDG_CONFIG_HOME`, its per-tab `HISTFILE`, its
token optimizer and Codex proxy wrapper folders on `PATH`, its `X-Chau7-*`
attribution headers, and the local analytics proxy `*_BASE_URL`s), so its
shells never talk to Chau7's sockets, logs, history or proxy.

## Notes for agents

The repository's `AGENTS.md` is generated (Aethyme), so the Chau7 Next rules
live here:

- Checks before a change: `cargo fmt --all --check`,
  `cargo clippy --workspace --all-targets -- -D warnings` and
  `cargo test --workspace` (from `apps/chau7-next`).
- Never add a path owned by the former Swift app outside
  `chau7_next_core/src/data_root.rs` (a test enforces it).
- Porting work is driven by `docs/rust-port/inventory/` (read its README
  first). In the same PR as the code, set each ported row's status, then run
  `scripts/parity.py --write` to refresh `docs/rust-port/PARITY.md` (CI
  checks it).
- Platform traits: full parity on macOS first, Linux and Windows only build
  and pass CI. Any feature that calls a macOS-only API goes through a small
  trait under `crates/chau7_next/src/platform/` (macOS implementation plus a
  stub that returns "not supported"); see `src/platform/README.md`.
- `chau7_terminal` (in the top-level `crates/` workspace) is shared with the
  iOS app: never change its C API or its Swift-visible behavior. Rust-only
  additions go in `src/rust_api.rs`; the generated header must stay identical (build without
  `CHAU7_TERMINAL_SKIP_CBINDGEN` and check `git diff` of
  `include/chau7_terminal.h`).

## Settings

`~/.chau7-next/config.toml`, same format as Chau7's `config.toml`
(`[general]`, `[appearance]`, `[terminal]`, `[keybindings]`), plus a `[next]`
section for options only Chau7 Next reads. Menu: Chau7 Next > Settings opens
the file (created with every option commented out); Reload Settings applies it.

### Repo grouping

Find this setting under Settings > Tabs > Repo Grouping. The default is Off
in Chau7 Next, as it was in the former Swift app. Automatic groups tabs by
detected Git root; Manual is for assigning and clearing groups from a tab
context menu. Existing groups remain visible in every mode. Changes made in
Settings save and apply to all open windows immediately. In `config.toml`, set
`repo_grouping_mode` under `[next]` to `off`, `auto`, or `manual`; after
editing the file directly, use Chau7 Next > Reload Settings.

### Idle tabs and numbered navigation

The idle-tabs dropdown has repository headings and separators, with tabs that have no repository collected at the end. The list scrolls while **Close All Idle** remains accessible below it.

**Settings > Tabs > Keyboard Navigation > Numbered Shortcuts Target Visible Tabs Only** makes numbered shortcuts follow the tab bar order, skipping tabs in the Idle dropdown. Horizontal clipping does not change the numbering. The default is off, keeping the all-tabs behavior. To configure it in a file, set `numbered_shortcuts_visible_only = true` under `[next]`, then reload settings.

### Selecting and copying terminal text

Drag past the top or bottom edge of a terminal pane to scroll while extending
its selection. Release the mouse button or move keyboard focus to another pane
to stop. In a full-screen TUI, selection follows the scrolling content while
excluding fixed headers and input footers. If a redraw cannot be matched
unambiguously, selection stops at the last confirmed text.

Terminal copy preserves line breaks and indentation. On macOS, copying also
publishes HTML and a Chau7 rich-text flavor with colors, emphasis and links.
Pasting into the Markdown text panel stores a styled terminal block, so its
formatting survives saving and reopening. Other paste destinations can choose
the plain-text or HTML flavor. Cmd+C without a selection still interrupts the
foreground process.

Large or unusually style-heavy selections fall back to the complete plain text
when the rich-format budget is exceeded. Editing a saved terminal block can
invalidate its stored style ranges; the text remains available in monospace.

## Shortcuts (macOS)

| | |
|---|---|
| New tab / close tab / reopen | Cmd+T / Cmd+W / Cmd+Shift+T |
| Close other tabs | Cmd+Opt+W |
| Next / previous tab | Cmd+Shift+] / Cmd+Shift+[, Ctrl+Tab / Ctrl+Shift+Tab, Cmd+Opt+Right / Left |
| Tab N, move tab right / left | Cmd+1..9 (by key position, so Cmd+& on AZERTY) / Cmd+Opt+Shift+] / [ |
| Rename tab | Cmd+Opt+R or double-click the tab |
| New window / close window | Cmd+N / Cmd+Shift+W |
| Split side by side / stacked / close pane | Cmd+D / Cmd+Opt+D / Cmd+Ctrl+W |
| Focus next / previous pane | Cmd+Opt+] / Cmd+Opt+[ |
| Copy (Ctrl-C without a selection), cut, paste, paste escaped | Cmd+C, Cmd+X, Cmd+V, Cmd+Opt+V |
| Select command line, twice for everything | Cmd+A |
| Find, next, previous, use selection | Cmd+F, Cmd+G, Cmd+Shift+G, Cmd+E |
| Snippets / command palette | Cmd+; or Cmd+Opt+S / Cmd+Opt+P |
| Bigger / smaller / actual size | Cmd+= / Cmd+- / Cmd+0 |
| Clear screen / clear scrollback | Cmd+K / Cmd+Opt+K |
| Previous / next command line | Cmd+Up / Cmd+Down |
| Command history at the prompt (this tab / all tabs) | Up, Down / Opt+Up, Opt+Down |
| SSH connections / export text | Cmd+Shift+O / Cmd+Shift+S |
| Keyboard shortcuts | Cmd+/ |

On Linux and Windows, Cmd becomes Ctrl+Shift and tab N is Alt+N.
Holding a letter repeats it (the accent popup is off for Chau7 Next; turn it
back on with `defaults write com.chau7.next ApplePressAndHoldEnabled -bool true`).
Option is Meta (Option+B is word back) except when it types punctuation
(Option+5 is `[` on AZERTY), as in Chau7.
Custom bindings: Help > Keyboard Shortcuts, or `[keybindings]` in config.toml
with the Swift action names (`"cmd+shift+b" = "toggleBroadcast"`); presets in
Settings (Default, Vim, Emacs).

## Layout

```
apps/chau7-next/
  crates/chau7_next_core/   pure logic, no UI: ports of Chau7Core with their tests
  crates/chau7_next_mcp_bridge/  chau7-next-mcp-bridge: stdio to MCP socket bridge for AI CLIs
  crates/chau7_next/        the GPUI app
    src/terminal/           session (PTY + parser via chau7_terminal) and view (grid painting, input, IME)
    src/workspace/          one window: mod.rs (tabs, render) plus one file per feature
                            (tab bar, drag and drop, rename, find, pickers, menus, ...)
    src/settings/           settings, one file per domain (appearance, terminal, tabs, ...)
    src/settings_window/    settings window, one file per section
    src/actions/            actions (mod.rs), default key bindings (keymap.rs), menu bar (menus.rs)
    src/pane.rs             split panes
    src/mcp/                MCP server: socket, tools, approvals, AI CLI registration
  scripts/bundle-macos.sh   builds "Chau7 Next.app"
```

The terminal emulator is the shared `chau7_terminal` crate in the repository's
top-level `crates/` workspace (`crates/chau7_terminal`), linked as a Rust
library. The iOS app links the same crate through its C API.

## Checks

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

CI (`.github/workflows/chau7-next.yml`) runs these on macOS, Linux and
Windows, and builds the macOS app bundle.

## Owned native parity fixtures (macOS)

From a clean committed checkout, with Rust 1.99.0 already installed:

```bash
python3 apps/chau7-next/scripts/native-parity.py
```

Use `--case restore`, `--case settings` or `--case editor` for one case, and
`--toolchain X.Y.Z` for another exact installed compiler. The script pins Cargo,
rustc and rustdoc; it does not update the shared `stable` alias. It builds the
optional `native-parity-fixture` feature into a separate target directory with
command-local LTO off. Ordinary app packaging leaves this feature disabled.

Each case uses a new validated temporary profile and actual macOS windows/frame
callbacks. Fake local shells record synthetic resume input without interpreting
provider commands. Settings and AppKit editor cases exercise production views.
The fixtures do not send OS input, change permissions, contact providers/devices
or reuse a live profile. Hardware keyboard, pointer and OS input-source checks
remain on the hand-test checklist.

The printed evidence directory contains the build log, per-case stdout/stderr
and a manifest with the exact Git revision, compiler, binary SHA256 and outcome.
Pass requires one explicit positive JSON result, exit zero and removal of the
owned profile. Empty stdout never counts as success. An unexpected timeout
retains the owned process PID/profile for diagnosis without forced signals.
An unbundled fixture has null bundle metadata; its manifest supplies provenance.

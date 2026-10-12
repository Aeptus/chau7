# Chau7 Next

Picking this up? Start with [`docs/rust-port/HANDOFF.md`](../../docs/rust-port/HANDOFF.md).

The Rust/GPUI port of Chau7. It runs **next to** the Swift app (bundle id
`com.chau7.next`, its own data folders), so both can be installed and used at
the same time while the port reaches parity. See
[`docs/rust-port/DUAL-SHIP.md`](../../docs/rust-port/DUAL-SHIP.md) for the plan
and [`docs/rust-port/PARITY.md`](../../docs/rust-port/PARITY.md) for what is
ported so far.

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

### Build locally

Requires Rust (stable, 1.88 or newer) and Xcode (GPUI compiles Metal shaders).
On Xcode 26 or newer the Metal toolchain is a separate download; if the build
fails with "cannot execute tool 'metal'", run:

```bash
xcodebuild -downloadComponent MetalToolchain
```

```bash
cd apps/chau7-next
./scripts/bundle-macos.sh                      # builds target/bundle/Chau7 Next.app
OUT_DIR=~/Applications ./scripts/bundle-macos.sh   # or build straight into ~/Applications
```

For development: `cargo run` from `apps/chau7-next` (logs go to the state
folder below; set `CHAU7_NEXT_LOG_STDOUT=1` to also print them).

## Data and coexistence

| | Chau7 (Swift) | Chau7 Next |
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

The API analytics proxy is the same Go program as Chau7's
(`apps/chau7-macos/chau7-proxy`, built into the app bundle; needs Go), run
with Chau7 Next's own ports and files, so both proxies can run at once. Its
self-signed TLS certificate is trusted separately (Settings > API Proxy >
Trust Certificate).

Remote control pairs separately: Chau7 Next starts the same `chau7-remote`
agent (built from `services/chau7-remote` into the app bundle; needs Go to
build) with its own state and credentials files, and shows up on the iPhone as
"<computer> (Chau7 Next)". The relay now admits only provisioned devices
(`chau7-remote identity`, then `chau7-remote provision --bundle <file>
--state ~/.chau7-next/remote/state.json`, see
`services/chau7-remote/docs/CREDENTIALS.md`); Chau7 Next has no UI for that
yet.

On first launch, `~/.chau7/config.toml` and `~/.chau7/snippets.json` are
**copied** (never modified). After that the two apps are independent. Every
path is defined in `chau7_next_core::data_root`; a test fails the build if any
other source file mentions a path owned by the Swift app.

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
- Never add a path owned by the Swift app outside
  `chau7_next_core/src/data_root.rs` (a test enforces it).
- Porting work is driven by `docs/rust-port/inventory/` (read its README
  first). In the same PR as the code, set each ported row's status, then run
  `scripts/parity.py --write` to refresh `docs/rust-port/PARITY.md` (CI
  checks it).
- Platform traits: full parity on macOS first, Linux and Windows only build
  and pass CI. Any feature that calls a macOS-only API goes through a small
  trait under `crates/chau7_next/src/platform/` (macOS implementation plus a
  stub that returns "not supported"); see `src/platform/README.md`.
- `chau7_terminal` is shared with the Swift app: never change its C API or
  its Swift-visible behavior. Rust-only additions go in `src/rust_api.rs`;
  the generated header must stay identical (build without
  `CHAU7_TERMINAL_SKIP_CBINDGEN` and check `git diff` of
  `include/chau7_terminal.h`).

## Settings

`~/.chau7-next/config.toml`, same format as Chau7's `config.toml`
(`[general]`, `[appearance]`, `[terminal]`, `[keybindings]`), plus a `[next]`
section for options only Chau7 Next reads. Menu: Chau7 Next > Settings opens
the file (created with every option commented out); Reload Settings applies it.

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

The terminal emulator is the same `chau7_terminal` crate the Swift app uses
(`apps/chau7-macos/rust/chau7_terminal`), linked as a Rust library instead of
through its C API.

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

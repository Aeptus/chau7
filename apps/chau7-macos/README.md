# Chau7 (macOS)

Chau7 is a macOS menu bar helper and floating terminal overlay built for AI-assisted CLI work. It tails local JSONL logs and CLI history to send notifications and keep a live multi-tab terminal in view.

## Feature Highlights

- Menu bar status item with quick toggles, recent activity, and session status.
- Native notifications for AI events and command idle detection.
- Multi-tab SwiftTerm overlay with rename, colors, last-command badges, and git branch indicator.
- Command palette, search overlay (regex + case sensitivity), snippets, clipboard history, bookmarks, and broadcast input.
- AI CLI detection with auto tab theming and custom detection rules.
- Claude Code event monitoring with permission and response-complete alerts.
- SSH connection manager with jump hosts and import from `~/.ssh/config`.

For a complete feature inventory, see `docs/FEATURES.md`:
- [Overview](docs/FEATURES.md#overview)
- [Terminal Overlay and Emulator](docs/FEATURES.md#terminal-overlay-and-emulator)
- [AI Integration and Monitoring](docs/FEATURES.md#ai-integration-and-monitoring)
- [Productivity Tools](docs/FEATURES.md#productivity-tools)
- [Settings and Customization](docs/FEATURES.md#settings-and-customization)
- [Debugging and Diagnostics](docs/FEATURES.md#debugging-and-diagnostics)
- [Keyboard Shortcuts](docs/FEATURES.md#keyboard-shortcuts)
- [Environment Variables](docs/FEATURES.md#environment-variables)

## Requirements

- macOS 13+ (Ventura)
- Xcode 15+ or Swift 5.9+ to build
- Network access the first time to fetch SwiftTerm via Swift Package Manager

## Install (build + run)

All commands below assume you are in `apps/chau7-macos`.

### Option A: Open in Xcode

1. Open `Package.swift` in Xcode.
2. Select the `Chau7` scheme.
3. Run (Cmd+R).

The first time it runs, macOS will ask for Notifications permission.
To see verbose logs when launched from Terminal, set `CHAU7_VERBOSE=1`.

### Option B: Build in Terminal

From the project folder:

```bash
swift build -c release
CHAU7_VERBOSE=1 .build/release/Chau7
```

Keep the app running to keep notifications active.

### Recommended: Build a proper .app bundle (better notifications)

For notifications to show up under their own app entry in macOS Settings,
run the helper script to create an app bundle:

```bash
swift build -c release
./Scripts/build-app.sh
open ./build/Chau7.app
```

`build-app.sh` now defaults to a development bundle identifier (`com.chau7.app.dev`) to avoid
macOS TCC permission collisions with the Launchpad app.

Quick install one-liner:

```bash
swift build -c release && ./Scripts/build-app.sh && open ./build/Chau7.app
```

Dock icon is enabled by default for the app bundle; to hide it:

```bash
SHOW_DOCK_ICON=0 ./Scripts/build-app.sh
```

### One-shot build + launch (verbose)

```bash
./Scripts/build-and-run.sh
```

`build-and-run.sh` now defaults to a dev bundle identifier (`com.chau7.app.dev`) to avoid
macOS permission collisions with `/Applications/Chau7.app`.
When ad-hoc signing is used, it now applies a stable designated requirement
(`designated => identifier "<bundle-id>"`) so TCC permissions do not churn on every rebuild.
Override when needed:

```bash
BUNDLE_IDENTIFIER=com.chau7.app ./Scripts/build-and-run.sh
```

### Install / update the Launchpad app

To install the production Launchpad app (`com.chau7.app`) into `/Applications`:

```bash
./Scripts/install-launchpad-app.sh
```

Note: this script refuses to replace `/Applications/Chau7.app` while it is running.
Replacing a running app causes TCC code-requirement mismatches and repeated permission prompts.

Optional: launch it after install:

```bash
OPEN_AFTER_INSTALL=1 ./Scripts/install-launchpad-app.sh
```

You can also run the bundled binary directly with verbose logs:

```bash
CHAU7_VERBOSE=1 ./build/Chau7.app/Contents/MacOS/Chau7
```

For extremely verbose trace logs (tailers, parsing, idle tracking):

```bash
CHAU7_VERBOSE=1 CHAU7_TRACE=1 ./build/Chau7.app/Contents/MacOS/Chau7
```

Logs are written to:

```
~/Library/Logs/Chau7.log
```

## Getting Started Cheatsheet

- Open overlay: menu bar icon → "Open Terminal"
- New tab: Cmd+T
- Command palette: Cmd+Shift+P
- Find: Cmd+F (regex and case toggles)
- Snippets: Cmd+;
- Next/prev tab: Cmd+Shift+] / Cmd+Shift+[
- Toggle dropdown: Ctrl+` (if enabled)
- Debug console: Cmd+Shift+D

## Chau7 terminal window

The app now ships with a floating terminal overlay powered by SwiftTerm.
It starts automatically and provides:
- A shell running your default login shell (configurable)
- Tabs with standard shortcuts (Cmd+T, Cmd+W, Cmd+Shift+[ / ], Ctrl+Tab)
- Multi-window support (Cmd+N) and tab jump (Cmd+1-9)
- Search overlay with regex/case-sensitive options (Cmd+F)
- Command palette (Cmd+Shift+P) and snippets (Cmd+;)
- Clipboard history, bookmarks, and broadcast input
- AI CLI detection with auto tab colors and product icons
- Command idle notifications based on input/output activity
- Optional dropdown terminal (Ctrl+`) when enabled in Settings

Use the menu bar icon to reopen the overlay if the window is hidden.

Idle behavior:
- "Idle seconds" triggers a notification.
- "Stale seconds" marks sessions closed and stops further idle alerts.

## Emit events from your CLI tools

Default log file: `~/.ai-events.log`

Use the helper script:

```bash
./Scripts/ai-event.sh needs_validation "Claude" "Please review the plan"
./Scripts/ai-event.sh finished "Codex" "Bulk upload complete"
./Scripts/ai-event.sh failed "Codex" "Tests failed"
```

Each line is JSON. Example:

```json
{"type":"finished","tool":"Codex","message":"Bulk upload complete","ts":"2026-01-09T12:00:00+01:00"}
```

## Wiring into Claude CLI / Codex

You can wrap your commands. Example pattern:

```bash
your_command_here || ./Scripts/ai-event.sh failed "Claude" "Command failed"
./Scripts/ai-event.sh finished "Claude" "Command finished"
```

There are example wrapper scripts in `Scripts/`.

### Live terminal output (PTY wrapper)

The history JSONL logs do not include the live terminal output. To capture it,
use the PTY wrappers:

```bash
./Scripts/codex-pty.sh
./Scripts/claude-pty.sh
```

When running AI CLIs inside the Chau7 terminal overlay, PTY output and AI events
are captured automatically. The wrappers are only needed for external terminals.

These log raw terminal output to:
- `~/Library/Logs/Chau7/codex-pty.log`
- `~/Library/Logs/Chau7/claude-pty.log`

You can override the paths with:
```bash
AI_CODEX_TTY_LOG=~/codex-tty.log ./Scripts/codex-pty.sh
AI_CLAUDE_TTY_LOG=~/claude-tty.log ./Scripts/claude-pty.sh
```

Input lines are tagged as:
```
[INPUT] your text
```

TTY readability:
- "Normalize terminal output" strips ANSI codes, handles backspaces, and removes control chars.
- You can disable it in the UI or set `CHAU7_TERMINAL_NORMALIZE=0` (legacy `AI_TTY_NORMALIZE=0`).
- "Render ANSI styling" keeps ANSI colors/styles in the terminal stream (set `CHAU7_TERMINAL_ANSI=0` or legacy `AI_TTY_ANSI=0`).

## Start at login (optional)

A sample LaunchAgent plist is included in `LaunchAgent/`.

Because the binary path depends on where you built it, do this:

1. Build release:

```bash
swift build -c release
```

2. Copy the binary somewhere stable, for example:

```bash
mkdir -p ~/Applications/Chau7
cp .build/release/Chau7 ~/Applications/Chau7/
```

3. Edit `LaunchAgent/com.chau7.plist` and set the binary path to:

```
$HOME/Applications/Chau7/Chau7
```

4. Install the LaunchAgent:

```bash
mkdir -p ~/Library/LaunchAgents
cp LaunchAgent/com.chau7.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.chau7.plist
```

Unload:

```bash
launchctl unload -w ~/Library/LaunchAgents/com.chau7.plist
```

## Troubleshooting

- Notifications do not appear: run the app bundle (`./Scripts/build-app.sh`), and verify notifications are allowed in System Settings.
- Menu bar icon is missing: quit and relaunch, or check `~/Library/Logs/Chau7.log` for launch errors.
- No AI events: confirm `~/.ai-events.log` is being written and `CHAU7_EVENTS_LOG` is not pointing elsewhere.
- PTY logs are empty: if you are using an external terminal, run `./Scripts/codex-pty.sh` or `./Scripts/claude-pty.sh` and verify `CHAU7_CODEX_TERMINAL_LOG`/`CHAU7_CLAUDE_TERMINAL_LOG`. Inside the Chau7 terminal overlay, logs are captured automatically.
- Overlay is hidden or off-screen: use Settings -> Actions -> Reset Window Positions, then reopen via the menu bar icon.

## FAQ

Q: What does an AI event line look like?
A: Each line is JSON with at least `type` and `tool`. Example:
```json
{"type":"finished","tool":"Codex","message":"Bulk upload complete","ts":"2026-01-09T12:00:00+01:00"}
```

Q: How do I emit events from my own CLI?
A: Use the helper script or inline it in your wrappers:
```bash
./Scripts/ai-event.sh needs_validation "Claude" "Please review the plan"
./Scripts/ai-event.sh finished "Codex" "All done"
./Scripts/ai-event.sh failed "Codex" "Tests failed"
```

Q: How do I capture live terminal output (PTY)?
A: Run the PTY wrappers instead of calling the CLI directly:
```bash
./Scripts/codex-pty.sh
./Scripts/claude-pty.sh
```
Logs default to `~/Library/Logs/Chau7/codex-pty.log` and `~/Library/Logs/Chau7/claude-pty.log`.

## Testing

Chau7 includes a comprehensive test suite for core functionality.

### Running Tests

```bash
# Ensure Xcode is set as the developer directory
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Run all tests
swift test
```

### Test Coverage

- **CommandDetectionTests** (40 tests): AI CLI detection, tokenization, environment parsing
- **EventParsingTests** (6 tests): Hook event parsing, session ID extraction

### Adding New Tests

Tests live in `apps/chau7-macos/Tests/Chau7Tests/`. The testable logic is in `apps/chau7-macos/Sources/Chau7Core/`:

- `CommandDetection.swift` - Pure functions for detecting AI CLIs
- Add new pure functions here for testability

## Remote Control (experimental)

- Build the remote agent from the repo root: `cd services/chau7-remote && go build ./cmd/chau7-remote`
- Configure relay and pairing in Chau7 settings: `Settings > Remote Control`

## Debugging

### Debug Console (Cmd+Shift+D)

Press **Cmd+Shift+D** anywhere in the app to open the Debug Console:

- **State**: Real-time app state, tabs, Claude sessions
- **Contexts**: Active debug operations with correlation IDs
- **Events**: Claude Code event stream
- **Logs**: Live log viewer with filtering
- **Report**: Generate bug reports and state snapshots

### Structured Logging

All operations use correlation IDs for tracing:

```
[ABC123] START command-detection {input=claude --help}
[ABC123] Found token {token=claude}
[ABC123] END command-detection SUCCESS (2ms) {result=Claude}
```

Logs are written to `~/Library/Logs/Chau7.log`

### Bug Reports

Generate detailed bug reports from the Debug Console or programmatically:

```swift
let path = BugReporter.shared.generateReport(userDescription: "Describe the issue")
```

Reports are saved to `~/.chau7/reports/` and include:
- Full app state snapshot
- Recent events
- Last 50 log lines
- Feature flag states

## Notes

- Notifications are delivered via UserNotifications (native).
- If you want action buttons (Approve or Retry), that is a small follow-up change.

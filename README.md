# Chau7 (macOS)

A small macOS menu bar helper that watches a local event log (newline-delimited JSON)
and shows native notifications when:
- a CLI task finishes
- a CLI task fails
- a CLI needs human validation

## What you get

- Menu bar icon (bell)
- Native notifications (banner or alert)
- Event log tailing from `~/.ai-events.log` by default
- Helper scripts you can call from Codex or Claude wrappers
- Chau7 terminal window (SwiftTerm) with live shell, status badge, and command-idle notifications

## Requirements

- macOS 13+ (Ventura) for MenuBarExtra
- Xcode 15+ or Swift 5.9+ to build
- Network access the first time to fetch SwiftTerm via Swift Package Manager

## Install (build + run)

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

Dock icon is enabled by default for the app bundle; to hide it:

```bash
SHOW_DOCK_ICON=0 ./Scripts/build-app.sh
```

### One-shot build + launch (verbose)

```bash
./Scripts/build-and-run.sh
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

## Chau7 terminal window

The app now ships with a floating terminal overlay powered by SwiftTerm.
It starts automatically and provides:
- A shell running your default login shell
- A top bar showing title, directory, and a status badge
- Notifications when a command becomes idle (heuristic based on input/output)
- Tabs with standard shortcuts (Cmd+T new tab, Cmd+W close tab, Cmd+Shift+[ / ] or Ctrl+Tab to switch)
- Window shortcuts (Cmd+N new overlay window, Cmd+[1-9] jump to tab)
- Find bar (Cmd+F) with in-terminal highlights and match list; Next/Prev with Cmd+G / Cmd+Shift+G
- Tab rename + color (Cmd+Shift+R)

Use the "Show Overlay" button in the Control Center if the window is hidden.

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
- You can disable it in the UI or set `AI_TTY_NORMALIZE=0`.
- "Render ANSI styling" keeps ANSI colors/styles in the terminal stream (set `AI_TTY_ANSI=0` to force plain).

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
/Users/YOUR_USERNAME/Applications/Chau7/Chau7
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

Tests live in `Tests/Chau7Tests/`. The testable logic is in `Sources/Chau7Core/`:

- `CommandDetection.swift` - Pure functions for detecting AI CLIs
- Add new pure functions here for testability

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

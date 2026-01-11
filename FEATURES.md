# Chau7 Features

Chau7 is a macOS menu bar helper and terminal overlay built for AI-assisted CLI work. It watches local JSONL logs, sends notifications, and provides a multi-tab SwiftTerm terminal with workflow tools.

## Table of Contents

- [Overview](#overview)
- [Core Experience](#core-experience)
- [Terminal Overlay and Emulator](#terminal-overlay-and-emulator)
- [AI Integration and Monitoring](#ai-integration-and-monitoring)
- [Productivity Tools](#productivity-tools)
- [Settings and Customization](#settings-and-customization)
- [Debugging and Diagnostics](#debugging-and-diagnostics)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [File Locations](#file-locations)
- [Environment Variables](#environment-variables)
- [Experimental or Not Yet Wired](#experimental-or-not-yet-wired)
- [Architecture](#architecture)

---

## Overview

- Menu bar status item with popover for quick actions, recent events, and Claude Code sessions.
- Local event and history log tailing for AI tools.
- Floating, multi-tab terminal overlay with productivity overlays (search, snippets, clipboard).

## Core Experience

### Menu Bar and Notifications

- Status bar icon with active/paused indicator.
- Popover shows active Claude Code sessions, recent events, and quick toggles (monitoring, broadcast, AI themes, syntax toggle, opacity).
- Native notifications for AI events and idle detection with per-type filters.

### Event Monitoring

- Tails AI event log lines from `~/.ai-events.log` (configurable).
- Monitors Codex and Claude history logs for idle and stale sessions.
- Optional tailing of Codex and Claude PTY logs for live output display (ANSI or normalized).

### Windows

- Overlay terminal window with blur background, resizable and multi-window.
- Dropdown terminal window (quake-style) with global hotkey and configurable height.
- Settings, Debug Console, Help, Snippets, and SSH manager windows.

## Terminal Overlay and Emulator

### Terminal Session

- SwiftTerm PTY with ANSI/VT100 and true-color support.
- Shell selection (system, zsh, bash, fish, custom path).
- Default start directory and optional startup command.
- Shell integration for working directory tracking (OSC 7).
- Command idle detection (`CHAU7_IDLE_SECONDS`) with notifications.

### Tabs and Navigation

- Multiple tabs per window with new/close, rename, move left/right, and custom colors.
- Auto tab color based on detected AI CLI.
- AI product icons in the tab bar when detected.
- Last-command badge (duration and exit status) and git branch indicator.
- Background rendering suspension for inactive tabs with configurable delay.
- Search overlay with regex and case sensitive options, match list, and next/previous navigation.

### Input and Mouse Helpers

- Cmd+click URLs and file paths (line and column supported) with configurable editor and browser.
- Option+click cursor positioning on the command line.
- Copy on select.
- Paste escaped to avoid shell interpolation.

## AI Integration and Monitoring

### Supported AI CLIs

- Claude (claude, claude-code, claude-cli)
- Codex (codex, codex-cli, codex-pty)
- Gemini (gemini, gemini-cli)
- ChatGPT (chatgpt, gpt, openai)
- GitHub Copilot (copilot, gh copilot)

### Detection Methods

- Command line tokenization with wrapper skipping (env, sudo, npx, bunx, pnpm).
- Output banner detection (Claude, Codex, Gemini, ChatGPT, Copilot).
- Custom detection rules with display name and tab color.

### Claude Code Monitoring

- Tails `~/.chau7/claude-events.jsonl` for session and tool events.
- Tracks session state (responding, waiting permission, waiting input).
- Sends notifications for permission requests and response completion.

### AI Event Notifications

- Event types: finished, failed, needs_validation, permission, tool_complete, session_end, idle.
- Per-type notification filters in Settings.

## Productivity Tools

- Command palette (Cmd+Shift+P) with searchable commands.
- Snippet manager with global, profile, and repo sources plus placeholder navigation.
- Clipboard history with pinning and quick paste.
- Bookmarks per tab (add and list; jump currently only switches tabs).
- Broadcast input to all tabs (with per-tab exclusion).
- SSH connection manager with saved profiles, jump hosts, and import from `~/.ssh/config`.
- Export terminal text and print output.

## Settings and Customization

- Searchable settings UI with categorized sections.
- Settings profiles (save/load named profiles).
- iCloud sync for settings (opt-in).
- Export/import settings as JSON.
- Fonts, default zoom, and color scheme presets.
- Window opacity and per-workspace overlay position memory.
- Notification filters and AI detection rules.
- Terminal monitoring toggles (events, history, terminal logs).

## Debugging and Diagnostics

- Debug Console with State, Contexts, Events, Logs, and Report tabs.
- Structured logging with correlation IDs and trace mode.
- Bug report generator and state snapshots.
- Log file view in Settings.

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
| Ctrl+Tab | Next tab |
| Ctrl+Shift+Tab | Previous tab |
| Cmd+Option+Shift+] | Move tab right |
| Cmd+Option+Shift+[ | Move tab left |
| Cmd+Shift+R | Rename tab |

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
| Cmd+Shift+P | Command palette |

### View and Terminal

| Shortcut | Action |
| --- | --- |
| Cmd+K | Clear screen |
| Cmd+Shift+K | Clear scrollback |
| Cmd+= | Zoom in |
| Cmd+- | Zoom out |
| Cmd+0 | Actual size |
| Cmd+Ctrl+F | Toggle full screen |

### App and Tools

| Shortcut | Action |
| --- | --- |
| Cmd+, | Settings |
| Cmd+Shift+D | Debug console |
| Cmd+Shift+O | SSH connections |
| Cmd+Shift+S | Export text |
| Cmd+P | Print |
| Esc | Close overlays (search, rename, snippets, etc) |
| Ctrl+` | Toggle dropdown terminal (if enabled) |

## File Locations

| Purpose | Path |
| --- | --- |
| AI event log | `~/.ai-events.log` |
| Claude history log | `~/.claude/history.jsonl` |
| Codex history log | `~/.codex/history.jsonl` |
| Claude Code hook events | `~/.chau7/claude-events.jsonl` |
| App log | `~/Library/Logs/Chau7.log` |
| Codex PTY log | `~/Library/Logs/Chau7/codex-pty.log` |
| Claude PTY log | `~/Library/Logs/Chau7/claude-pty.log` |
| PTY capture log | `~/Library/Logs/Chau7/pty-capture.log` |
| Global snippets | `~/.chau7/snippets.json` |
| Profile snippets | `~/.chau7/profile-snippets.json` |
| Repo snippets | `.chau7/snippets.json` |
| Bug reports | `~/.chau7/reports/` |
| State snapshots | `~/.chau7/snapshots/` |
| LaunchAgent sample | `LaunchAgent/com.chau7.plist` |

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
| CHAU7_VERBOSE | Verbose logging (1 enables) |
| CHAU7_TRACE | Trace logging (1 enables) |
| CHAU7_CLEAR_ON_LAUNCH | Disable clear-on-launch when set to 0/false |
| CHAU7_PTY_DUMP | Enable raw PTY capture (1 enables) |
| CHAU7_TRACE_PTY | Same as CHAU7_PTY_DUMP |
| CHAU7_PTY_DUMP_PATH | Override PTY capture log path |

Legacy AI_* and SMART_OVERLAY_* environment variables are still supported.

## Experimental or Not Yet Wired

The following items exist in code or settings UI but are not fully wired into the live terminal UI yet:

- Split panes (controller and UI shell exist, not integrated into overlay).
- Semantic search (command block tracking exists, no UI).
- Syntax highlighting for live terminal output (engine exists, not attached).
- Inline images (iTerm2 imgcat parser exists, not attached).
- Pretty print JSON (setting only).
- System theme selection for the overlay (setting only).
- Launch at login toggle in Settings (use LaunchAgent sample for now).
- Tab bar visibility toggle (UI only).
- Keybinding presets and shortcut editor (stored in settings, not used by runtime).
- Bell, cursor style/blink, and scrollback size settings (UI only).

## Architecture

```
Chau7/
├── Sources/
│   ├── Chau7/           # Main app (SwiftUI + AppKit)
│   └── Chau7Core/       # Testable pure functions
├── Tests/
│   └── Chau7Tests/      # Unit tests
├── Scripts/             # Build and helper scripts
└── Package.swift        # Swift Package Manager config
```

Key patterns:

- ObservableObject for state management.
- Singleton managers for shared features.
- Pure functions in Chau7Core for testability.
- Correlation IDs for trace logging.

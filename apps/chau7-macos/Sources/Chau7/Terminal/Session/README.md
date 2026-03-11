# Terminal/Session

Terminal session lifecycle, command block tracking, history navigation, and input detection.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. Session-level AI detection (app name, provider) uses `AIToolRegistry` for tool identity. Tool-specific logic belongs in Monitoring, not here.

## Files

| File | Purpose |
|------|---------|
| `BookmarkManager.swift` | Manages per-tab terminal bookmarks with configurable limits |
| `CommandBlockManager.swift` | Tracks command blocks (start/end lines, timing, exit status) per tab |
| `CommandHistoryManager.swift` | Per-tab and global command history for arrow-key navigation |
| `InputLineTracker.swift` | Tracks which terminal rows contain user input (prompt lines) |
| `LineTimestampTracker.swift` | Associates timestamps with terminal output lines for timeline display |
| `TerminalSessionModel.swift` | Core session model managing shell process, search, output capture, and delegates |

## Key Types

- `TerminalSessionModel` — ObservableObject managing the shell process, PTY, and session state
- `CommandBlockManager` — singleton tracking command execution blocks with line ranges and exit codes
- `CommandHistoryManager` — singleton providing per-tab and cross-tab command history navigation
- `InputLineTracker` — bounded set tracking which rows are user input lines

## Dependencies

- **Uses:** Logging, Settings, History, Keyboard, Monitoring, Utilities, AI
- **Used by:** Overlay, SplitPanes, Rendering, Terminal/Views

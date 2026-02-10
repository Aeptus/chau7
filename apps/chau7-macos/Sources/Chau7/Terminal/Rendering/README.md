# Terminal/Rendering

ANSI parsing, SwiftTerm terminal view subclass, output normalization, and PTY data capture.

## Files

| File | Purpose |
|------|---------|
| `AnsiParser.swift` | Parses ANSI SGR escape sequences into NSAttributedString with 16/256/true color support |
| `Chau7TerminalView.swift` | Custom LocalProcessTerminalView subclass with output/input hooks and cursor overlay |
| `TerminalNormalizer.swift` | Normalizes terminal output by processing backspaces, stripping ANSI codes, and control chars |
| `TerminalOutputCapture.swift` | Captures raw PTY data to a log file for debugging terminal emulation issues |

## Key Types

- `Chau7TerminalView` — SwiftTerm-based terminal view with output callbacks, dim patching, and copy-on-select
- `AnsiParser` — enum providing static ANSI-to-NSAttributedString conversion with style tracking
- `TerminalNormalizer` — enum with static methods for cleaning terminal text for display
- `TerminalOutputCapture` — singleton logging raw PTY I/O when enabled via environment variables

## Dependencies

- **Uses:** Settings, Logging, Terminal/Session (InputLineTracker), Keyboard, Snippets, Rendering (TerminalCursorLineView)
- **Used by:** Performance (SwiftTermBridge, MetalDisplayCoordinator), Terminal/Views, Overlay

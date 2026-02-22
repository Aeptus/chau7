# Terminal/Rendering

ANSI parsing, output normalization, and PTY data capture.

## Files

| File | Purpose |
|------|---------|
| `AnsiParser.swift` | Parses ANSI SGR escape sequences into NSAttributedString with 16/256/true color support |
| `TerminalNormalizer.swift` | Normalizes terminal output by processing backspaces, stripping ANSI codes, and control chars |
| `TerminalOutputCapture.swift` | Captures raw PTY data to a log file for debugging terminal emulation issues |

## Key Types

- `AnsiParser` — enum providing static ANSI-to-NSAttributedString conversion with style tracking
- `TerminalNormalizer` — enum with static methods for cleaning terminal text for display
- `TerminalOutputCapture` — singleton logging raw PTY I/O when enabled via environment variables

## Dependencies

- **Uses:** Settings, Logging
- **Used by:** Terminal/Views, Overlay

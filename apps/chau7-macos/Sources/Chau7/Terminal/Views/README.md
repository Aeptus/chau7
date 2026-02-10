# Terminal/Views

SwiftUI/AppKit terminal view wrappers, the unified terminal view protocol, and log display.

## Files

| File | Purpose |
|------|---------|
| `AnsiLogView.swift` | NSViewRepresentable rendering ANSI-colored log lines in an NSTextView with font caching |
| `TerminalLineView.swift` | Reusable SwiftUI component for rendering a single terminal line with normalization |
| `TerminalViewProtocol.swift` | Unified protocol (`TerminalViewLike`) for backend-agnostic terminal view access |
| `TerminalViewRepresentable.swift` | NSViewRepresentable bridging terminal views into SwiftUI with Metal coordinator support |

## Key Types

- `TerminalViewLike` — protocol unifying Chau7TerminalView and RustTerminalView interfaces
- `TerminalViewRepresentable` — SwiftUI bridge wrapping terminal views with Metal rendering support
- `TerminalContainerView` — NSView container managing terminal view layout and Metal coordinator
- `AnsiLogView` — NSViewRepresentable for rendering ANSI-colored log output

## Dependencies

- **Uses:** Terminal/Rendering (Chau7TerminalView), RustBackend (RustTerminalView), Performance (MetalDisplayCoordinator), Rendering, Settings
- **Used by:** Overlay, SplitPanes, StatusBar

# Terminal

Top-level terminal module containing session management, rendering, and view submodules.

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Session/` | Terminal session lifecycle, command tracking, input detection, and history |
| `Rendering/` | ANSI parsing, terminal view subclass, output normalization, and PTY capture |
| `Views/` | SwiftUI/AppKit terminal view wrappers, protocols, and log display |

## Dependencies

- **Uses:** Settings, Logging, Utilities, Performance, RustBackend, Rendering
- **Used by:** App, Overlay, SplitPanes, StatusBar, Analytics, Scripting

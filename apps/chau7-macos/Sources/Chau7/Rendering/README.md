# Rendering

Terminal overlay views for command blocks, inline images, cursor lines, and search highlights.

## Files

| File | Purpose |
|------|---------|
| `CommandBlockOverlayView.swift` | Renders colored left-border gutter marks for command blocks (green/red/blue) |
| `InlineImageSupport.swift` | Handles iTerm2 image protocol (ESC ] 1337) for inline image display |
| `TerminalCursorLineView.swift` | Draws cursor line highlight, context lines, and input history indicators |
| `TerminalHighlightView.swift` | Renders search match highlights and selection overlays on the terminal |

## Key Types

- `CommandBlockOverlayView` — SwiftUI overlay drawing command block gutter marks with hover tooltips
- `InlineImageHandler` — singleton parsing and displaying iTerm2 inline image protocol sequences
- `TerminalCursorLineView` — NSView overlay for cursor line highlighting with context line support
- `TerminalHighlightView` — NSView overlay drawing search and selection highlights

## Dependencies

- **Uses:** Terminal/Session (CommandBlockManager), Terminal/Views (TerminalViewProtocol), Settings
- **Used by:** Terminal/Views (TerminalViewRepresentable), Overlay

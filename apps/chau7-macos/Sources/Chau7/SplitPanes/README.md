# SplitPanes

Tree-based split pane layout with terminal and text editor pane types.

## Files

| File | Purpose |
|------|---------|
| `SplitPaneController.swift` | Manages the split pane tree (horizontal/vertical splits, focus, resize, close) |
| `SplitPaneViews.swift` | SwiftUI views rendering the recursive split pane tree with draggable dividers |

## Key Types

- `SplitPaneController` — ObservableObject managing a tree of `SplitNode` with focus tracking
- `SplitNode` — recursive enum representing terminal, text editor, or split container nodes
- `SplitDirection` — horizontal (side by side) or vertical (stacked) split orientation

## Dependencies

- **Uses:** Terminal/Session (TerminalSessionModel), Editor
- **Used by:** Overlay

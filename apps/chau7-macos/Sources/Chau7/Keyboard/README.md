# Keyboard

Clipboard history, Kitty keyboard protocol, and paste escaping utilities.

## Files

| File | Purpose |
|------|---------|
| `ClipboardHistoryManager.swift` | Polls the system clipboard and maintains a history of copied text with pinning |
| `KittyKeyboardHandler.swift` | Bridges macOS NSEvent key events to the Kitty keyboard protocol encoding |
| `PasteEscaper.swift` | Escapes shell-sensitive characters in pasted text to prevent injection |

## Key Types

- `ClipboardHistoryManager` — singleton ObservableObject tracking clipboard changes with LRU history
- `KittyKeyboardHandler` — encodes key events per the Kitty keyboard protocol flags
- `PasteEscaper` — static utility escaping backslashes, quotes, dollar signs, and backticks

## Dependencies

- **Uses:** Logging, Settings
- **Used by:** Terminal/Session, Overlay, Settings/Views

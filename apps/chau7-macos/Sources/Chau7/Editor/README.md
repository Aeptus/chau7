# Editor

IDE-like text editor with syntax highlighting, line numbers, and find/replace.

## Files

| File | Purpose |
|------|---------|
| `EditorLanguage.swift` | Language definitions with regex-based highlighting rules for multiple languages |
| `EditorScrollView.swift` | Custom NSScrollView hosting the editor text view with a line number gutter |
| `EnhancedEditorView.swift` | NSViewRepresentable wrapping NSTextView with IDE features (line numbers, bracket matching) |
| `SyntaxHighlighter.swift` | Cached syntax highlighting engine for terminal output with LRU cache |

## Key Types

- `EnhancedEditorView` — SwiftUI-bridged text editor used in split panes for file editing
- `EditorLanguage` — language definition struct with regex patterns for syntax coloring
- `SyntaxHighlighter` — singleton providing cached syntax highlighting for terminal lines

## Dependencies

- **Uses:** Settings (EditorConfig), Logging
- **Used by:** SplitPanes, Settings/Views

# Editor

Swift: `apps/chau7-macos/Sources/Chau7/Editor/` (4 files, 1083 lines), plus `Settings/EditorConfig.swift` and `Settings/Views/EditorSettingsView.swift`
Swift tests: `EditorLanguageTests`, `SyntaxHighlighterTests` (both in `Tests/Chau7Tests/Editor/SyntaxHighlighterTests.swift`)
Wave: 4
Depends on: SplitPanes (the panes that would host it), Settings

Text highlighting and editing building blocks. `SyntaxHighlighter` colors terminal-style text (used by the file preview pane and the menu bar panel log), `SemanticOutputDetector` records command blocks for semantic search, and `EnhancedEditorView` is an IDE-like editor (line numbers, language highlighting, auto-indent, bracket matching) that no pane currently uses.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| EDT-001 | Output-style highlighting: numbers, quoted strings, file paths, URLs (when clickable URLs are on), JSON keys, git hashes and branch names, prompts, success / warning / error keywords (errors win); results cached (LRU) and available in batches or async | `Editor/SyntaxHighlighter.swift` (`SyntaxHighlighter`) | `SyntaxHighlighterTests` | chau7_next_core/src/editor/output_highlight.rs,chau7_next/src/panes/highlight.rs | done |  |
| EDT-002 | Setting: Syntax highlighting on/off (off returns plain text) | `Settings/FeatureSettings.swift` (`isSyntaxHighlightEnabled`), `Settings/Views/DisplaySettingsView.swift` | `SyntaxHighlighterTests` | chau7_next_core/src/editor/output_highlight.rs,chau7_next/src/panes/preview.rs,chau7_next/src/settings/appearance.rs | done |  |
| EDT-003 | Command blocks recorded from shell integration (command, start and end row, time, exit code) and searched by command text for the Find bar's semantic mode; error blocks listed separately | `Editor/SyntaxHighlighter.swift` (`SemanticOutputDetector`), `Terminal/Session/TerminalSessionModel+Search.swift` (`updateSemanticSearch`) |  | chau7_next_core/src/command_block.rs,chau7_next_core/src/editor/semantic.rs | done |  |
| EDT-004 | Language detection from the file extension: Swift, Python, JavaScript/TypeScript (js, jsx, ts, tsx), Shell (sh, bash, zsh, fish), JSON, YAML, TOML, Markdown, Go, Rust, Ruby, plain text (txt, log, anything unknown), case-insensitive | `Editor/EditorLanguage.swift` (`detect`) | `EditorLanguageTests` | chau7_next_core/src/editor/language.rs | done |  |
| EDT-005 | Language highlighting rules (keywords, types, strings, comments, numbers; some bold), reapplied 150 ms after the last edit | `Editor/EditorLanguage.swift` (`highlightingRules`), `Editor/EnhancedEditorView.swift` (`applySyntaxHighlighting`) | `EditorLanguageTests` | chau7_next_core/src/editor/language.rs,chau7_next/src/panes/highlight.rs | done |  |
| EDT-006 | Line number gutter whose width follows the line count (at least 3 places), absolute numbering. Swift's gutter class also has relative and hybrid modes, but nothing selects them (`lineNumberMode` is never set, no setting exists), so Swift always numbers absolutely; Chau7 Next does the same | `Editor/EditorScrollView.swift` (`LineNumberGutterView`) |  | chau7_next/src/panes/editor.rs | done | NSRulerView |
| EDT-007 | Find bar with incremental search inside the editor | `Editor/EnhancedEditorView.swift` (`usesFindBar`) |  | chau7_next/src/panes/editor.rs | done | NSTextFinder |
| EDT-008 | Tab inserts the configured indent (spaces or tab, tab size); Shift+Tab outdents the line | `Editor/EnhancedEditorView.swift` (`doCommandBy`, `handleOutdent`) |  | chau7_next_core/src/editor/text.rs,chau7_next/src/panes/editor.rs | done |  |
| EDT-009 | Auto-indent: a new line copies the previous line's leading whitespace | `Editor/EnhancedEditorView.swift` (`handleAutoIndent`) | `editor::text` tests (`newline_with_indent`) | chau7_next_core/src/editor/text.rs,chau7_next/src/panes/editor.rs | done |  |
| EDT-010 | Bracket matching: moving next to `()[]{}<>` flashes the matching bracket; jump to the matching bracket | `Editor/EnhancedEditorView.swift` (`highlightMatchingBracket`, `jumpToMatchingBracket`) |  | chau7_next_core/src/editor/text.rs,chau7_next/src/panes/editor.rs | done |  |
| EDT-011 | Word wrap on/off (off scrolls horizontally) | `Editor/EnhancedEditorView.swift` |  | chau7_next/src/panes/editor.rs | done |  |
| EDT-012 | Editor settings: font size (13), tab size (4), use spaces, word wrap, line numbers, auto-indent, bracket matching, highlight current line, minimap, theme; stored in UserDefaults `editor.config` | `Settings/EditorConfig.swift`, `Settings/Views/EditorSettingsView.swift` |  | chau7_next_core/src/editor/config.rs,chau7_next/src/settings/editor.rs,chau7_next/src/settings_window/editor.rs,chau7_next/src/panes/editor.rs | done |  |

| EDT-013 | Markdown source/live styling retains original text, updates spans without breaking selection/undo and supports session note/runbook headers | `Editor/MarkdownLiveStyler.swift`; `Editor/EnhancedEditorView.swift` |  | chau7_next/src/panes/editor.rs; chau7_next/src/panes/runbook.rs | partial |  |

## Notes

- **EDT-004 to EDT-012 are not reachable in the Swift app.**
  `EnhancedEditorView` is never instantiated: the editor pane
  (SPL-011) uses a plain `NSTextView` (`TextEditorContent`), and the file
  preview (SPL-018) uses `SyntaxHighlighter` (output-style), not
  `EditorLanguage`. The Editor settings tab still edits `EditorConfig`, which
  nothing reads. Decision (2026-10-10): port them as designed. Chau7 Next's
  editor pane is the IDE-style editor: the gpui-kit code editor with the
  Swift language rules as its highlighter, and every `EditorConfig` value
  applied (settings in `[next]` as `editor_*`, not UserDefaults).
- The minimap setting and "highlight current line" only change the caret
  color in Swift; there is no minimap drawing. Chau7 Next draws both (a
  minimap column of line bars that scrolls on click, and a current line
  band), and the accent caret goes with "highlight current line".
- Jump to matching bracket has no shortcut in Swift; Chau7 Next binds
  Cmd+Shift+\ (Ctrl+Shift+\ elsewhere) inside the editor pane, and Cmd+S
  saves the editor's file.
- EDT-001 is also used by `StatusBar/MainPanelView.swift` (menu bar panel log
  lines, together with JSON pretty-printing).
- EDT-003 (`SemanticOutputDetector`) is search infrastructure that happens to
  live in `SyntaxHighlighter.swift`; Rust already records OSC 133 command
  markers, which can feed it.

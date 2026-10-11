# Editor

Swift: `apps/chau7-macos/Sources/Chau7/Editor/` (4 files, 1083 lines), plus `Settings/EditorConfig.swift` and `Settings/Views/EditorSettingsView.swift`
Swift tests: `EditorLanguageTests`, `SyntaxHighlighterTests` (both in `Tests/Chau7Tests/Editor/SyntaxHighlighterTests.swift`)
Wave: 4
Depends on: SplitPanes (the panes that would host it), Settings

Text highlighting and editing building blocks. `SyntaxHighlighter` colors terminal-style text (used by the file preview pane and the menu bar panel log), `SemanticOutputDetector` records command blocks for semantic search, and `EnhancedEditorView` is the current reachable editor pane (line numbers, language highlighting, auto-indent, bracket matching and live Markdown source styling).

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

| EDT-013 | Markdown source/live styling retains original text, updates spans without breaking selection/undo and supports session note/runbook headers | `Editor/MarkdownLiveStyler.swift`; `Editor/EnhancedEditorView.swift` |  | chau7_next/src/panes/editor.rs; chau7_next/src/panes/editor/live_markdown.rs; chau7_next/src/panes/editor/native_markdown.rs; chau7_next_core/src/editor/live_markdown.rs; chau7_next/src/panes/runbook.rs | partial | Attribute-only source styles, incremental fence-aware parsing and scoped preview binding implemented; macOS native heading fonts and measured hanging indentation implemented; selected-window input/popup acceptance remains pending. |

| EDT-014 | Named editor autosave toggle, 2.5 s debounce, 2 s Auto-saved status and discard cancellation; automatic defaults for Next-owned plans/notes and stable owner-tab session note locator/UI | `SplitPanes/EditorAutoSaver.swift`; `SplitPanes/SplitPaneController.swift` | EditorAutoSaverTests | chau7_next/src/panes/editor.rs; chau7_next_core/src/editor/text.rs | done | 6943290c + coordinator e2cb9f62 complete isolated note attachment; 47 focused editor tests and strict macOS Clippy passed. Native UI acceptance remains unverified. |

| EDT-015 | Detect file modification on disk, reload clean editor; dirty editor warns File changed externally. Reload? and never silently overwrites newer content | `SplitPanes/SplitPaneController.swift`; `SplitPanes/SplitPaneViews.swift` |  | chau7_next/src/panes/editor.rs; chau7_next_core/src/editor/text.rs | done |  |

## Notes

- **EDT-004 to EDT-012 are reachable in current Swift.**
  `SplitPanes/SplitPaneViews.swift` now instantiates `EnhancedEditorView`.
  The original April inventory's unreachable note was stale. Next's
  gpui-kit editor applies the configured language rules and editor settings.
- **EDT-013 remains partial.** Markdown source styles now apply immediately
  as UTF-8 text decorations, preserving markers, selection and undo history.
  The parser carries fence state, restyles edited paragraphs with neighbors,
  and falls back to a full pass when an old or new fence delimiter changes.
  Source/preview uses `.md` and `.markdown` case insensitively, with scoped
  Cmd+Shift+P (Ctrl+Shift+P elsewhere); the existing note/runbook filename
  header and source buffer remain shared. GPUI's pinned `HighlightStyle`
  cannot vary font family, heading size or paragraph hanging indentation.
  macOS now mounts a real Rust AppKit `NSTextView`/`NSScrollView` only for the
  current source viewport. It applies all six heading sizes, body/code fonts
  and measured prefix hanging indentation, preserving native undo and
  selection. The widget is retained across preview toggles and detached for
  unmounted sources, GPUI prompts/dialogs/menus and workspace overlays. Native
  Tab/outdent/newline, find, bracket indication, checkbox glyph hit targets and
  line gutter are wired. The optional `markdown_native_attributes` example
  uses the production styler in a hidden owned AppKit window: H1 22.1pt at
  body13, task indent29.7324pt, unchanged text/selection, and preserved native
  user-insertion undo passed. File loads now open source by default, preserving
  the chosen preview mode on same-file reload. Explicit loads cancel stale
  native queued input, reset native undo even for identical file content and
  set the requested selection; pending native edits block external replacement.
  Existing Edit menu commands route only to the focused native surface.
  Content/dirty readers now observe pending native text immediately; save,
  autosave, append, preview and close drain edits/UTF-16 selection before
  using the GPUI mirror. A later coalesced signal cannot replace the saved
  or appended text; actions/focus remain ordered in their existing queue.
  Two actual GPUI regressions exercise the shared native pending queue without
  native UI (temporary-file save, fenced append, preview and late delivery);
  an additional pure queue test preserves focus/actions. All 406 app tests
  pass (one ignored); strict workspace/all-target release Clippy passes.
  Source-window keyboard/IME, selection, split
  resize and popup acceptance remain pending; keep partial until proven.
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

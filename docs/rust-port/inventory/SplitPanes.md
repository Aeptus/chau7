# SplitPanes

Swift: `apps/chau7-macos/Sources/Chau7/SplitPanes/` (5 files, 2476 lines), plus entry points in `Overlay/OverlayTabsModel.swift`, `App/AppDelegate.swift` (pane actions) and the "Panes" menu in `App/Chau7App.swift`
Swift tests: `SplitPaneControllerTests`, `SplitNodeTests`, `TextEditorModelTests`, `SplitEnumTests` (all in `Tests/Chau7Tests/SplitPanes/SplitPaneControllerTests.swift`)
Wave: 1 for terminal splits (SPL-001 to SPL-010), 4 for the other pane types (SPL-011 to SPL-023)
Depends on: Terminal, Editor (syntax highlighting for the file preview), Repository (git diff), Commands (Cmd-click into the editor)

Each tab holds a tree of panes split side by side or stacked. Besides terminals, a pane can be a plain text editor (with a markdown runbook mode that runs code blocks in the tab's terminal), a read-only file or image preview, or a git diff viewer.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SPL-001 | Split the focused pane side by side with a new terminal ("Split Horizontally", Cmd+D) | `SplitPanes/SplitPaneController.swift` (`splitWithTerminal(.horizontal)`) | `SplitPaneControllerTests` | `chau7_next/src/pane.rs` (`split(Axis::Horizontal)`), `chau7_next/src/actions/` (`SplitRight`) | done | |
| SPL-002 | Split the focused pane stacked top and bottom ("Split Vertically", Cmd+Opt+D) | `SplitPanes/SplitPaneController.swift` (`splitWithTerminal(.vertical)`) | `SplitPaneControllerTests` | `chau7_next/src/pane.rs`, `chau7_next/src/actions/` (`SplitDown`) | done | |
| SPL-003 | The new pane takes half of the focused pane and gets focus | `SplitPanes/SplitPaneController.swift` (`splitNode`) | `SplitPaneControllerTests` | `chau7_next/src/pane.rs` (`insert_split`) | done | |
| SPL-004 | Drag a divider to resize two panes (resize cursor on hover, divider turns accent-colored while dragging, each side kept between 10% and 90%) | `SplitPanes/SplitPaneViews.swift` (`SplitDivider`, `SplitContainerView`), `SplitPanes/SplitPaneController.swift` (`updateRatio`) | `SplitPaneControllerTests` | `chau7_next/src/pane.rs` (`set_ratio`, divider drag; no accent while dragging) | done | NSCursor |
| SPL-005 | Close the focused pane (Ctrl+Cmd+W); the last pane of a tab cannot be closed; focus moves to the first pane of the sibling subtree | `SplitPanes/SplitPaneController.swift` (`closeFocusedPane`, `removeNode`) | `SplitPaneControllerTests` | chau7_next/src/pane.rs | done |  |
| SPL-006 | Focus next / previous pane in tree order, wrapping around (Cmd+Opt+] / Cmd+Opt+[) | `SplitPanes/SplitPaneController.swift` (`focusNextPane`, `focusPreviousPane`) | `SplitPaneControllerTests` | `chau7_next/src/pane.rs` (`focus_step`) | done | |
| SPL-007 | Click inside a pane to focus it | `SplitPanes/SplitPaneViews.swift` (`onFocus`) | | `chau7_next/src/pane.rs` (`TerminalViewEvent::Focused`) | done | |
| SPL-008 | Setting: Split panes on/off (off blocks new terminal splits; editor panes still open) | `Settings/FeatureSettings.swift` (`isSplitPanesEnabled`), `Settings/Views/WindowsSettingsView.swift` | `SplitPaneControllerTests` | chau7_next/src/pane.rs,chau7_next/src/settings/terminal.rs | done |  |
| SPL-009 | Split layout restored on relaunch: tree shape, ratios, pane ids, each terminal's directory, editor file, preview file, diff file/directory/mode (terminal panes are saved in `session.json`; the editor, preview and diff leaves come with their panes in wave 4) | `SplitPanes/SplitPaneController.swift` (`SavedSplitNode`, `exportLayout`, `fromSavedNode`) | `SplitPaneControllerTests` | chau7_next/src/pane.rs,chau7_next/src/restore.rs,chau7_next/src/session_store.rs,chau7_next_core/src/session_restore.rs | done |  |
| SPL-010 | "Panes" menu listing every pane action with its shortcut (splits, editor, preview, diff, append selection, close pane, focus next/previous) | `App/Chau7App.swift` |  | chau7_next/src/actions/menus.rs,chau7_next/src/actions/keymap.rs | done |  |
| SPL-011 | Open a text editor pane beside the focused pane ("Open Text Editor", Cmd+Opt+E), empty "Untitled" | `SplitPanes/SplitPaneController.swift` (`splitWithTextEditor`, `TextEditorModel`), `SplitPanes/SplitPaneViews.swift` (`TextEditorPaneView`, `TextEditorContent`) | `SplitPaneControllerTests`, `TextEditorModelTests` | chau7_next/src/pane.rs,chau7_next/src/panes/editor.rs,chau7_next/src/workspace/panes.rs | done |  |
| SPL-012 | Editor pane: monospaced 12 pt plain-text editing with undo, smart quotes/dashes off; header with file name (click copies it, "Copied" flash), orange unsaved dot, Open File button, Save button (Save As panel for untitled), close button; spinner while loading | `SplitPanes/SplitPaneViews.swift` (`TextEditorPaneView`), `SplitPanes/SplitPaneController.swift` (`loadFile`, `save`, `saveAs`) | `TextEditorModelTests` | chau7_next/src/panes/editor.rs | done | NSSavePanel, NSPasteboard |
| SPL-013 | Closing an editor with unsaved, non-empty text asks Save / Don't Save / Cancel (Save on untitled shows Save As; cancelling keeps the pane) | `SplitPanes/SplitPaneViews.swift` (`attemptClose`) |  | chau7_next/src/panes/editor.rs,chau7_next/src/pane.rs | done | NSAlert |
| SPL-014 | Open a file in the editor at a line: reuses the first editor pane in the tab, otherwise splits a new one; scrolls to and selects the line start once loaded (used by Cmd-click, CMD-040) | `SplitPanes/SplitPaneController.swift` (`openFileInEditor`), `SplitPanes/SplitPaneViews.swift` (`scrollToLine`) | `SplitPaneControllerTests` | chau7_next/src/pane.rs,chau7_next/src/panes/editor.rs,chau7_next_core/src/editor/text.rs | done |  |
| SPL-015 | Append the terminal selection to the editor ("Append Selection to Editor", Cmd+Opt+Shift+E): trimmed, added on a new line, marks it unsaved; needs an open editor pane | `SplitPanes/SplitPaneController.swift` (`appendSelectionToEditor`, `appendText`), `Overlay/OverlayTabsModel.swift` | `TextEditorModelTests` | chau7_next/src/pane.rs,chau7_next/src/panes/editor.rs,chau7_next_core/src/editor/text.rs | done |  |
| SPL-016 | Markdown runbook headings/text/fences; only shell fences execute, per-block running/succeeded/failed state keyed by section and command | `SplitPanes/MarkdownRunbookView.swift`; `SplitPanes/RunbookCodeBlockTracker.swift` |  | chau7_next_core/src/editor/markdown.rs,chau7_next/src/panes/runbook.rs,chau7_next/src/panes/editor.rs | done |  |
| SPL-017 | Run All executes only shell fences in order and waits for actual matching command completion; stops if shell never reports completion after 60 s | `SplitPanes/RunbookCodeBlockTracker.swift`; `SplitPanes/SplitPaneController.swift` |  | chau7_next/src/panes/editor.rs,chau7_next/src/pane.rs | done |  |
| SPL-018 | File preview pane ("Open File Preview", Cmd+Opt+O): read-only text at the terminal font size with output-style syntax colors (EDT-001), find bar, scroll to a line; header with file type icon, name and close; reuses an existing preview pane; empty, loading and error states | `SplitPanes/FilePreviewPaneView.swift` (`FilePreviewPaneView`, `ReadOnlyEditorContent`), `SplitPanes/SplitPaneController.swift` (`FilePreviewModel`, `openFilePreview`) | `SplitPaneControllerTests` | chau7_next/src/panes/preview.rs,chau7_next/src/pane.rs | done | NSWorkspace (file icons) |
| SPL-019 | Image preview for png, jpg, jpeg, gif, svg, webp, ico, bmp, tiff, tif: fitted in a scroll view on a checkerboard, IMAGE badge, "Unable to decode image" fallback | `SplitPanes/FilePreviewPaneView.swift` (`ImagePreviewContent`) | `SplitPaneControllerTests` | chau7_next/src/panes/preview.rs | done | NSImage |
| SPL-020 | Diff viewer pane ("Open Diff Viewer", Cmd+Opt+Shift+D): opens the first file changed by the last AI command in the tab, else the first dirty file from `git status --porcelain`; reuses an existing diff pane | `App/AppDelegate.swift` (`openDiffViewerPane`), `SplitPanes/SplitPaneController.swift` (`DiffViewerModel`, `openDiffViewer`) | `SplitPaneControllerTests` | chau7_next/src/workspace/panes.rs,chau7_next/src/pane.rs,chau7_next/src/panes/diff.rs | done |  |
| SPL-021 | Diff display: hunk headers (blue), context lines with old and new line numbers, additions (green, new number) and deletions (red, old number), blank line between hunks, +N / -N counts in the header, find bar; "No changes" state | `SplitPanes/DiffViewerPaneView.swift` (`UnifiedDiffContent`), `SplitPanes/SplitPaneController.swift` (`parseUnifiedDiff`) | `SplitPaneControllerTests` | chau7_next_core/src/editor/diff.rs,chau7_next/src/panes/diff.rs,chau7_next/src/panes/highlight.rs | done |  |
| SPL-022 | Diff Working / Staged toggle (`git diff` vs `git diff --cached`) and Refresh; an empty working-tree diff falls back to the staged diff | `SplitPanes/DiffViewerPaneView.swift`, `SplitPanes/SplitPaneController.swift` (`loadDiff`, `toggleDiffMode`) | `SplitPaneControllerTests` | chau7_next_core/src/editor/diff.rs,chau7_next/src/panes/diff.rs | done |  |
| SPL-023 | Changed Files panel context menu: Open Diff, Preview File | `Debug/ChangedFilesPanel.swift` |  | chau7_next/src/panes/changed_files.rs | done |  |

| SPL-024 | Open and restore repository/dashboard pane kinds with headers/factory actions and dependency lifetime; existing diff/editor panes remain available | `SplitPanes/PaneFactoryRegistry.swift`; `SplitPanes/SplitPaneController.swift`; `SplitPanes/RepositoryPaneView.swift` | SplitPaneControllerTests | chau7_next/src/pane.rs; chau7_next/src/panes/repository.rs; chau7_next/src/panes/dashboard.rs; chau7_next_core/src/session_restore.rs | done |  |
| SPL-025 | Session notes attach Markdown companion files to AI session, derive correct repository/session location and persist without overwriting unrelated notes | `SplitPanes/SessionNoteCoordinator.swift`; `Chau7Core/SessionNoteFileStore.swift`; `Chau7Core/SessionNoteAttachmentLocator.swift` | SessionNoteFileStoreTests; SessionNoteAttachmentLocatorTests | chau7_next/src/panes/editor.rs; chau7_next/src/pane.rs; chau7_next_core/src/editor/session_note.rs | done | 6943290c isolated stable owner-tab notes plus coordinator e2cb9f62 three identity seams; descriptor-relative Unix creation and portable Windows guard. Native UI and Windows acceptance remain unverified. |
| SPL-026 | Runbook renders editable checkbox tasks, bullets, numbered lists and dividers; task toggles update original source and plan progress excludes code fences | `Chau7Core/MarkdownRunbookInfrastructure.swift`; `SplitPanes/MarkdownRunbookView.swift` | current_runbook_tests::tasks_toggle_source_and_ignore_fenced_examples | chau7_next_core/src/editor/markdown.rs; chau7_next/src/panes/runbook.rs; chau7_next/src/panes/editor.rs | done | |

| SPL-027 | Markdown editor header displays checked/total tasks only when tasks exist; source changes update the count and fenced examples do not count | `SplitPanes/SplitPaneViews.swift:315`; `SplitPanes/SplitPaneController.swift` | Markdown progress cache regression; actual native header paint transitions 1/2 to 2/2 at 9a4b5730 | chau7_next/src/panes/editor.rs; chau7_next_core/src/editor/markdown.rs; chau7_next/src/panes/editor/native_markdown/fixture.rs | done | NSTextView; cached progress is refreshed on text changes rather than parsed during header render. |

## Notes

- Swift's tree is binary (`.split(first, second, ratio)`). Rust's is n-ary
  (`Node::Split { children, ratios }`): splitting along the parent's axis
  inserts a sibling that takes half of the focused pane, which looks the same.
- Swift `SplitDirection.horizontal` means side by side and `.vertical` means
  stacked. Rust names them by result (Split Right / Split Down). Rust binds
  Split Down to Cmd+Shift+D, which in Swift opens the Data Explorer
  (DEX-001).
- `adjustRatio(delta:)` exists in Swift (clamped 0.1 to 0.9) but nothing
  binds it to a key, so it is not listed.
- Rust closes a pane when its shell exits if `close_on_exit` is set; Swift
  handles exit elsewhere (Terminal module).
- The editor pane uses a plain `NSTextView`, not `EnhancedEditorView`
  (Editor.md): no line numbers or language highlighting in the editor pane.
  Chau7 Next's editor pane has the designed IDE features (EDT-004 to
  EDT-012) and uses the editor font size setting (13 pt) instead of 12 pt.
- Ctrl+Cmd+W (Close Pane) on an editor with unsaved text asks Save / Don't
  Save / Cancel, like its close button; Swift closes it without asking.
- Saved layouts (`session.json`) store editor, preview and diff leaves as
  `{"type":"editor","id":..,"path":..}`, `{"type":"preview",..}` and
  `{"type":"diff","file":..,"directory":..,"mode":"workingTree"|"staged"}`.
- The diff runs git with the `:(top)` pathspec, so files from `git status`
  (relative to the repository root) also diff from a subdirectory.
- The runbook view opens automatically for `.md` files; it shows on load
  because `isMarkdownMode` follows the file path.
- `SavedSplitNode` decodes old saved layouts that lack the preview and diff
  fields (`testSavedSplitNodeDecodeOldFormatWithoutNewFields`).

## Current repository and dashboard factories

- SPL-024 now includes the real Dashboard pane variant, factory/subscription, focus and close events, editor companion routing, visible Open in Split action, reuse by repository scope and saved layout kind. Repository, diff, preview, editor and terminal variants remain available in the same tree.
- Dashboard layout regressions round-trip normal/empty/missing scopes and normalize duplicate IDs while preserving repository directories, editor paths and terminal identities. The Dashboard entity owns its cancellable diagnostic refresh timer; hidden tabs/windows do not trigger background repository refreshes, and the timer is independent of the window in which the pane was originally created.
- Native visual, cross-window drag and relaunch acceptance remains on the coordinator's isolated macOS checklist.

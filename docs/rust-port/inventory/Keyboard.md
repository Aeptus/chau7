# Keyboard

Swift: `apps/chau7-macos/Sources/Chau7/Keyboard/` (3 files, 284 lines)
Swift tests: `Keyboard/ClipboardHistoryManagerTests`, `Keyboard/PasteEscaperTests`, `Terminal/KittyKeyboardProtocolTests`, `Terminal/TerminalKeyPressTests`, `Terminal/OptionModifiedTextRoutingTests`, `Terminal/RustTerminalViewTextInputTests`, `Settings/KeybindingsManagerTests`
Wave: 1
Depends on: Terminal, Settings (custom shortcuts)

The module itself holds clipboard history, escaped paste and the Kitty keyboard
protocol bridge. This file also covers everything a person types: how keys
become terminal bytes (`RustBackend/RustTerminalView.swift`,
`Chau7Core/TerminalKeyPress.swift`), prompt history keys, and every default
keyboard shortcut (menus in `App/Chau7App.swift`, the key monitor in
`App/AppDelegate.swift`, `FeatureSettings.defaultShortcuts`), so that one file
answers "does this key do the same thing in Chau7 Next".

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| KBD-001 | Clipboard history records every clipboard change, including copies made in other apps (polled every second), newest first, a repeated text moves to the top | `Keyboard/ClipboardHistoryManager.swift` | `ClipboardHistoryManagerTests` | `chau7_next_core/src/input/clipboard_history.rs`, `chau7_next/src/workspace/app_data.rs`, `chau7_next/src/workspace/pickers.rs` (polled every second; NSPasteboard change count via `platform/pasteboard.rs`, clipboard text compared elsewhere) | done | NSPasteboard |
| KBD-002 | Clipboard history settings: on/off (stops polling), max items 1 to 1,000; pinned items survive trimming | `Keyboard/ClipboardHistoryManager.swift` | `ClipboardHistoryManagerTests` (testTrimToMaxItems, testPinnedItemsSurviveTrim) | `chau7_next/src/settings/productivity.rs` (`[next] clipboard_history`, `clipboard_history_max`), `chau7_next_core/src/input/clipboard_history.rs`, `chau7_next/src/workspace/app_data.rs`, `chau7_next/src/workspace/pickers.rs` | done |  |
| KBD-003 | Pin and unpin an item, remove one item, clear all unpinned items | `Keyboard/ClipboardHistoryManager.swift` | `ClipboardHistoryManagerTests` (testTogglePin, testRemove, testClear) | `chau7_next_core/src/input/clipboard_history.rs`, `chau7_next/src/workspace/app_data.rs`, `chau7_next/src/workspace/pickers.rs` | done |  |
| KBD-004 | Clipboard history survives restarts | `Keyboard/ClipboardHistoryManager.swift` (UserDefaults `clipboard.history`) |  | `chau7_next_core/src/input/clipboard_history.rs`, `chau7_next/src/workspace/app_data.rs`, `chau7_next/src/workspace/pickers.rs` (`DataRoot::clipboard_history_file`) | done |  |
| KBD-005 | Clipboard history panel with search and 60-char previews; choosing an item puts it on the clipboard, moves it to the top and pastes it | `Keyboard/ClipboardHistoryManager.swift`, `Overlay/OverlayTabsModel.swift` (`pasteFromClipboardHistory`) | `ClipboardHistoryManagerTests` (testPaste, testPreview) | `chau7_next_core/src/input/clipboard_history.rs`, `chau7_next/src/workspace/app_data.rs`, `chau7_next/src/workspace/pickers.rs` | done |  |
| KBD-006 | Paste uses bracketed paste markers when the program enabled mode 2004 | `RustBackend/RustTerminalView.swift` (`pasteText`) | | `chau7_next_core/src/key_encoding.rs` (`encode_paste`), `chau7_next/src/terminal/view.rs` (`paste`) | done | |
| KBD-007 | Paste Escaped: clipboard text with backslash, single and double quotes, dollar, backtick and exclamation mark escaped by a backslash (menu, context menu, Cmd+Opt+V) | `Keyboard/PasteEscaper.swift`, `App/AppDelegate.swift` (`pasteEscaped`) | `PasteEscaperTests` | `chau7_next_core/src/input/paste_escaper.rs`, `chau7_next/src/terminal/input.rs`, `chau7_next/src/actions/menus.rs` | done |  |
| KBD-008 | Typing or pasting scrolls back to the live screen | `RustBackend/RustTerminalView.swift` (`send(data:)`) | | `chau7_next/src/terminal/view.rs` (`write_without_broadcast`) | done | |
| KBD-009 | AutoFill from Passwords (Edit menu) inserts a saved password into the shell | `App/AppDelegate.swift` (`autofillFromPasswords`), `RustBackend/RustTerminalView.swift` (`insertText`) |  | `chau7_next/src/platform/autofill.rs`, `chau7_next/src/terminal/input.rs` (`replace_text_in_range`) | done | Password AutoFill (NSTextInputClient) |
| KBD-010 | Cursor and editing keys: arrows, Home/End, PageUp/Down, Insert (Help key), Forward Delete, F1 to F12 with xterm modifier parameters; arrows follow application cursor mode (DECCKM) | `RustBackend/RustTerminalView.swift` (`generateSpecialKeySequence`), `Chau7Core/TerminalKeyPress.swift` | `TerminalKeyPressTests` | `chau7_next_core/src/key_encoding.rs` (`encode_key`) | done | |
| KBD-011 | Control keys: Ctrl+letter, Ctrl+`[ \ ] ^ _ @ space`, Ctrl+2 to Ctrl+8; Ctrl+Opt adds ESC | `RustBackend/RustTerminalView.swift` (`controlCharacter`) | `TerminalKeyPressTests` | `chau7_next_core/src/key_encoding.rs` | done | |
| KBD-012 | Tab, Shift+Tab (CSI Z), Return (CR), Backspace (DEL; Ctrl+Backspace sends BS), Escape | `RustBackend/RustTerminalView.swift` (`generateSpecialKeySequence`) | `TerminalKeyPressTests` | `chau7_next_core/src/key_encoding.rs` | done | |
| KBD-013 | Option as Meta without a setting: Option+letter sends ESC+letter (Shift gives the uppercase letter), while Option+non-letter keys that type ASCII punctuation (Option+5 is `[` on AZERTY) send that character | `RustBackend/RustTerminalView.swift` (`generateTerminalSequence`), `Chau7Core/OptionModifiedTextRouting.swift` | `OptionModifiedTextRoutingTests` | `chau7_next_core/src/key_encoding.rs` (`option_types_text`), `chau7_next/src/terminal/view.rs` (`on_key_down`) | done |  |
| KBD-014 | Text input through the input method: IME composition, dead keys (`^` then `e` on a French keyboard), emoji picker; marked text shown and never sent twice | `RustBackend/RustTerminalView.swift` (`routeTextInputThroughInputContext`, `setMarkedText`, `insertText`) | `RustTerminalViewTextInputTests` | `chau7_next/src/terminal/view.rs` (`EntityInputHandler`, `marked_text`) | done | NSTextInputClient |
| KBD-015 | Cmd combinations never reach the shell | `RustBackend/RustTerminalView.swift` (`keyDown`) | | `chau7_next_core/src/key_encoding.rs` (`platform` modifier) | done | |
| KBD-016 | Kitty keyboard protocol (`CSI > flags u` push, pop, query; progressive enhancement encoding including key release) | `Keyboard/KittyKeyboardHandler.swift`, `Chau7Core/KittyKeyboardProtocol.swift` | `KittyKeyboardProtocolTests` | `chau7_next_core/src/input/kitty.rs`, `chau7_next/src/terminal/input.rs` (`on_key_down`, `on_key_up`), `chau7_terminal/src/rust_api.rs` (`set_kitty_keyboard`, `kitty_keyboard_flags`) | done |  |
| KBD-017 | Synthesized key presses (named key plus modifiers) (MCP `tab_press_key` and `tab_submit_prompt`; in Swift the scripting API and remote control send text, not key presses), encoded with the current cursor mode | `Chau7Core/TerminalKeyPress.swift`, `Terminal/Session/TerminalSessionModel.swift` (`sendKeyPress`) | `TerminalKeyPressTests` | `chau7_next_core/src/terminal_key_press.rs`, `chau7_next/src/pane.rs` (`send_key_press`), `chau7_next/src/mcp/tools/tabs.rs` | done |  |
| KBD-018 | Prompt history keys: at a shell prompt, Up/Down replace the line with this tab's earlier commands, Option+Up/Down with commands from all tabs; ignored in full-screen programs; key repeat does not re-insert the same line | `RustBackend/RustTerminalView.swift` (`handleHistoryKeyDown`), `Terminal/Session/CommandHistoryManager.swift` |  | `chau7_next_core/src/input/command_history.rs`, `chau7_next/src/terminal/input.rs` (`history_key`, `note_user_input`) | done |  |
| KBD-019 | Snippet placeholders: after inserting a snippet, Tab and Shift+Tab move between placeholders; any other key ends placeholder mode | `RustBackend/RustTerminalView.swift` (`handleSnippetKeyDown`) |  | `chau7_next_core/src/snippet_store.rs` (`Navigation`), `chau7_next/src/terminal/input.rs` (`insert_snippet`, `snippet_key`) | done |  |
| KBD-020 | Custom shortcuts: rebind actions in Settings, presets default / vim (Ctrl+H and Ctrl+L for tabs) / emacs (Ctrl+P and Ctrl+N), export and import as JSON; custom bindings win over terminal input | `Settings/KeybindingsManager.swift`, `Settings/FeatureSettings.swift` (`customShortcuts`, `defaultShortcuts`) | `KeybindingsManagerTests` | `chau7_next_core/src/input/shortcuts.rs`, `chau7_next/src/actions/keymap.rs`, `chau7_next/src/settings/input.rs`, `chau7_next/src/settings_window/shortcuts.rs` | done |  |
| KBD-021 | Bindable actions with no default key: toggle broadcast, clipboard history, bookmarks, add bookmark, interrupt (Ctrl+C), end of file (Ctrl+D), suspend (Ctrl+Z), clear line (Ctrl+U), clear word (Ctrl+W), fullscreen, select tab N | `Settings/KeybindingsManager.swift` (`KeyAction`, `executeAction`) | `KeybindingsManagerTests` | chau7_next/src/actions/keymap.rs (action_for_swift_name), chau7_next/src/terminal/input.rs (send_control), chau7_next/src/workspace/bookmarks.rs | done |  |
| KBD-022 | Cmd+T new tab | `App/Chau7App.swift` | `KeybindingsManagerTests` | `chau7_next/src/actions/` | done | |
| KBD-023 | Cmd+N new window | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-024 | Cmd+W close tab | `App/Chau7App.swift`, `App/AppDelegate.swift` (`closeTabFromShortcut`) | | `chau7_next/src/actions/` | done | |
| KBD-025 | Cmd+Shift+W close window | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-026 | Cmd+Opt+W close other tabs | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/workspace/keys.rs` (`close_other_tabs`) | done |  |
| KBD-027 | Cmd+Shift+T reopen closed tab | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-028 | Cmd+1 to Cmd+9 select tab, matched by physical key so it works on AZERTY and other layouts | `App/AppDelegate.swift` (`tabNumberForKeyCode`), `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (`bind_layout_keys`: GPUI key equivalents per layout) | done |  |
| KBD-029 | Cmd+Shift+] and Cmd+Shift+[ next and previous tab | `App/Chau7App.swift` | | `chau7_next/src/actions/` (`cmd-}`, `cmd-{`) | done | |
| KBD-030 | Ctrl+Tab and Ctrl+Shift+Tab next and previous tab | `App/AppDelegate.swift` (`handleKeyEvent`) |  | `chau7_next/src/actions/keymap.rs` | done |  |
| KBD-031 | Cmd+Opt+Right and Cmd+Opt+Left next and previous tab (while the tab shortcuts are not customized and no text field has focus) | `App/AppDelegate.swift` (`handleKeyEvent`, `shouldUseAlternateTabNavigationShortcuts`) |  | `chau7_next/src/actions/keymap.rs` (`bind_shortcut_settings`) | done |  |
| KBD-032 | Cmd+Opt+Shift+] and Cmd+Opt+Shift+[ move the tab right and left | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/workspace/keys.rs` (`move_selected_tab`) | done |  |
| KBD-033 | Cmd+Opt+R rename tab | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-034 | Cmd+Opt+Shift+R refresh tab bar (recovery) | `App/Chau7App.swift` | | | n/a | |
| KBD-035 | Cmd+C copies the selection, or sends Ctrl+C (interrupt) when nothing is selected | `App/AppDelegate.swift` (`copyOrInterrupt`), `RustBackend/RustTerminalView.swift` (`copy`) |  | `chau7_next/src/terminal/view.rs` (`copy`) | done |  |
| KBD-036 | Cmd+X copies (a terminal cannot cut) | `App/AppDelegate.swift` (`cut`) |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/terminal/input.rs` | done |  |
| KBD-037 | Cmd+V paste | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-038 | Cmd+Opt+V paste escaped | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/terminal/input.rs` (`paste_escaped`) | done |  |
| KBD-039 | Cmd+A selects the current command line (wrapped rows included); Cmd+A twice within 0.4 s selects the whole buffer | `App/AppDelegate.swift` (`selectAll`) |  | `chau7_next/src/terminal/input.rs` (`select_all`) | done |  |
| KBD-040 | Cmd+F find | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-041 | Cmd+G find next | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-042 | Cmd+Shift+G find previous | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-043 | Cmd+E use selection for find | `App/Chau7App.swift`, `App/AppDelegate.swift` (`useSelectionForFind`) |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/workspace/keys.rs`, `chau7_next/src/workspace/find.rs` (`search_for`) | done |  |
| KBD-044 | Escape closes the find bar, then the rename field | `App/AppDelegate.swift` (`handleKeyEvent`) | | `chau7_next/src/actions/` (`SearchBar` context), `chau7_next/src/workspace/` (rename) | done | |
| KBD-045 | Cmd+; and Cmd+Opt+S snippets | `Overlay/OverlayWindow.swift` (`performKeyEquivalent`), `Settings/FeatureSettings.swift` (`defaultShortcuts`) |  | `chau7_next/src/actions/keymap.rs` | done |  |
| KBD-046 | Cmd+Opt+P command palette | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+Shift+P kept too) | done |  |
| KBD-047 | Cmd+Shift+D data explorer | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs, chau7_next/src/app_actions.rs, chau7_next/src/data_explorer.rs | done |  |
| KBD-048 | Cmd+Ctrl+F full screen | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-049 | Cmd+= and Cmd+- zoom the tab's text in and out | `App/Chau7App.swift` |  | `chau7_next/src/workspace/font.rs` (selected tab only, 8 to 72 pt; Cmd++ also zooms in) | done |  |
| KBD-050 | Cmd+0 (and Cmd+à, the 0 key on AZERTY) actual size | `App/Chau7App.swift`, `Settings/FeatureSettings.swift` | | `chau7_next/src/actions/` (`cmd-0`) | done | |
| KBD-051 | Cmd+K clear screen (sends Ctrl+L, scrollback kept) | `App/Chau7App.swift`, `App/AppDelegate.swift` (`clearScreen`) |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/terminal/input.rs` (`clear_screen`) | done |  |
| KBD-052 | Cmd+Opt+K clear scrollback | `App/Chau7App.swift`, `Settings/FeatureSettings.swift` |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/terminal/input.rs` (`clear_scrollback`) | done |  |
| KBD-053 | Cmd+Up and Cmd+Down scroll to the previous and next command prompt | `App/Chau7App.swift`, `RustBackend/RustTerminalView.swift` (`scrollToPreviousInputLine`) |  | `chau7_next_core/src/input/input_lines.rs`, `chau7_next/src/actions/keymap.rs`, `chau7_next/src/terminal/input.rs` (`jump_input_line`) | done |  |
| KBD-054 | Cmd+D split side by side | `App/Chau7App.swift` | | `chau7_next/src/actions/` (`SplitRight`) | done | |
| KBD-055 | Cmd+Opt+D split stacked | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` | done |  |
| KBD-056 | Cmd+Ctrl+W close pane | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` | done |  |
| KBD-057 | Cmd+Opt+] and Cmd+Opt+[ focus next and previous pane | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` (Cmd+] and Cmd+[ kept too) | done |  |
| KBD-058 | Cmd+Opt+E open text editor pane | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs,chau7_next/src/panes/mod.rs | done |  |
| KBD-059 | Cmd+Opt+O open file preview pane | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs,chau7_next/src/panes/mod.rs | done |  |
| KBD-060 | Cmd+Opt+Shift+D open diff viewer pane | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs,chau7_next/src/panes/mod.rs | done |  |
| KBD-061 | Cmd+Opt+Shift+E append selection to editor | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs,chau7_next/src/panes/mod.rs | done |  |
| KBD-062 | Cmd+Opt+G show changed files | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs,chau7_next/src/panes/mod.rs | done |  |
| KBD-063 | Cmd+Shift+O SSH connections | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs` | done |  |
| KBD-064 | Cmd+Shift+S export terminal text to a file | `App/Chau7App.swift`, `App/AppDelegate.swift` (`exportText`) |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/workspace/keys.rs` (`export_text`) | done | NSSavePanel |
| KBD-065 | Cmd+P print the terminal | `App/Chau7App.swift`, `App/AppDelegate.swift` (`printTerminal`) |  | `chau7_next/src/platform/print.rs`, `chau7_next/src/workspace/keys.rs` (`print_terminal`): prints the visible text in the terminal font (GPUI has no printable NSView) | done | NSPrintOperation |
| KBD-066 | Cmd+, settings | `App/Chau7App.swift` | | `chau7_next/src/actions/` | done | |
| KBD-067 | Cmd+/ keyboard shortcuts help | `App/Chau7App.swift` |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/settings_window/shortcuts.rs` | done |  |
| KBD-068 | Cmd+Opt+I report issue | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs, chau7_next/src/debug/mod.rs, chau7_next/src/debug/report_window.rs | done |  |
| KBD-069 | Cmd+Opt+L debug console | `App/Chau7App.swift` |  | chau7_next/src/actions/keymap.rs, chau7_next/src/debug/mod.rs | done |  |
| KBD-070 | Standard app menu keys: Cmd+Q quit, Cmd+M minimize, Cmd+H hide, Cmd+Opt+H hide others | `App/Chau7App.swift` (SwiftUI default app menu) |  | `chau7_next/src/actions/keymap.rs`, `chau7_next/src/workspace/keys.rs`, `chau7_next/src/actions/menus.rs` | done |  |

## Notes

- **Where Swift shortcuts live.** Three dispatch paths, checked in this order:
  `OverlayWindow.performKeyEquivalent` (only Cmd+;), the SwiftUI menu
  (`Chau7App.swift` `.commands`), then the `AppDelegate` local key monitor
  (Cmd+1..9 by key code, Escape, custom bindings from `KeybindingsManager` when
  no menu item owns the key, Ctrl+Tab, Cmd+Opt+arrows). Prompt history keys
  and snippet placeholder keys are separate local monitors installed by
  `RustTerminalView`.
- **Default custom shortcuts** (`FeatureSettings.defaultShortcuts`, action
  names as stored): newTab cmd+t, closeTab cmd+w, find cmd+f, findNext cmd+g,
  copy cmd+c, paste cmd+v, newWindow cmd+n, zoomIn cmd+=, zoomOut cmd+-,
  zoomReset cmd+0, nextTab cmd+shift+], previousTab cmd+shift+[, findPrevious
  cmd+shift+g, clear cmd+opt+k, snippets cmd+opt+s, renameTab cmd+opt+r,
  debugConsole cmd+opt+l, splitHorizontal cmd+d, splitVertical cmd+opt+d,
  openTextEditor cmd+opt+e, previousInputLine cmd+up, nextInputLine cmd+down,
  refreshTabBar cmd+opt+shift+r.
- **Two naming schemes.** Swift stores custom shortcuts with "shortcut action"
  names (`find`, `findNext`, `findPrevious`, `snippets`, `clear`, ...) and maps
  them to `KeyAction` raw values (`toggleSearch`, `nextMatch`, `previousMatch`,
  `showSnippets`, ...) in `KeyAction.fromShortcutAction`. Chau7 Next accepts
  both (`shortcuts::canonical_action`). Its keymap maps `debugConsole`,
  `openTextEditor`, `showChangedFiles`, `showBookmarks` and `addBookmark`.
  `refreshTabBar` is the remaining excluded action; it belongs to SwiftUI's
  tab-bar recovery UI (KBD-034, n/a in Next).
- **Split naming.** In Swift `splitHorizontal` means side by side
  (`SplitDirection.horizontal`, Cmd+D) and `splitVertical` means stacked;
  `action_for_swift_name` follows that (fixed, it used to be reversed).
- **Rust-only shortcuts:** Cmd+Shift+H command history, Cmd+Shift+Alt+D demo
  tabs (debug), Cmd++ (zoom in), Cmd+] / Cmd+[ (focus pane), Cmd+Shift+P
  (command palette, also on Cmd+Opt+P).
- **Custom shortcuts** (`[keybindings]`, preset in `[next] keybinding_preset`)
  are bound on top of the defaults when settings load or change. GPUI cannot
  remove one binding, so a removed custom shortcut keeps working until the app
  restarts; a changed one takes effect at once.
- **Prompt history and echo.** Swift skips recording a command when the PTY
  has echo off (`isPtyEchoDisabled`), but line editors (readline, zle) also
  turn echo off while editing, so Swift rarely records at a shell prompt.
  Chau7 Next treats only echo off in canonical mode as a password prompt
  (`Chau7Terminal::is_password_input`), and seeds the global (Option+Up)
  history from the shell integration's history file.
- **Option as Meta.** Swift has no setting. Its rule
  (`OptionModifiedTextRouting`): Option with a letter key is Meta; Option with
  a non-letter key that produces one printable ASCII character is literal text.
  Chau7 Next follows it (`key_encoding::option_types_text`); the old
  `[next] option_as_meta` setting is gone.
- **Small encoding differences** (Chau7 Next is closer to xterm, keep it):
  Home/End use SS3 in application cursor mode; Alt+Enter, Alt+Tab and
  Alt+Backspace get an ESC prefix; Ctrl+- sends 0x1f; pasted newlines become CR.
- **Kitty keyboard protocol.** `KittyKeyboardHandler` is never instantiated
  in Swift. Chau7 Next turns on the emulator's own flag stack
  (`Chau7Terminal::set_kitty_keyboard`, Rust callers only, so Swift is
  unchanged) and encodes keys in `chau7_next_core::input::kitty`.
- **Minimal mode shortcut.** Settings advertise Cmd+Shift+M for minimal mode
  but no menu item or monitor binds it (see Appearance.md APR-008).
- **n/a row.** KBD-034 recovers from a SwiftUI tab bar rendering glitch that
  the GPUI tab bar does not have.
- **Clipboard polling** (KBD-001) needs a platform pasteboard change counter
  (`NSPasteboard.changeCount` on macOS); put it behind a trait with a stub
  elsewhere.

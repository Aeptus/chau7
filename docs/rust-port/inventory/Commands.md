# Commands

Swift: `apps/chau7-macos/Sources/Chau7/Commands/` (4 files, 1333 lines), plus Cmd-click handling in `RustBackend/RustTerminalView.swift` (`handleCmdClick`), dangerous-command highlighting in `Terminal/Session/TerminalSessionModel+ShellIntegration.swift` and settings in `Settings/Views/DangerousCommandSettingsView.swift`
Swift tests: `DangerousCommandGuardTests`, `PathClickHandlerTests` (plus Chau7Core `CommandRiskDetection` tests)
Wave: 1
Depends on: Settings, SplitPanes (Cmd-click into the editor pane), Snippets (palette entries)

The command palette (a searchable list of every app action), the dangerous-command highlight and guard, and Cmd-click on URLs and file paths in terminal output.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| CMD-001 | Command palette opens from the menu or shortcut as a floating panel at the top center of the screen, search field focused; toggling again closes it; it hides when it stops being active (Swift: when the app deactivates) | `Commands/CommandPalette.swift` (`CommandPaletteController`) |  | chau7_next/src/workspace/palette_window.rs, chau7_next/src/actions/ | done | NSPanel |
| CMD-002 | Palette search matches the command title or its category name; selection resets to the top on each keystroke | `Commands/CommandPalette.swift` (`filteredCommands`) |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-003 | Up/Down move the selection (list scrolls to keep it centered), Return or click runs the command after the palette closes, Esc closes | `Commands/CommandPalette.swift` (`CommandPaletteSearchField`, `executeSelected`) |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-004 | Palette rows show an icon, the category and the shortcut; footer shows "N commands" and key hints | `Commands/CommandPalette.swift` (`CommandRow`, `KeyHint`) |  | chau7_next/src/workspace/pickers/palette.rs (PaletteIcon), chau7_next/src/workspace/pickers.rs, chau7_next/src/assets.rs | done |  |
| CMD-005 | Palette: New Window, New Tab, Reopen Closed Tab | `Commands/CommandPalette.swift` (`buildCommands`) | | `chau7_next/src/workspace/` (`command_list`) | done | |
| CMD-006 | Palette: Close Tab, Close Window | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs,chau7_next/src/commands.rs | done |  |
| CMD-007 | Palette: Close Other Tabs (Opt+Cmd+W) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/extras.rs,chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-008 | Palette: Export Text... (Shift+Cmd+S, saves the buffer) and Print... (Cmd+P) | `Commands/CommandPalette.swift`, `App/AppDelegate.swift` (`exportText`, `printTerminal`) |  | `chau7_next/src/workspace/keys.rs` (`export_text`, `print_terminal`), `chau7_next/src/workspace/pickers/palette.rs` | done | NSSavePanel, NSPrintOperation |
| CMD-009 | Palette: Cut, Copy, Paste, Select All | `Commands/CommandPalette.swift` |  | `chau7_next/src/terminal/input.rs` (copy, cut, paste, select all), `chau7_next/src/workspace/pickers/palette.rs` | done |  |
| CMD-010 | Palette: Paste Escaped (Opt+Cmd+V, clipboard pasted shell-escaped) | `Commands/CommandPalette.swift`, `App/AppDelegate.swift` (`pasteEscaped`) |  | `chau7_next/src/terminal/input.rs` (`paste_escaped`), `chau7_next_core/src/input/paste_escaper.rs` | done |  |
| CMD-011 | Palette: Find..., Find Next, Find Previous | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-012 | Palette: Use Selection for Find (Cmd+E) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/extras.rs,chau7_next/src/workspace/find.rs | done |  |
| CMD-013 | Palette: Snippets... | `Commands/CommandPalette.swift` | | `chau7_next/src/workspace/` | done | |
| CMD-014 | Palette: Manage Snippets..., Migrate Snippets to Clean JSON, Reload Snippets (see SNP-014, SNP-015, SNP-028) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs,chau7_next/src/workspace/pickers.rs | done |  |
| CMD-015 | Palette: Toggle Full Screen, Zoom In, Zoom Out, Actual Size | `Commands/CommandPalette.swift` | | `chau7_next/src/workspace/` | done | |
| CMD-016 | Palette: Open Text Editor, Append Selection to Editor (see SPL-011, SPL-015) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs,chau7_next/src/workspace/panes.rs | done |  |
| CMD-017 | Palette: Split Horizontal, Split Vertical, Close Pane | `Commands/CommandPalette.swift` | | `chau7_next/src/workspace/` ("Split Right", "Split Down", "Close Pane") | done | |
| CMD-018 | Palette: Focus Next Pane, Focus Previous Pane | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-019 | Palette: Clear Screen (Cmd+K) and Clear Scrollback (Shift+Cmd+K) as two commands | `Commands/CommandPalette.swift` |  | `chau7_next/src/terminal/input.rs` (`clear_screen`, `clear_scrollback`), `chau7_next/src/workspace/pickers/palette.rs` | done |  |
| CMD-020 | Palette: Scroll to Top, Scroll to Bottom | `Commands/CommandPalette.swift` |  | `chau7_next/src/pane.rs` (ScrollToTop, ScrollToBottom), `chau7_next/src/workspace/pickers/palette.rs` | done |  |
| CMD-021 | Palette: Previous Input Line / Next Input Line (Cmd+Up / Cmd+Down jump between prompts) | `Commands/CommandPalette.swift`, `App/AppDelegate.swift` (`scrollToPreviousInputLine`) |  | chau7_next/src/workspace/pickers/palette.rs, chau7_next/src/terminal/input.rs (jump_input_line) | done |  |
| CMD-022 | Palette: Show Next Tab, Show Previous Tab, Select Tab 1 to 9 | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-023 | Palette: Move Tab Right, Move Tab Left (Shift+Opt+Cmd+] / [) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/extras.rs | done |  |
| CMD-024 | Palette: Rename Tab... | `Commands/CommandPalette.swift` | | `chau7_next/src/workspace/` | done | |
| CMD-025 | Palette: Force Refresh Tab | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/extras.rs | done |  |
| CMD-026 | Palette: Settings... | `Commands/CommandPalette.swift` | | `chau7_next/src/workspace/` | done | |
| CMD-027 | Palette: (dev) Debug Console (Shift+Cmd+L) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs | done |  |
| CMD-028 | Palette: SSH Connections... (Shift+Cmd+O, opens the SSH manager, see PRO-006) | `Commands/CommandPalette.swift` |  | chau7_next/src/profiles/ssh_manager.rs,chau7_next/src/commands.rs | done |  |
| CMD-029 | Palette: Keyboard Shortcuts... (Cmd+/) | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs, chau7_next/src/workspace/keys.rs | done |  |
| CMD-030 | Palette: About Chau7, Documentation, Report Issue | `Commands/CommandPalette.swift` |  | chau7_next/src/workspace/pickers/palette.rs, chau7_next/src/debug/report_window.rs | done | NSWorkspace |
| CMD-031 | Dangerous command highlight: terminal rows whose text matches a risky pattern are tinted red (50% system red), including commands typed at the prompt | `Terminal/Session/TerminalSessionModel+ShellIntegration.swift` (`dangerousRowTints`, `recordDangerousCommandLineIfNeeded`), `Chau7Core/CommandRiskDetection.swift` | `CommandRiskDetection` tests | `chau7_next/src/terminal/view.rs` (`dangerous_rows`), `chau7_next_core/src/command_risk.rs` | done | |
| CMD-032 | Setting: Highlight scope Disabled / AI Outputs Only (only while an AI CLI runs in the tab) / All Outputs | `Settings/Views/DangerousCommandSettingsView.swift`, `Settings/FeatureSettings.swift` (`dangerousCommandHighlightScope`) |  | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| CMD-033 | Setting: edit the risky pattern list (add, edit, remove; matching is case-insensitive, whitespace-normalized substring) | `Settings/Views/DangerousCommandSettingsView.swift` (`patternListSection`), `Settings/FeatureSettings.swift` (`dangerousCommandPatterns`) |  | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| CMD-034 | Guard on Enter: a risky command (pattern match, Cyrillic/fullwidth homoglyphs, or multi-line paste) shows a confirmation (Execute / Cancel / Always Allow, "Do not warn for this command again") before the keystroke reaches the shell; block-listed commands are refused; allow-listed (global or per directory) pass | `Commands/DangerousCommandGuard.swift`, `Commands/DangerousCommandConfirmationView.swift` | `DangerousCommandGuardTests` | chau7_next/src/terminal/view/guard.rs,chau7_next/src/terminal/command_guard.rs,chau7_next_core/src/guard_line.rs | done | NSAlert |
| CMD-035 | Guard settings: enable switch, allow list (view, remove, clear), block list (add, remove, clear), reset to defaults | `Settings/Views/DangerousCommandSettingsView.swift`, `Commands/DangerousCommandGuard.swift` | `DangerousCommandGuardTests` | chau7_next/src/settings_window/mine/dangerous.rs | done |  |
| CMD-036 | Cmd-click a URL: OSC 8 hyperlink first, else a plain `http`, `https`, `file`, `ssh`, `ftp` or `sftp` URL under the pointer, matched across the wrapped logical line | `RustBackend/RustTerminalView.swift` (`handleCmdClick`, `findURLs`), `Utilities/RegexPatterns.swift` |  | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done | NSWorkspace |
| CMD-037 | Setting: URL handler (open links in a chosen browser instead of the system default) | `Commands/PathClickHandler.swift` (`openURL`), `Settings/FeatureSettings.swift` (`urlHandler`) |  | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done | NSWorkspace |
| CMD-038 | Holding Cmd over a clickable URL or path shows the pointing-hand cursor | `RustBackend/RustTerminalView.swift` (cursor update on mouse move) |  | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done | NSCursor |
| CMD-039 | Cmd-click a file path (absolute, `~`, or relative to the tab directory, with optional `:line:column`) opens it when the file exists | `Commands/PathClickHandler.swift` (`findPaths`, `resolvePath`), `RustBackend/RustTerminalView.swift` | `PathClickHandlerTests` | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done |  |
| CMD-040 | Cmd-clicked file opens in the internal editor pane at that line (setting "Cmd+click opens internal editor", default on; see SPL-014) | `RustBackend/RustTerminalView.swift`, `SplitPanes/SplitPaneController.swift` (`onFilePathClicked`) |  | chau7_next/src/terminal/links.rs,chau7_next/src/terminal/mouse.rs,chau7_next/src/pane.rs | done |  |
| CMD-041 | External editor for Cmd-clicked files: the "Default editor" setting or `$EDITOR`, with line jump for code/subl (`--goto f:l:c`), vim/nvim (`+l`), emacs (`+l:c`); with no editor set, code/subl/atom from `/usr/local/bin`, `/opt/homebrew/bin` or `/usr/bin` when a line is given, else the system default app | `Commands/PathClickHandler.swift` (`openPath`) | `PathClickHandlerTests` | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done | NSWorkspace |
| CMD-042 | Setting: Cmd-click paths and URLs on/off | `Settings/FeatureSettings.swift` (`isCmdClickPathsEnabled`) |  | chau7_next/src/terminal/links.rs,chau7_next_core/src/link_detect.rs | done |  |

## Notes

- **CMD-034 is not wired in Swift.** `DangerousCommandGuard.check` and
  `DangerousCommandConfirmationView` are only used by tests and the settings
  view; nothing calls them from the Enter key path, although the settings text
  says a dialog appears. Rust ports the check logic
  (`command_risk::DangerousCommandGuard`). The user should decide whether the
  guard is wanted before anyone builds UI for it.
- Swift highlight: input rows are recorded when a command is submitted, output
  rows are scanned with debounce and cached (with a low-power mode that limits
  how many rows are scanned). Rust scans every visible row each frame with a
  per-text cache, which gives the same picture for "All Outputs".
- Guard persistence (UserDefaults): `feature.dangerousCommandGuard`,
  `dangerousGuard.allowList`, `dangerousGuard.blockList`,
  `dangerousGuard.directoryAllowLists` (JSON `{dir: [commands]}`).
- Path regex (`RegexPatterns.filePath`): needs an extension
  (`name.ext`), optional leading `/` or `.`, optional `:line` and `:col`.
- Shortcut differences: palette is Cmd+Opt+P in the Swift menu (the release
  notes say Shift+Cmd+P), Rust uses Cmd+Shift+P (Ctrl+Shift+Space off macOS).
  Swift Cmd+K is Clear Screen; Rust Cmd+K clears scrollback.
- Rust-only palette entries (keep them): Open config.toml, Reload Settings,
  Clipboard History, Command History, Toggle Broadcast Input, Load Demo Tabs.

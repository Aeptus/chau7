# RustBackend

Swift: `apps/chau7-macos/Sources/Chau7/RustBackend/` (5 files, 6713 lines)
Swift tests: `Terminal/RustTerminalViewTextInputTests.swift`, `Terminal/OptionModifiedTextRoutingTests.swift`, `Terminal/TerminalKeyPressTests.swift`, `Terminal/RustAnsiParserTests.swift`, `Keyboard/PasteEscaperTests.swift`, `Commands/PathClickHandlerTests.swift`, `Remote/RemoteTerminalGridSnapshotTests.swift`
Wave: 1
Depends on: none

The terminal view of the Swift app: it loads the shared `chau7_terminal`
emulator through its C API, runs the shell in a PTY, polls it at the display
refresh rate, draws the grid (CPU renderer `RustGridView`, or hands it to the
Metal renderer in Performance), and turns keyboard, mouse, clipboard, drag and
drop and IME input into PTY bytes. Most of what a user touches inside a tab
lives here.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| RBK-001 | New tab starts the configured shell in a PTY with the session environment, sized to the view on first layout | `RustBackend/RustTerminalView.swift` (`startTerminal`, `RustTerminalFFI.init`) | | `chau7_next/src/terminal/session.rs` (`spawn`) | done | |
| RBK-002 | Resizing the window or pane resizes the PTY and the emulator reflows wrapped lines | `RustBackend/RustTerminalView.swift` (`layout`) | | `chau7_next/src/terminal/view.rs` (canvas prepaint), `chau7_next/src/terminal/session.rs` (`resize`) | done | |
| RBK-003 | New output shows up within one frame: output is polled at the display refresh rate (CVDisplayLink, timer fallback at the screen's max FPS) | `RustBackend/RustTerminalView.swift` (`setupPollingLoop`, `pollAndSync`) | | `chau7_next/src/terminal/session.rs` (poll thread, coalesced `refresh`) | done | CVDisplayLink |
| RBK-004 | Background tabs keep draining the PTY (every 500 ms) so the shell never blocks, and still report bell, title and exit; an activated tab syncs immediately | `RustBackend/RustTerminalView.swift` (`notifyUpdateChanges`, `backgroundDrain`, `resumeDisplayLink`) | | `chau7_next/src/terminal/session.rs` (poll thread runs for every session) | done | |
| RBK-005 | Window/tab title set by programs (OSC 0/1/2) | `RustBackend/RustTerminalView.swift` (`getPendingTitle`, `onTitleChanged`) | | `chau7_next/src/terminal/session.rs` (`take_pending_title`) | done | |
| RBK-006 | Current directory follows OSC 7 (`file://host/path`, percent-decoded, malformed URL fallback), including directories reported by remote shells | `RustBackend/RustTerminalView.swift` (`parseOSC7`, `processOSC7URL`) |  | chau7_next_core/src/shell_osc7.rs, chau7_next/src/terminal/session.rs (refresh, update_cwd fallback) | done |  |
| RBK-007 | Shell integration events (OSC 133 A/B/C/D with exit code) reach the session (prompt, command start, command end) | `RustBackend/RustTerminalView.swift` (`getPendingShellIntegrationEvents`), `RustBackend/RustFFITypes.swift` | | `chau7_next/src/terminal/session.rs` (`take_shell_events`) | done | |
| RBK-008 | Shell exit or PTY close is reported once (exit code when known) | `RustBackend/RustTerminalView.swift` (`emitProcessTerminatedOnce`) | | `chau7_next/src/terminal/session.rs` (`exited`), `chau7_next/src/terminal/view.rs` (exit label) | done | |
| RBK-009 | "Shell initializing" notice when the shell prints nothing for 5 s after start | `RustBackend/RustTerminalView.swift` (`shellStartupTimeoutWork`, `onShellStartupSlow`) |  | chau7_next/src/terminal/session.rs (tick: shell_slow), chau7_next/src/terminal/loading_overlay.rs | done |  |
| RBK-010 | Bell: system beep, "subtle" plays the Pop sound, sound "none" flashes the view white; bell enabled toggle (`terminal.bellEnabled`, `terminal.bellSound`) | `RustBackend/RustTerminalView.swift` (`handleBell`, `flashBell`, `applyBellSettings`) |  | chau7_next/src/terminal/session.rs (ring_bell), chau7_next/src/pane.rs (flash), chau7_next/src/platform/sound.rs | done | NSSound |
| RBK-011 | Programs can set the clipboard (OSC 52 store) | `RustBackend/RustTerminalView.swift` (`getPendingClipboard`) | | `chau7_next/src/terminal/session.rs` (`ClipboardStore`), `chau7_next/src/terminal/view.rs` | done | NSPasteboard |
| RBK-012 | Programs can read the clipboard (OSC 52 load request answered with the clipboard text) | `RustBackend/RustTerminalView.swift` (`hasClipboardRequest`, `respondClipboard`) |  | chau7_next/src/terminal/session.rs (SessionEvent::ClipboardLoad, respond_clipboard), chau7_next/src/terminal/pty_writer.rs, chau7_next/src/terminal/view.rs | done | NSPasteboard |
| RBK-013 | Cmd-click on an OSC 8 hyperlink opens its URL | `RustBackend/RustTerminalView.swift` (`handleCmdClick`, `getLinkUrl`) | | `chau7_next/src/terminal/view.rs` (`url_at`) | done | NSWorkspace |
| RBK-014 | OSC 8 hyperlinks are underlined in the system link color | `RustBackend/RustTerminalView.swift` (`RustGridView.draw`) |  | `chau7_next/src/terminal/paint.rs` (`underline_for`, `link_color`) | done |  |
| RBK-015 | Cmd-click on a plain URL opens it; the URL is found on the whole logical (wrapped) line with the shared URL regex | `RustBackend/RustTerminalView.swift` (`handleCmdClick`, `getClickableLineHit`, `findURLs`) |  | chau7_next/src/terminal/links.rs | done | NSWorkspace |
| RBK-016 | Cmd-click on a file path (with optional `:line:col`) resolved against the cwd opens it in the internal editor (`feature.cmdClickOpensInternalEditor`) or the default app; nonexistent paths are ignored; whole feature behind `feature.cmdClickPaths` | `RustBackend/RustTerminalView.swift` (`handleCmdClick`, `logMissingCmdClickPath`) | `PathClickHandlerTests` | chau7_next/src/terminal/links.rs,chau7_next/src/terminal/mouse.rs | done | NSWorkspace |
| RBK-017 | Holding Cmd over a clickable URL or path shows the pointing-hand cursor | `RustBackend/RustTerminalView.swift` (`handleMouseMove`) |  | chau7_next/src/terminal/view.rs,chau7_next/src/terminal/links.rs | done | NSCursor |
| RBK-018 | Selection: drag to select (1.5 px threshold), double-click selects a word, triple-click a line, Select All covers screen and scrollback; selection drawn by the emulator (inverted cells) | `RustBackend/RustTerminalView.swift` (`setupEventMonitors`, `contextSelectAll`) | | `chau7_next/src/terminal/view.rs` (`on_mouse_down`, `on_mouse_move`, `select_all`) | done | |
| RBK-019 | Dragging a selection past the top or bottom edge auto-scrolls on a timer, faster the further out the mouse is; the scroll wheel extends an active selection | `RustBackend/RustTerminalView.swift` (`startAutoScrollTimer`, `performAutoScroll`, scroll wheel monitor) |  | `chau7_next/src/terminal/mouse.rs` (`update_auto_scroll`, `auto_scroll_step`, `on_scroll`) | done |  |
| RBK-020 | Copy on select (`feature.copyOnSelect`, default on): copies after drag, double-click and triple-click, debounced, skipped while Option is held | `RustBackend/RustTerminalView.swift` (`scheduleCopyOnSelect`) |  | `chau7_next/src/terminal/mouse.rs` (`schedule_copy_on_select`) | done | NSPasteboard |
| RBK-021 | Cmd+C copies the selection; with no selection it sends Ctrl-C (interrupt) | `RustBackend/RustTerminalView.swift` (`copy(_:)`) |  | `chau7_next/src/terminal/view.rs` (`copy`) | done | NSPasteboard |
| RBK-022 | Paste wraps text in bracketed paste markers when the program enabled mode 2004 | `RustBackend/RustTerminalView.swift` (`pasteText`, `isBracketedPasteMode`) | | `chau7_next/src/terminal/view.rs` (`paste`), `chau7_next_core/src/key_encoding.rs` (`encode_paste`) | done | NSPasteboard |
| RBK-023 | Mouse reporting to programs (modes 1000/1002/1003, X10 and SGR encodings, wheel, Shift/Option/Ctrl bits), only when the "Mouse Reporting" setting is on (`feature.mouseReporting`, default off); Ctrl-click bypasses it; right-click is reported as press and release | `RustBackend/RustTerminalView.swift` (`sendMouseEvent`, `sendScrollEvent`, `menu(for:)`) |  | `chau7_next/src/terminal/mouse.rs` (`reports_mouse`, `report_mouse`), `chau7_next_core/src/key_encoding.rs` (`encode_mouse`) | done |  |
| RBK-024 | Scroll wheel scrolls the scrollback when no program asked for mouse events | `RustBackend/RustTerminalView.swift` (scroll wheel monitor) | | `chau7_next/src/terminal/view.rs` (`on_scroll`) | done | |
| RBK-025 | Typing or pasting while scrolled up jumps back to the bottom | `RustBackend/RustTerminalView.swift` (`send(data:)`, `send(txt:)`) | | `chau7_next/src/terminal/view.rs` (`write_without_broadcast`) | done | |
| RBK-026 | Scroll to top and scroll to bottom (menu items and command palette) | `RustBackend/RustTerminalView.swift` (`scrollToTop`, `scrollToBottom`) |  | chau7_next/src/pane.rs (ScrollToTop, ScrollToBottom), chau7_next/src/workspace/pickers.rs, chau7_next/src/terminal/session.rs (scroll_to_top) | done |  |
| RBK-027 | Jump to the previous / next input line (keybindings `previousInputLine`, `nextInputLine`), using rows recorded when commands are entered | `RustBackend/RustTerminalView.swift` (`scrollToPreviousInputLine`, `scrollToNextInputLine`, `recordInputLine`) |  | `chau7_next_core/src/input/input_lines.rs`, `chau7_next/src/terminal/input.rs` (`jump_input_line`) | done |  |
| RBK-028 | Clear Scrollback frees history, removes inline images and resets dangerous-command highlights | `RustBackend/RustTerminalView.swift` (`clearScrollbackBuffer`) | | `chau7_next/src/terminal/view.rs` (`clear_scrollback`) | done | |
| RBK-029 | Clear Screen (sends Ctrl-L and clears the selection) | `RustBackend/RustTerminalView.swift` (`contextClearScreen`) |  | `chau7_next/src/terminal/input.rs` (`clear_screen`) | done |  |
| RBK-030 | Scrollback size setting (`terminal.scrollbackLines`) applied to open tabs | `RustBackend/RustTerminalView.swift` (`applyScrollbackLines`) | | `chau7_next/src/terminal/session.rs` (`apply_settings`) | done | |
| RBK-031 | Smart scroll (`feature.smartScrollEnabled`, default on): new output does not move the view while the user is scrolled up | `RustBackend/RustTerminalView.swift` (`restoreSmartScrollIfNeeded`, `updateIsUserAtBottom`) |  | chau7_next/src/terminal/session.rs (refresh: smart_scroll), chau7_next/src/settings/terminal.rs | done |  |
| RBK-032 | Color scheme (foreground, background, cursor, 16 ANSI colors) applied to the emulator and refreshed live | `RustBackend/RustTerminalView.swift` (`applyColorScheme`) | | `chau7_next/src/terminal/session.rs` (`apply_colors`) | done | |
| RBK-033 | Cursor shape (block, underline, bar) and blink setting; block cursor redraws its glyph in the background color; hidden when the program sends DECTCEM off | `RustBackend/RustTerminalView.swift` (`applyCursorStyle`, `RustGridView.drawCursor`, `tickCursorBlink`) | | `chau7_next/src/terminal/view.rs` (`paint_grid`, blink task) | done | |
| RBK-034 | Text attributes: bold and italic font variants, dim at 60 %, inverse, hidden, strikethrough, wide (CJK, emoji) characters on the grid | `RustBackend/RustTerminalView.swift` (`RustGridView.draw`), `RustBackend/RustFFITypes.swift` | | `chau7_next/src/terminal/view.rs` (`paint_grid`) | done | |
| RBK-035 | Underline styles from SGR 4:x: single, double, curly, dotted, dashed | `RustBackend/RustTerminalView.swift` (`RustGridView.draw`), `Performance/MetalTerminalRenderer.swift` (shader) |  | `chau7_terminal` (`OwnedCell::underline`), `chau7_next/src/terminal/paint.rs` (`underline_for`, `paint_decoration`) | done |  |
| RBK-036 | Bold text in ANSI colors 0-7 shown in the bright variant (bold-as-bright, done inside `chau7_terminal`) | `chau7_terminal/src/terminal.rs` (shared) | | `chau7_terminal` via `grid_copy` | done | |
| RBK-037 | Rows holding a dangerous command get a red tint | `RustBackend/RustTerminalView.swift` (`updateDangerousRowTints`, `RustGridView.rowTints`), `Performance/RustTermBridge.swift` | | `chau7_next/src/terminal/view.rs` (`dangerous_rows`) | done | |
| RBK-038 | Key encoding: arrows (DECCKM aware), Home/End, PgUp/PgDn, Insert (Help key), forward Delete, F1-F12 with xterm modifier parameters, Shift-Tab, Backspace (DEL) and Ctrl-Backspace (BS), Ctrl+letter/symbol/digit, Ctrl+Option adds ESC | `RustBackend/RustTerminalView.swift` (`generateTerminalSequence`, `generateSpecialKeySequence`, `controlCharacter`, `send(keyPress:)`) | `TerminalKeyPressTests` | `chau7_next_core/src/key_encoding.rs` (`encode_key`) | done | |
| RBK-039 | Option as Meta: Option+letter sends ESC+letter, while Option punctuation on international layouts (e.g. Option+5 for `[`) is typed as the character | `RustBackend/RustTerminalView.swift` (`generateTerminalSequence`), `Chau7Core` `OptionModifiedTextRouting` | `OptionModifiedTextRoutingTests` | `chau7_next_core/src/key_encoding.rs` (`option_types_text`), `chau7_next/src/terminal/view.rs` | done |  |
| RBK-040 | Cmd shortcuts never reach the shell | `RustBackend/RustTerminalView.swift` (`keyDown`, `handleTerminalKeyEvent`) | | `chau7_next_core/src/key_encoding.rs` | done | |
| RBK-041 | IME and dead keys: composition kept until committed, candidate window placed at the cursor, pending composition discarded when the tab loses focus | `RustBackend/RustTerminalView.swift` (`NSTextInputClient` extension, `resignFirstResponder`) | `RustTerminalViewTextInputTests` | `chau7_next/src/terminal/input.rs` (`EntityInputHandler`, `init_input`), `chau7_next/src/platform/input_method.rs` (`discard_marked_text` on focus loss) | done | NSTextInputClient |
| RBK-042 | Password AutoFill and macOS Services: text inserted by the system is pasted (bracketed), "AutoFill from Passwords..." in the context menu, selection offered to Services and text returned by a service pasted | `RustBackend/RustTerminalView.swift` (`insertText`, `contextAutoFillFromPasswords`, `validRequestor`, `writeSelectionToPasteboard`, `readSelectionFromPasteboard`) | `RustTerminalViewTextInputTests` | chau7_next/src/platform/autofill.rs, chau7_next/src/platform/services.rs, chau7_next/src/terminal/input.rs, chau7_next/src/app_actions.rs (deliver_platform_input) | done | NSTextInputClient, NSServices |
| RBK-043 | Local echo (`feature.localEchoEnabled`, default off): typed printable ASCII appears before the PTY echoes it, backspace undoes it, the echo is removed from output, turned off at password prompts | `RustBackend/RustTerminalView.swift` (`applyLocalEcho`, `processOutputForLocalEcho`, `detectEchoMode`) |  | `chau7_next_core/src/input/local_echo.rs`, `chau7_next/src/terminal/input.rs` (`apply_local_echo`, `with_local_echo`) | done |  |
| RBK-044 | Password prompt detection (PTY echo off, read with termios, heuristic fallback) so secrets are kept out of history | `RustBackend/RustTerminalView.swift` (`isPtyEchoDisabled`, `isEchoDisabledViaTermios`) |  | `chau7_terminal/src/rust_api.rs` (`password_input_on_fd`), `chau7_next/src/terminal/session.rs` (`is_echo_disabled`), `chau7_next/src/terminal/input.rs` (`note_user_input`) | done |  |
| RBK-045 | Up/Down at a shell prompt recall the tab's Chau7 command history; Option+Up/Down use the global (all tabs) history; key repeat does not re-insert the same command | `RustBackend/RustTerminalView.swift` (`installHistoryKeyMonitor`, `handleHistoryKeyDown`) |  | `chau7_next_core/src/input/command_history.rs`, `chau7_next/src/terminal/input.rs` (`history_key`) | done |  |
| RBK-046 | Snippet insertion (bracketed when enabled) with Tab / Shift-Tab jumping between placeholders, then to the final cursor position | `RustBackend/RustTerminalView.swift` (`insertSnippet`, `handleSnippetKeyDown`, `advanceSnippetPlaceholder`) | | `chau7_next/src/terminal/input.rs` (`insert_snippet`, `snippet_key`), `chau7_next_core/src/snippet_store.rs` (`prepare_insertion`, `Navigation`) | done | |
| RBK-047 | Select the current command line (menu item) | `RustBackend/RustTerminalView.swift` (`selectCurrentCommand`) |  | `chau7_next/src/terminal/input.rs` (`select_all`) | done |  |
| RBK-048 | Click to position the cursor (`feature.clickToPosition`, default on): a plain single click within 5 rows of the cursor moves it with arrow keys | `RustBackend/RustTerminalView.swift` (`handleClickToPosition`) |  | `chau7_next_core/src/input/cursor_moves.rs`, `chau7_next/src/terminal/mouse.rs` (`on_mouse_up`) | done |  |
| RBK-049 | Option-click moves the cursor to the clicked cell (`feature.optionClickCursor`, default on) | `RustBackend/RustTerminalView.swift` (`handleOptionClick`) |  | `chau7_next_core/src/input/cursor_moves.rs`, `chau7_next/src/terminal/mouse.rs` (`on_mouse_up`) | done |  |
| RBK-050 | Terminal context menu: Copy, Paste, Paste Escaped, Select All, AutoFill from Passwords, Clear Screen, Clear Scrollback; in mouse reporting mode right-click goes to the program unless Shift is held | `RustBackend/RustTerminalView.swift` (`menu(for:)`) | `PasteEscaperTests` | `chau7_next/src/terminal/input.rs` (`show_context_menu`), `chau7_next/src/terminal/mouse.rs` (`on_right_mouse_down`) | done | NSMenu |
| RBK-051 | Drag and drop: dropped files paste their shell-quoted paths; Option-drop of an image file, or a dropped PNG/TIFF, pastes a markdown base64 data URI for AI CLIs (10 MB limit, beep when larger) | `RustBackend/RustTerminalView.swift` (`performDragOperation`, `pasteImageData`) |  | chau7_next_core/src/input/drop.rs, chau7_next/src/terminal/mouse.rs (on_drop_paths, paste_image_data), chau7_next/src/platform/drop_image.rs | done | NSDraggingDestination |
| RBK-052 | PTY writes run on a background queue, so a program that stops reading input never freezes the UI; the terminal is destroyed off the main thread | `RustBackend/RustTerminalView.swift` (`RustTerminalFFI.writeQueue`, `deinit`) |  | chau7_next/src/terminal/pty_writer.rs, chau7_next/src/terminal/session.rs (write, retry_resize), chau7_terminal rust_api.rs (wait_input_writable) | done |  |
| RBK-053 | Text written into the screen without going through the PTY (the tip header box on new tabs) | `RustBackend/RustTerminalView.swift` (`injectOutput`, `startTerminal(initialOutput:)`) |  | chau7_next/src/terminal/session.rs (inject_output, spawn tip box) | done |  |
| RBK-054 | Whole buffer text (scrollback and screen) and single-line text for search, export and history | `RustBackend/RustTerminalView.swift` (`getBufferAsData`, `getLineText`, `getCachedBufferLines`) | | `chau7_next/src/terminal/session.rs` (`buffer_text`, `line_text`) | done | |
| RBK-055 | Grid snapshot payload for the remote control client | `RustBackend/RustTerminalView.swift` (`captureRemoteGridSnapshotPayload`) | `RemoteTerminalGridSnapshotTests` | chau7_next/src/remote/snapshot.rs | done |  |
| RBK-056 | Sixel and Kitty graphics toggles (`feature.sixelEnabled`, `feature.kittyGraphicsEnabled`) and Kitty image cache size (`feature.kittyCacheLimitMB`, 64-1024 MB) in Settings, plus iTerm2 interception following the Inline Images setting | `RustBackend/SixelKittyBridge.swift`, `RustBackend/RustTerminalView.swift` (`setImageProtocols`) |  | `chau7_next/src/settings/appearance.rs` (`GraphicsOptions`), `chau7_next/src/terminal/session.rs` (`apply_image_protocols`), `chau7_next/src/terminal/images.rs` | done |  |
| RBK-057 | (dev) Debug state dump, metrics reset, throughput stress test and diagnostics for a terminal | `RustBackend/RustTerminalView.swift` (`getDebugState`, `dumpDebugState`, `stressTest`, `runDiagnostics`) | | | n/a | |
| RBK-058 | ANSI text parsed by the Rust library for colored log views | `RustBackend/RustAnsiParser.swift` | `RustAnsiParserTests` | | n/a | |
| RBK-059 | Dim sequence patcher | `RustBackend/RustDimPatcher.swift` | | | n/a | |
| RBK-060 | CPU grid sync optimizations: dirty-row diff, partial redraw, 120 fps cap, skip unchanged frames | `RustBackend/RustTerminalView.swift` (`syncGridToRenderer`, `cellsEqual`) | | | n/a | |

## Notes

- The emulator (`apps/chau7-macos/rust/chau7_terminal`) is shared. Behavior
  done inside it (parsing, reflow, scrollback, selection painting by swapping
  fg/bg in the snapshot, bold-as-bright, OSC 8 link ids, OSC 133 and image
  interception) is the same in both apps as long as Chau7 Next calls the
  matching `rust_api.rs` / `terminal.rs` method.
- RBK-006: Chau7 Next parses OSC 7 from the output (`shell_osc7`, also
  across chunks) and falls back to the process table only while no OSC 7
  was seen.
- RBK-014: only the Swift CPU renderer draws the link underline. The Metal
  renderer (the Swift default, `feature.useMetalRenderer`) ignores `link_id`,
  so most Swift users do not see it either.
- RBK-015: Next only scans the visible row (no wrapped-line join via
  `logical_line_text`), recognizes only `http://`, `https://` and `file://`,
  and works even when `feature.cmdClickPaths` is off.
- RBK-019: Next scrolls one line per mouse-move event past the edge (no
  timer, no acceleration) and the wheel does not extend the selection.
- RBK-020: Next default is off (`copy_on_select = false`), Swift default is
  on; Option does not skip the copy.
- RBK-023: Next always reports (no setting), uses Shift as the bypass
  modifier, and only listens for the left button: right and middle clicks are
  not reported. Next also sends focus in/out (mode 1004) and turns the wheel
  into arrow keys in alternate-screen apps; Swift does neither.
- RBK-031: `alacritty_terminal` keeps the viewport while scrolled up (smart
  scroll on). With `[next] smart_scroll_enabled = false`, new output scrolls
  the view back to the bottom.
- RBK-035: `OwnedCell` drops the `_pad` byte that carries the underline
  variant (bits 0-2: 0/1 single, 2 double, 3 curly, 4 dotted, 5 dashed), so
  Next draws every underline as single. Add the field to `rust_api.rs`.
- RBK-039: Swift always treats Option+letter as Meta and lets Option
  punctuation through (`OptionModifiedTextRouting`). Next has an
  `option_as_meta` setting, default off, which composes every Option key.
- RBK-041: Next keeps `marked_text` when focus leaves the view.
- RBK-046: Next inserts placeholder defaults (`snippets::expand`) with no Tab
  navigation, and only uses bracketed paste when the text has a newline.
- RBK-052: input goes through `PtyWriter` (one thread per session, ordered,
  1 KB chunks written after `POLLOUT`), resize waits at most 50 ms for the
  terminal lock and retries, and the terminal is dropped on the writer
  thread.
- RBK-056: the Swift app intercepts Sixel and Kitty images but never draws
  them (decoding TODO in `pollAndSync`). Chau7 Next sets the protocols from
  the settings (Sixel and Kitty off by default, iTerm2 following Inline
  Images) and draws Sixel and Kitty images like iTerm2 ones.
- `unicodeAmbiguousWidth` exists in Swift settings but RustBackend never
  calls `chau7_terminal_set_ambiguous_width`.
- n/a rows: RBK-057 has no caller in the Swift app. RBK-058 is an optional
  accelerator for `Terminal/Rendering/AnsiParser.swift` (the user-visible log
  view belongs to the Terminal module). RBK-059 has no caller. RBK-060 is CPU
  renderer plumbing that GPUI replaces.

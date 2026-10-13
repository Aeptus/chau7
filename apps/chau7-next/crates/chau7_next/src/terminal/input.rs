//! Keyboard input of the terminal view: keys to PTY bytes, IME and dead
//! keys, prompt history keys, snippet placeholders, the Kitty keyboard
//! protocol, and the Edit commands (copy, cut, paste, paste escaped, select
//! all, clear screen and scrollback, AutoFill, input line jumps).
//!
//! Mirrors `RustTerminalView.swift` (`keyDown`, `generateTerminalSequence`,
//! `handleHistoryKeyDown`, `handleSnippetKeyDown`, `copy`, `paste`,
//! `NSTextInputClient`) and the Edit menu handlers of `AppDelegate.swift`.
//! A child module of `view.rs`, so it reaches the view's fields.

use std::ops::Range;
use std::time::{Duration, Instant};

use chau7_next_core::input::command_history::{
    CommandHistory, InputLineBuffer, RepeatGuard, recall_bytes,
};
use chau7_next_core::input::input_lines::InputLineTracker;
use chau7_next_core::input::kitty::{self, KittyEventType, KittyOutput};
use chau7_next_core::input::local_echo::LocalEcho;
use chau7_next_core::input::paste_escaper;
use chau7_next_core::input::shortcuts;
use chau7_next_core::key_encoding::{self, KeyContext, KeyMods};
use chau7_next_core::snippet_store::{Insertion, Navigation, cursor_move_bytes};
use gpui::{
    App, Bounds, ClipboardItem, Context, EntityInputHandler, Global, KeyDownEvent, KeyUpEvent,
    Pixels, Point, UTF16Selection, Window, point, size,
};

use super::TerminalView;
use crate::actions::{
    AutoFillFromPasswords, ClearLine, ClearScreen, ClearScrollback, ClearWord, Copy, Cut,
    NextInputLine, Paste, PasteEscaped, PreviousInputLine, SelectAll, SendEndOfFile, SendInterrupt,
    SendSuspend, TerminalMenu, TerminalMenuOp,
};
use crate::settings::Settings;
use crate::terminal::session::{SelectionKind, SessionEvent};

/// Cmd+A twice within this delay selects the whole buffer (Swift `doubleTapThreshold`).
const SELECT_ALL_DOUBLE_TAP: Duration = Duration::from_millis(400);

/// Keys with their own escape sequences; they never go through the IME.
const NAMED: &[&str] = &[
    "enter",
    "tab",
    "escape",
    "backspace",
    "delete",
    "insert",
    "up",
    "down",
    "left",
    "right",
    "home",
    "end",
    "pageup",
    "pagedown",
    "f1",
    "f2",
    "f3",
    "f4",
    "f5",
    "f6",
    "f7",
    "f8",
    "f9",
    "f10",
    "f11",
    "f12",
];

/// Commands entered in every terminal (Swift `CommandHistoryManager.shared`).
/// The global list starts with the shell integration's history file.
struct PromptHistory(CommandHistory);
impl Global for PromptHistory {}

fn prompt_history(cx: &mut App) -> &mut CommandHistory {
    if !cx.has_global::<PromptHistory>() {
        let mut history = CommandHistory::new();
        let mut older: Vec<String> = crate::history::shell_file::entries(cx)
            .iter()
            .take(2000)
            .map(|e| e.command.clone())
            .collect();
        older.reverse();
        history.seed_global(older);
        cx.set_global(PromptHistory(history));
    }
    &mut cx.global_mut::<PromptHistory>().0
}

/// Keyboard state of one terminal view.
pub(super) struct InputState {
    history_repeat: RepeatGuard,
    /// What was typed since the last Enter, for prompt history.
    line: InputLineBuffer,
    /// Rows where commands were entered (Cmd+Up / Cmd+Down).
    input_lines: InputLineTracker,
    snippet: Option<Navigation>,
    last_select_all: Option<Instant>,
    /// Set while a key press is being typed through the input method, so
    /// text arriving without it (AutoFill, emoji picker) is pasted instead.
    key_text_pending: bool,
    /// The shell reported a finished command (OSC 133), so `command_running`
    /// tells whether it sits at a prompt.
    shell_integration: bool,
    commands_entered: usize,
    local_echo: LocalEcho,
    /// Mouse state (`mouse.rs`).
    pub(super) mouse: super::mouse::MouseState,
}

impl InputState {
    pub(super) fn new(scrollback_lines: usize) -> Self {
        Self {
            history_repeat: RepeatGuard::default(),
            line: InputLineBuffer::new(),
            input_lines: InputLineTracker::new(scrollback_lines.max(1)),
            snippet: None,
            last_select_all: None,
            key_text_pending: false,
            shell_integration: false,
            commands_entered: 0,
            local_echo: LocalEcho::default(),
            mouse: Default::default(),
        }
    }
}

fn key_mods(modifiers: &gpui::Modifiers) -> KeyMods {
    KeyMods {
        shift: modifiers.shift,
        alt: modifiers.alt,
        control: modifiers.control,
        platform: modifiers.platform,
    }
}

impl TerminalView {
    /// Hook up input: Kitty keyboard protocol, shell integration events, IME
    /// reset on focus loss. Called once from `new`.
    pub(super) fn init_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let scrollback = Settings::get(cx).terminal.scrollback_lines;
        self.session
            .read(cx)
            .with_terminal(|t| t.set_kitty_keyboard(true, scrollback));
        let events = cx.subscribe(&self.session, |this, session, event, cx| match event {
            SessionEvent::CommandFinished(_) => this.input.shell_integration = true,
            SessionEvent::Output if !this.input.local_echo.is_empty() => {
                let session = session.read(cx);
                let grid = &session.grid;
                let offset = grid.display_offset as i32;
                this.input.local_echo.confirm(|col, row| {
                    let row = row + offset;
                    if col < 0 || row < 0 || row >= grid.rows as i32 {
                        return None;
                    }
                    let index = row as usize * grid.cols as usize + col as usize;
                    grid.cells.get(index).map(|c| c.character)
                });
            }
            _ => {}
        });
        // A pending composition (a dead key) must not leak into another tab
        // (Swift `resignFirstResponder` discards it).
        let blur = cx.on_blur(&self.focus_handle, window, |this, _, cx| {
            if this.marked_text.take().is_some() {
                if let Err(err) = crate::platform::input_method::discard_marked_text() {
                    log::warn!("discard marked text: {err}");
                }
                cx.notify();
            }
            this.input.snippet = None;
        });
        self._subscriptions.extend([events, blur]);
    }

    /// Listeners and actions of the terminal element.
    pub(super) fn input_listeners(
        div: gpui::Stateful<gpui::Div>,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        use gpui::prelude::*;
        div.on_key_down(cx.listener(Self::on_key_down))
            .on_key_up(cx.listener(Self::on_key_up))
            .on_action(cx.listener(Self::copy))
            .on_action(cx.listener(|this, _: &Cut, window, cx| this.copy(&Copy, window, cx)))
            .on_action(cx.listener(Self::paste))
            .on_action(cx.listener(|this, _: &PasteEscaped, _, cx| this.paste_escaped(cx)))
            .on_action(cx.listener(Self::select_all))
            .on_action(cx.listener(|this, _: &ClearScreen, _, cx| this.clear_screen(cx)))
            .on_action(cx.listener(|this, _: &ClearScrollback, window, cx| {
                this.clear_scrollback(window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &PreviousInputLine, _, cx| this.jump_input_line(false, cx)),
            )
            .on_action(cx.listener(|this, _: &NextInputLine, _, cx| this.jump_input_line(true, cx)))
            .on_action(
                cx.listener(|this, _: &AutoFillFromPasswords, window, cx| {
                    this.autofill(window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SendInterrupt, _, cx| this.send_control("interrupt", cx)),
            )
            .on_action(cx.listener(|this, _: &SendEndOfFile, _, cx| this.send_control("eof", cx)))
            .on_action(cx.listener(|this, _: &SendSuspend, _, cx| this.send_control("suspend", cx)))
            .on_action(cx.listener(|this, _: &ClearLine, _, cx| this.send_control("clearLine", cx)))
            .on_action(cx.listener(|this, _: &ClearWord, _, cx| this.send_control("clearWord", cx)))
            .on_action(cx.listener(Self::on_terminal_menu))
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let mods = key_mods(&keystroke.modifiers);
        let key = keystroke.key.as_str();
        let key_char = keystroke.key_char.as_deref();

        if self.snippet_key(key, mods, cx) || self.history_key(key, mods, event.is_held, cx) {
            self.consume(window, cx);
            return;
        }
        // Enter on a dangerous command asks first (`DangerousCommandGuard`).
        if self.guard_enter(event, window, cx) {
            self.consume(window, cx);
            return;
        }

        // Kitty keyboard protocol, when the program asked for it.
        let flags = self
            .session
            .read(cx)
            .with_terminal(|t| t.kitty_keyboard_flags());
        if flags != 0 && self.marked_text.is_none() {
            let event_type = if event.is_held {
                KittyEventType::Repeat
            } else {
                KittyEventType::Press
            };
            match kitty::encode(key, key_char, mods, flags, event_type) {
                KittyOutput::Bytes(bytes) => {
                    self.write(&bytes, cx);
                    self.consume(window, cx);
                    return;
                }
                KittyOutput::Nothing => {
                    self.consume(window, cx);
                    return;
                }
                KittyOutput::Legacy => {}
            }
        }

        // Plain text goes through the platform input handler (IME, dead keys,
        // emoji picker) unless a modifier changes its meaning. Option is Meta
        // except when it types ASCII punctuation (Swift's
        // `OptionModifiedTextRouting`; there is no setting).
        let is_text = key_char.is_some()
            && !NAMED.contains(&key)
            && !mods.control
            && !mods.platform
            && (!mods.alt || key_encoding::option_types_text(key, key_char, mods));
        if is_text || self.marked_text.is_some() {
            self.input.key_text_pending = true;
            return;
        }
        let ctx = KeyContext {
            app_cursor: self.session.read(cx).is_app_cursor(),
            option_as_meta: true,
        };
        if let Some(bytes) = key_encoding::encode_key(key, key_char, mods, ctx) {
            self.apply_local_echo(&bytes, cx);
            self.write(&bytes, cx);
            self.consume(window, cx);
        }
    }

    /// Local echo (`feature.localEchoEnabled`): predict typed characters,
    /// never at a password prompt or in a full-screen program.
    fn apply_local_echo(&mut self, bytes: &[u8], cx: &mut Context<Self>) {
        if !Settings::get(cx).input.local_echo {
            self.input.local_echo.clear();
            return;
        }
        let session = self.session.read(cx);
        let skip = session.is_echo_disabled() || session.with_terminal(|t| t.is_alt_screen());
        if skip {
            self.input.local_echo.clear();
            return;
        }
        let cursor = (session.cursor.0 as i32, session.cursor.1 as i32);
        let (cols, rows) = (session.grid.cols as i32, session.grid.rows as i32);
        self.input.local_echo.typed(bytes, cursor, cols, rows);
    }

    /// Predicted cells to draw: (column, screen row, character).
    pub(super) fn local_echo_cells(&self) -> Vec<(i32, i32, char)> {
        self.input.local_echo.cells().to_vec()
    }

    /// Kitty protocol key releases (flag 2), the only use of key up.
    fn on_key_up(&mut self, event: &KeyUpEvent, window: &mut Window, cx: &mut Context<Self>) {
        let flags = self
            .session
            .read(cx)
            .with_terminal(|t| t.kitty_keyboard_flags());
        if flags & kitty::EVENT_TYPES == 0 {
            return;
        }
        let keystroke = &event.keystroke;
        if let KittyOutput::Bytes(bytes) = kitty::encode(
            &keystroke.key,
            keystroke.key_char.as_deref(),
            key_mods(&keystroke.modifiers),
            flags,
            KittyEventType::Release,
        ) {
            self.session.read(cx).write(&bytes);
            self.consume(window, cx);
        }
    }

    fn consume(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        cx.stop_propagation();
        window.prevent_default();
        cx.notify();
    }

    /// Tab / Shift+Tab between snippet placeholders; any other key ends it.
    fn snippet_key(&mut self, key: &str, mods: KeyMods, cx: &mut Context<Self>) -> bool {
        let Some(nav) = self.input.snippet.as_mut() else {
            return false;
        };
        if key != "tab" || mods.platform || mods.control || mods.alt {
            self.input.snippet = None;
            return false;
        }
        let (delta, active) = nav.advance(mods.shift);
        if !active {
            self.input.snippet = None;
        }
        self.write_raw(&cursor_move_bytes(delta), cx);
        true
    }

    /// Whether the shell sits at a prompt (Swift `isAtPrompt`): never in a
    /// full-screen program; with shell integration, between commands;
    /// without it, only until the first command (afterwards the arrows could
    /// belong to a REPL).
    fn at_prompt(&self, cx: &App) -> bool {
        let session = self.session.read(cx);
        if session.exited.is_some() || session.with_terminal(|t| t.is_alt_screen()) {
            return false;
        }
        if self.input.shell_integration || session.last_command.is_some() {
            !session.command_running
        } else {
            self.input.commands_entered == 0
        }
    }

    /// Up/Down at a prompt recall this terminal's commands, Option+Up/Down
    /// those of every terminal (Swift `handleHistoryKeyDown`).
    fn history_key(
        &mut self,
        key: &str,
        mods: KeyMods,
        held: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        let up = match key {
            "up" => true,
            "down" => false,
            _ => return false,
        };
        if mods.platform || mods.control || mods.shift || !self.at_prompt(cx) {
            return false;
        }
        let tab = self.session.read(cx).id;
        let history = prompt_history(cx);
        let command = match (mods.alt, up) {
            (true, true) => history.previous_global(),
            (true, false) => history.next_global(),
            (false, true) => history.previous_in_tab(tab),
            (false, false) => history.next_in_tab(tab),
        };
        // No more history: the key is consumed anyway, as in Swift.
        let Some(command) = command else {
            return true;
        };
        if self.input.history_repeat.should_skip(&command, up, held) {
            return true;
        }
        self.write_raw(&recall_bytes(&command), cx);
        self.input.line.clear();
        self.input.line.feed(command.as_bytes());
        true
    }

    /// Bytes generated by Chau7 itself (cursor moves, history recall): sent
    /// and broadcast like typing, without touching the typed-line buffer.
    fn write_raw(&mut self, bytes: &[u8], cx: &mut Context<Self>) {
        if bytes.is_empty() {
            return;
        }
        let session = self.session.read(cx);
        session.scroll_to_bottom();
        session.write(bytes);
        self.cursor_on = true;
        cx.emit(super::TerminalViewEvent::Input(bytes.to_vec()));
    }

    /// Every byte the user types or pastes passes here (Swift `handleInput`):
    /// completed lines go to the prompt history and the input line marks.
    pub(super) fn note_user_input(&mut self, bytes: &[u8], cx: &mut Context<Self>) {
        let lines = self.input.line.feed(bytes);
        if lines.is_empty() {
            return;
        }
        let (tab, echo_off, row, active_ai, session_id, tab_id) = {
            let session = self.session.read(cx);
            // A password prompt (echo off, canonical mode): never recorded.
            let echo_off = session.is_echo_disabled();
            let row = session.grid.scrollback_rows as i64 + session.cursor.1 as i64;
            (
                session.id,
                echo_off,
                row,
                session.shell().effective_provider().is_some() || session.ai_app.is_some(),
                session.cto_id().to_owned(),
                session.tab_identifier.clone(),
            )
        };
        for line in lines {
            if line.trim().is_empty() {
                continue;
            }
            self.input.commands_entered += 1;
            self.input.input_lines.record(row);
            self.danger_note_input_line(&line, row, cx);
            prompt_history(cx).record(&line, tab, echo_off);
            if let Some(event) = context_session_event(&line, echo_off, active_ai) {
                crate::proxy::record_context_session_event(event, &session_id, &tab_id, cx);
            }
        }
    }

    /// Cmd+Up / Cmd+Down: scroll the previous or next command line to the top
    /// (Swift `scrollToPreviousInputLine`, `scrollToNextInputLine`).
    fn jump_input_line(&mut self, next: bool, cx: &mut Context<Self>) {
        let session = self.session.read(cx);
        let top = session.grid.scrollback_rows as i64 - session.grid.display_offset as i64;
        let target = if next {
            self.input.input_lines.next(top)
        } else {
            self.input.input_lines.previous(top)
        };
        match target {
            Some(row) => session.scroll_lines((top - row) as i32),
            None if next => session.scroll_to_bottom(),
            None => return,
        }
        self.session.update(cx, |s, cx| s.refresh(cx));
    }

    /// Insert a snippet; Tab and Shift+Tab then move between its placeholders.
    pub fn insert_snippet(&mut self, insertion: &Insertion, cx: &mut Context<Self>) {
        self.paste_text(&insertion.text, cx);
        self.input.snippet = match Navigation::start(insertion) {
            Some((nav, delta)) => {
                self.write_raw(&cursor_move_bytes(delta), cx);
                Some(nav)
            }
            None => None,
        };
    }

    /// Cmd+C: copy the selection, or send Ctrl-C (interrupt) when nothing
    /// is selected (`RustTerminalView.copy`). Cmd+X does the same.
    fn copy(&mut self, _: &Copy, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = self.session.read(cx).selection_text() {
            crate::workspace::record_clipboard(&text, cx);
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        } else {
            self.write(&[0x03], cx);
        }
    }

    fn paste(&mut self, _: &Paste, window: &mut Window, cx: &mut Context<Self>) {
        let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) else {
            return;
        };
        let bracketed = self.session.read(cx).is_bracketed_paste();
        let bytes = key_encoding::encode_paste(&text, bracketed);
        // A multi-line paste with a dangerous command asks first.
        if self.guard_paste(&text, bytes.clone(), window, cx) {
            return;
        }
        self.write(&bytes, cx);
    }

    /// Paste with bracketed paste markers when the program asked for them.
    pub fn paste_text(&mut self, text: &str, cx: &mut Context<Self>) {
        let bracketed = self.session.read(cx).is_bracketed_paste();
        let bytes = key_encoding::encode_paste(text, bracketed);
        self.write(&bytes, cx);
    }

    /// Paste Escaped (Cmd+Opt+V): backslashes before shell metacharacters,
    /// sent as typed text (Swift `send(txt:)`, no paste markers).
    fn paste_escaped(&mut self, cx: &mut Context<Self>) {
        if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
            self.write(paste_escaper::escape(&text).as_bytes(), cx);
        }
    }

    /// Send text as if typed (palette, history picker).
    pub fn send_text(&mut self, text: &str, cx: &mut Context<Self>) {
        let bracketed = self.session.read(cx).is_bracketed_paste();
        let bytes = key_encoding::encode_paste(text, bracketed && text.contains('\n'));
        self.write(&bytes, cx);
    }

    /// Cmd+A selects the current command line (wrapped rows included); a
    /// second Cmd+A within 0.4 s selects the whole buffer (`AppDelegate.selectAll`).
    fn select_all(&mut self, _: &SelectAll, window: &mut Window, cx: &mut Context<Self>) {
        let now = Instant::now();
        let double = self
            .input
            .last_select_all
            .is_some_and(|t| now.duration_since(t) < SELECT_ALL_DOUBLE_TAP);
        let session = self.session.read(cx);
        if double {
            session.select_all();
            self.input.last_select_all = None;
        } else {
            let row = session.cursor.1 as i32;
            session.selection_start(0, row, SelectionKind::Line);
            session.selection_update(0, row);
            self.input.last_select_all = Some(now);
        }
        self.session.update(cx, |s, cx| s.refresh(cx));
        self.publish_selection(window, cx);
    }

    /// Clear Screen (Cmd+K): Ctrl-L to the shell, scrollback kept.
    fn clear_screen(&mut self, cx: &mut Context<Self>) {
        self.write(&[0x0c], cx);
        {
            let session = self.session.read(cx);
            session.selection_clear();
            crate::platform::services::clear_selection_for_session(session.id);
        }
        self.session.update(cx, |s, cx| s.refresh(cx));
    }

    /// Clear Scrollback (Cmd+Opt+K): history above the screen is erased.
    fn clear_scrollback(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.overlays.clear();
        self.session.read(cx).clear_scrollback();
        self.input.input_lines.reset();
        self.danger.reset();
        self.session.update(cx, |s, cx| s.refresh(cx));
        self.publish_selection(window, cx);
    }

    /// Bindable terminal signals (Swift `KeyAction.interrupt`, `eof`, ...).
    fn send_control(&mut self, action: &str, cx: &mut Context<Self>) {
        if let Some(bytes) = shortcuts::control_action_bytes(action) {
            self.write(bytes, cx);
        }
    }

    fn autofill(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        match crate::platform::autofill::request() {
            Ok(true) => log::info!("Password AutoFill requested"),
            Ok(false) => log::warn!("Password AutoFill unavailable"),
            Err(err) => log::warn!("Password AutoFill: {err}"),
        }
    }

    fn on_terminal_menu(
        &mut self,
        action: &TerminalMenu,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action.0 {
            TerminalMenuOp::Copy => self.copy(&Copy, window, cx),
            TerminalMenuOp::Paste => self.paste(&Paste, window, cx),
            TerminalMenuOp::PasteEscaped => self.paste_escaped(cx),
            TerminalMenuOp::SelectAll => {
                self.session.read(cx).select_all();
                self.session.update(cx, |s, cx| s.refresh(cx));
                self.publish_selection(window, cx);
            }
            TerminalMenuOp::AutoFill => self.autofill(window, cx),
            TerminalMenuOp::ClearScreen => self.clear_screen(cx),
            TerminalMenuOp::ClearScrollback => self.clear_scrollback(window, cx),
        }
    }

    /// Terminal context menu (right click): Copy, Paste, Paste Escaped,
    /// Select All, AutoFill from Passwords (when available), Clear Screen,
    /// Clear Scrollback (`RustTerminalView.menu(for:)`).
    pub(super) fn show_context_menu(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use gpui_kit::component::native_menu::NativeMenu;
        window.focus(&self.focus_handle, cx);
        let can_copy = self.session.read(cx).selection_text().is_some();
        let can_paste = cx
            .read_from_clipboard()
            .and_then(|item| item.text())
            .is_some();
        let op = |op| Box::new(TerminalMenu(op)) as Box<dyn gpui::Action>;
        let mut menu = NativeMenu::new()
            .menu_with_disabled(crate::l10n::tr("Copy"), !can_copy, op(TerminalMenuOp::Copy))
            .menu_with_disabled(
                crate::l10n::tr("Paste"),
                !can_paste,
                op(TerminalMenuOp::Paste),
            )
            .menu_with_disabled(
                crate::l10n::tr("Paste Escaped"),
                !can_paste,
                op(TerminalMenuOp::PasteEscaped),
            )
            .menu(crate::l10n::tr("Select All"), op(TerminalMenuOp::SelectAll))
            .separator();
        if crate::platform::autofill::is_available() {
            menu = menu
                .menu(
                    crate::l10n::tr("AutoFill from Passwords..."),
                    op(TerminalMenuOp::AutoFill),
                )
                .separator();
        }
        menu.menu(
            crate::l10n::tr("Clear Screen"),
            op(TerminalMenuOp::ClearScreen),
        )
        .menu(
            crate::l10n::tr("Clear Scrollback"),
            op(TerminalMenuOp::ClearScrollback),
        )
        .show(position, window, cx);
    }
}

impl EntityInputHandler for TerminalView {
    fn text_for_range(
        &mut self,
        _range: Range<usize>,
        _adjusted: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        None
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: 0..0,
            reversed: false,
        })
    }

    fn marked_text_range(
        &self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Range<usize>> {
        self.marked_text
            .as_ref()
            .map(|t| 0..t.encode_utf16().count())
    }

    fn unmark_text(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.marked_text = None;
        cx.notify();
    }

    /// Committed text. Typed on the keyboard: sent as is. From elsewhere
    /// (Password AutoFill, the emoji picker, Services): pasted, as Swift's
    /// `insertText` does when `handlingKeyDown` is false.
    fn replace_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked_text = None;
        let typed = std::mem::take(&mut self.input.key_text_pending);
        if !text.is_empty() {
            if typed {
                self.apply_local_echo(text.as_bytes(), cx);
                self.write(text.as_bytes(), cx);
            } else {
                self.paste_text(text, cx);
            }
        }
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        new_text: &str,
        _new_selected_range: Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked_text = (!new_text.is_empty()).then(|| new_text.to_string());
        cx.notify();
    }

    /// The IME candidate window goes at the cursor.
    fn bounds_for_range(
        &mut self,
        _range: Range<usize>,
        element_bounds: Bounds<Pixels>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let metrics = self.metrics.as_ref()?;
        let session = self.session.read(cx);
        let (col, row) = session.cursor;
        let row = row as f32 + session.grid.display_offset as f32;
        Some(Bounds::new(
            point(
                element_bounds.left() + metrics.cell_width * col as f32,
                element_bounds.top() + metrics.line_height * row,
            ),
            size(metrics.cell_width, metrics.line_height),
        ))
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

/// Slash commands only affect proxy context inside an AI tool, never passwords.
fn context_session_event(
    line: &str,
    echo_off: bool,
    active_ai: bool,
) -> Option<chau7_next_core::injection_rules::SessionEvent> {
    if echo_off || !active_ai {
        return None;
    }
    chau7_next_core::injection_rules::SessionEvent::detect(line)
}

#[cfg(test)]
mod context_event_tests {
    use super::context_session_event;
    use chau7_next_core::injection_rules::SessionEvent;
    #[test]
    fn events_require_ai_echo_on_and_exact_slash_command() {
        assert_eq!(
            context_session_event(" /compact preserve tasks", false, true),
            Some(SessionEvent::AfterCompact)
        );
        assert_eq!(
            context_session_event("/CLEAR", false, true),
            Some(SessionEvent::AfterClear)
        );
        assert_eq!(context_session_event("/clear", true, true), None);
        assert_eq!(context_session_event("/clear", false, false), None);
        assert_eq!(context_session_event("/clearance", false, true), None);
        assert_eq!(context_session_event("echo /clear", false, true), None);
    }
}

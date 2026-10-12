//! Text editor pane (`TextEditorPaneView`, `TextEditorModel` in
//! `SplitPanes/`), with the IDE features `Editor/EnhancedEditorView.swift`
//! designed (EDT-004 to EDT-012): language highlighting, line numbers,
//! find bar, Tab and Shift+Tab indent, auto-indent, bracket matching, word
//! wrap, all driven by the editor settings.
//!
//! Header: file name (click copies it, "Copied" flash), orange dot while
//! unsaved, Open File, Save (Save As for untitled), Source/Runbook toggle
//! and Run All for `.md` files, close. Closing with unsaved, non-empty text
//! asks Save / Don't Save / Cancel.

mod live_markdown;
#[cfg(target_os = "macos")]
mod native_markdown;

use crate::monitoring::file_monitor::FileMonitor;
use crate::terminal::session::TerminalSession;
use futures::StreamExt;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use chau7_next_core::editor::config::EditorConfig;
use chau7_next_core::editor::language::{EditorLanguage, PLAIN_TEXT};
use chau7_next_core::editor::markdown;
use chau7_next_core::editor::text as edtext;
use gpui::{
    AnyWindowHandle, App, ClipboardItem, Context, Entity, EventEmitter, FocusHandle, Focusable,
    KeyBinding, PathPromptOptions, PromptLevel, Render, Subscription, Task, Window, div,
    prelude::*, px,
};
use gpui_kit::base::input::{
    EditorState, Enter, InputEvent, OutdentInline, RangeDecoration, RangeDecorationCollection,
    RangeDecorationStyle, TabSize, TextDecorationCollection,
};
use gpui_kit::component::input::Editor;
use gpui_kit::component::{Icon, IconName};

use super::highlight::{self, HighlightMode, Palette};
use super::{SidePaneEvent, header, header_button, loading, placeholder};
use crate::settings::Settings;
use crate::theme::Chrome;

gpui::actions!(
    chau7_editor,
    [
        /// Save the editor's file (Save As for an untitled editor).
        SaveEditor,
        /// Move the caret to the bracket matching the one next to it.
        JumpToMatchingBracket,
        /// Toggle Markdown source / preview inside the focused editor.
        ToggleMarkdownMode,
    ]
);

const CONTEXT: &str = "EditorPane";
type TerminalProvider = Rc<dyn Fn(&App) -> Option<Entity<TerminalSession>>>;

/// Editor key bindings (Cmd+S on macOS, Ctrl+S elsewhere, inside the pane).
pub fn bind_keys(cx: &mut App) {
    if cfg!(target_os = "macos") {
        cx.bind_keys([
            KeyBinding::new("cmd-s", SaveEditor, Some(CONTEXT)),
            KeyBinding::new("cmd-shift-p", ToggleMarkdownMode, Some(CONTEXT)),
            KeyBinding::new("cmd-shift-\\", JumpToMatchingBracket, Some(CONTEXT)),
        ]);
    } else {
        cx.bind_keys([
            KeyBinding::new("ctrl-s", SaveEditor, Some(CONTEXT)),
            KeyBinding::new("ctrl-shift-p", ToggleMarkdownMode, Some(CONTEXT)),
            KeyBinding::new("ctrl-shift-\\", JumpToMatchingBracket, Some(CONTEXT)),
        ]);
    }
}

/// Suggested name in the Save As panel (`editor.defaultFilename`).
const DEFAULT_FILENAME: &str = "untitled.txt";

pub struct EditorPane {
    state: Entity<EditorState>,
    window_handle: AnyWindowHandle,
    #[cfg(target_os = "macos")]
    native_pending: Rc<std::cell::RefCell<native_markdown::Pending>>,
    path: Option<PathBuf>,
    dirty: bool,
    loading: bool,
    error: Option<String>,
    /// Rendered runbook instead of the source; files open in source mode.
    markdown_mode: bool,
    copied_until: Option<Instant>,
    language: &'static EditorLanguage,
    palette: Palette,
    config: EditorConfig,
    /// Current file load; older results are ignored (`loadingToken`).
    load_token: u64,
    load_task: Option<Task<()>>,
    /// Text set by the pane itself (load, append): not a user edit.
    programmatic: bool,
    bracket: Option<RangeDecorationCollection>,
    markdown_styles: chau7_next_core::editor::live_markdown::Document,
    markdown_decorations: Option<TextDecorationCollection>,
    #[cfg(target_os = "macos")]
    native_markdown: Option<Rc<native_markdown::NativeMarkdown>>,
    #[cfg(target_os = "macos")]
    native_guard_subscriptions: Vec<Subscription>,
    bracket_clear: Option<Task<()>>,
    last_cursor: usize,
    /// Settings changed; applied at the next render (it needs the window).
    settings_pending: bool,
    focus_handle: FocusHandle,
    _subscriptions: Vec<Subscription>,
    loaded_hash: Option<edtext::ContentHash>,
    autosave: bool,
    autosaved_until: Option<Instant>,
    autosave_task: Option<Task<()>>,
    file_monitor: Option<FileMonitor>,
    file_monitor_task: Option<Task<()>>,
    terminal_provider: Option<TerminalProvider>,
    run_task: Option<Task<()>>,
    run_generation: u64,
    run_states: HashMap<(usize, String), super::runbook::BlockStatus>,
    note_attachment_pending: Option<PathBuf>,
}

impl EventEmitter<SidePaneEvent> for EditorPane {}

impl EditorPane {
    /// An empty "Untitled" editor (`splitWithTextEditor` without a file).
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let config = Settings::get(cx).editor.config.clone();
        let palette = super::palette(cx);
        let state = cx.new(|cx| {
            EditorState::new(window, cx)
                .language(PLAIN_TEXT.id)
                .folding(false)
                .indent_guides(false)
                .auto_close(false)
                .smart_indent(false)
                .line_number(config.show_line_numbers)
                .soft_wrap(config.word_wrap)
                .tab_size(tab_size(&config))
        });
        state.update(cx, |s, cx| {
            s.set_highlighter_factory(
                highlight::factory(HighlightMode::Language(&PLAIN_TEXT), palette),
                cx,
            )
        });
        let subscriptions = vec![
            cx.subscribe_in(&state, window, |this, _, event: &InputEvent, window, cx| {
                match event {
                    InputEvent::Change => {
                        this.refresh_markdown_styles(cx);
                        if !this.programmatic && !this.dirty {
                            this.dirty = true;
                            cx.emit(SidePaneEvent::Changed);
                        }
                        if !this.programmatic {
                            this.schedule_autosave(cx);
                        }
                        cx.notify();
                    }
                    InputEvent::Focus => cx.emit(SidePaneEvent::Focused),
                    _ => {}
                }
                this.update_bracket(window, cx);
            }),
            cx.observe_in(&state, window, |this, _, window, cx| {
                this.update_bracket(window, cx)
            }),
        ];
        let focus_handle = cx.focus_handle();
        Self {
            state,
            window_handle: window.window_handle(),
            #[cfg(target_os = "macos")]
            native_pending: Default::default(),
            path: None,
            dirty: false,
            loading: false,
            error: None,
            markdown_mode: false,
            copied_until: None,
            language: &PLAIN_TEXT,
            palette,
            config,
            load_token: 0,
            load_task: None,
            programmatic: false,
            bracket: None,
            markdown_styles: Default::default(),
            markdown_decorations: None,
            #[cfg(target_os = "macos")]
            native_markdown: None,
            #[cfg(target_os = "macos")]
            native_guard_subscriptions: Vec::new(),
            bracket_clear: None,
            last_cursor: 0,
            settings_pending: false,
            focus_handle,
            _subscriptions: subscriptions,
            loaded_hash: None,
            autosave: false,
            autosaved_until: None,
            autosave_task: None,
            file_monitor: None,
            file_monitor_task: None,
            terminal_provider: None,
            run_task: None,
            run_generation: 0,
            run_states: HashMap::new(),
            note_attachment_pending: None,
        }
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }
    /// Only attach an untitled buffer; pending typed text is merged after the background read.
    pub fn attach_session_note(
        &mut self,
        path: PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.path.is_some() {
            return;
        }
        self.note_attachment_pending = Some(path.clone());
        self.load_file(path, None, window, cx);
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty || self.has_pending_native_edits()
    }

    /// `fileName`: the file name or "Untitled".
    pub fn file_name(&self) -> String {
        edtext::editor_file_name(self.path.as_deref().and_then(Path::to_str))
    }

    pub fn content(&self, cx: &App) -> String {
        #[cfg(target_os = "macos")]
        if let Some(text) = self.native_pending.borrow().text() {
            return text.to_string();
        }
        self.state.read(cx).value().to_string()
    }

    fn is_markdown_file(&self) -> bool {
        self.language.id == "markdown"
    }

    /// Attribute-only updates leave EditorState text, selection and history intact.
    fn refresh_markdown_styles(&mut self, cx: &mut Context<Self>) {
        if !self.is_markdown_file() {
            self.markdown_styles = Default::default();
            if let Some(collection) = &self.markdown_decorations {
                collection.clear(cx);
            }
            return;
        }
        let text = self.content(cx);
        self.markdown_styles.update(&text);
        let decorations = live_markdown::decorations(&self.markdown_styles, self.palette);
        if let Some(collection) = &self.markdown_decorations {
            collection.set(decorations, cx);
        } else {
            self.markdown_decorations = Some(self.state.update(cx, |state, cx| {
                state.create_decorations_collection(decorations, cx)
            }));
        }
    }

    fn has_pending_native_edits(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.native_pending.borrow().text().is_some()
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }

    #[cfg(target_os = "macos")]
    fn mirror_native_edits(
        &mut self,
        text: Option<String>,
        selection: Option<std::ops::Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let changed = text.is_some();
        if let Some(text) = text {
            self.state
                .update(cx, |state, cx| state.set_value(text, window, cx));
            self.refresh_markdown_styles(cx);
            self.dirty = true;
            cx.emit(SidePaneEvent::Changed);
        }
        if let Some(selection) = selection {
            self.state
                .update(cx, |state, cx| state.set_selected_range(selection, cx));
        }
        changed
    }

    /// Programmatic consumers must see native edits before mutating the mirror.
    /// Keep the coalesced signal/actions queued; it will now find no stale text.
    fn flush_native_edits(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> bool {
        #[cfg(target_os = "macos")]
        {
            let (text, selection) = self
                .native_pending
                .borrow_mut()
                .take_edits(&self.state.read(_cx).value());
            self.mirror_native_edits(text, selection, _window, _cx)
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }

    #[cfg(target_os = "macos")]
    fn native_menu_command(
        &mut self,
        command: native_markdown::MenuCommand,
        cx: &mut Context<Self>,
    ) {
        if !self.markdown_mode
            && self
                .native_markdown
                .as_ref()
                .is_some_and(|native| native.menu_command(command))
        {
            cx.stop_propagation();
        }
    }

    fn toggle_markdown_mode(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.flush_native_edits(window, cx) {
            self.schedule_autosave(cx);
        }
        if self.is_markdown_file() {
            self.markdown_mode = !self.markdown_mode;
            cx.notify();
        }
    }

    // ----- settings ----------------------------------------------------

    /// The settings changed (applied at the next render).
    pub fn settings_changed(&mut self, cx: &mut Context<Self>) {
        self.settings_pending = true;
        cx.notify();
    }

    /// Apply the editor settings and theme.
    fn apply_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let config = Settings::get(cx).editor.config.clone();
        let palette = super::palette(cx);
        let changed_colors = palette != self.palette;
        self.palette = palette;
        let state = self.state.clone();
        state.update(cx, |s, cx| {
            s.set_line_number(config.show_line_numbers, window, cx);
            s.set_soft_wrap(config.word_wrap, window, cx);
            s.set_tab_size(tab_size(&config), cx);
        });
        self.config = config;
        self.refresh_markdown_styles(cx);
        if changed_colors {
            self.install_highlighter(cx);
        }
        cx.notify();
    }

    fn install_highlighter(&mut self, cx: &mut Context<Self>) {
        let language = if self.is_markdown_file() {
            &PLAIN_TEXT
        } else {
            self.language
        };
        let factory = highlight::factory(HighlightMode::Language(language), self.palette);
        let id = language.id;
        self.state.update(cx, |s, cx| {
            s.set_highlighter_factory(factory, cx);
            s.set_highlighter(id, cx);
        });
        self.refresh_markdown_styles(cx);
    }

    // ----- files -------------------------------------------------------

    /// `loadFile(at:scrollToLine:)`: read the file in the background; once
    /// loaded, select the start of 1-based `line`.
    pub fn load_file(
        &mut self,
        path: PathBuf,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.autosave_task = None;
        self.load_token += 1;
        let token = self.load_token;
        self.loading = true;
        self.error = None;
        cx.notify();
        let read_path = path.clone();
        let task = cx.background_spawn(async move { std::fs::read(&read_path) });
        self.load_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.load_token != token {
                    log::info!("Ignoring stale file load result for: {}", path.display());
                    return;
                }
                this.loading = false;
                let text = match result {
                    Ok(bytes) => String::from_utf8(bytes)
                        .map_err(|_| "The file is not valid UTF-8 text.".to_string()),
                    Err(err) => Err(err.to_string()),
                };
                match text {
                    Ok(text) => this.finish_load(path, text, line, window, cx),
                    Err(err) => {
                        log::error!("Failed to load file: {err}");
                        this.error = Some(format!("Failed to load file: {err}"));
                    }
                }
                cx.notify();
            });
        }));
    }

    fn finish_load(
        &mut self,
        path: PathBuf,
        mut text: String,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let merge_untitled = self
            .note_attachment_pending
            .take()
            .is_some_and(|target| target == path)
            && self.path.is_none();
        let untitled = merge_untitled
            .then(|| self.content(cx))
            .filter(|text| !text.trim().is_empty());
        let different_file = self.path.as_ref() != Some(&path);
        self.loaded_hash = Some(edtext::content_hash(text.as_bytes()));
        if let Some(untitled) = &untitled {
            text = edtext::append_text(&text, untitled).unwrap_or(text);
        }
        #[cfg(target_os = "macos")]
        self.native_pending.borrow_mut().clear_for_load();
        self.error = None;
        if different_file {
            let root = chau7_next_core::data_root::DataRoot::from_env();
            self.autosave = edtext::default_autosave(&path, root.config_dir())
                || edtext::default_autosave(&path, root.state_dir());
        }
        self.language = EditorLanguage::detect(&path.to_string_lossy());
        self.path = Some(path.clone());
        self.dirty = untitled.is_some();
        // Swift resets the preview when the file path changes, while a reload
        // of the same Markdown file preserves the chosen source/preview mode.
        if different_file || !self.is_markdown_file() {
            self.markdown_mode = false;
        }
        self.install_highlighter(cx);
        self.programmatic = true;
        let state = self.state.clone();
        state.update(cx, |s, cx| s.set_value(text.clone(), window, cx));
        self.programmatic = false;
        self.refresh_markdown_styles(cx);
        if let Some(line) = line {
            self.select_line(&text, line, cx);
        }
        #[cfg(target_os = "macos")]
        if let Some(native) = &self.native_markdown {
            native.loaded(&text, &self.config, self.state.read(cx).selected_range());
        }
        self.watch_file(path.clone(), window, cx);
        self.schedule_autosave(cx);
        log::info!("Loaded file: {}", path.display());
        cx.emit(SidePaneEvent::Changed);
    }

    fn schedule_autosave(&mut self, cx: &mut Context<Self>) {
        self.autosave_task = None;
        if !self.autosave || self.path.is_none() || !self.dirty {
            return;
        }
        let window_handle = self.window_handle;
        self.autosave_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(2500))
                .await;
            let _ = cx.update_window(window_handle, |_, window, cx| {
                this.update(cx, |this, cx| {
                    if this.autosave
                        && this.is_dirty()
                        && let Some(path) = this.path.clone()
                    {
                        this.write_to(path, window, cx);
                    }
                })
            });
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let _ = this.update(cx, |_, cx| cx.notify());
        }));
    }

    fn watch_file(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        self.file_monitor = None;
        self.file_monitor_task = None;
        let (sender, mut receiver) = futures::channel::mpsc::channel::<()>(1);
        let sender = std::sync::Mutex::new(sender);
        let monitor = FileMonitor::new(path.clone(), move || {
            if let Ok(mut sender) = sender.lock() {
                let _ = sender.try_send(());
            }
        });
        monitor.start();
        self.file_monitor = Some(monitor);
        self.file_monitor_task = Some(cx.spawn_in(window, async move |this, cx| {
            while receiver.next().await.is_some() {
                let read_path = path.clone();
                let bytes = cx
                    .background_spawn(async move { std::fs::read(read_path) })
                    .await;
                let _ = this.update_in(cx, |this, window, cx| {
                    if this.path.as_ref() != Some(&path) {
                        return;
                    }
                    let Ok(bytes) = bytes else {
                        return;
                    };
                    let dirty = this.dirty || this.has_pending_native_edits();
                    match edtext::external_change(this.loaded_hash, &bytes, dirty) {
                        edtext::ExternalChange::Unchanged => {}
                        edtext::ExternalChange::Conflict => {
                            this.autosave_task = None;
                            this.error = Some(
                                "File changed externally. Reload and merge before saving.".into(),
                            );
                            cx.notify();
                        }
                        edtext::ExternalChange::Reload => match String::from_utf8(bytes) {
                            Ok(text) => {
                                this.loaded_hash = Some(edtext::content_hash(text.as_bytes()));
                                #[cfg(target_os = "macos")]
                                if let Some(native) = &this.native_markdown {
                                    native.loaded(&text, &this.config, 0..0);
                                }
                                this.programmatic = true;
                                this.state
                                    .update(cx, |state, cx| state.set_value(text, window, cx));
                                this.programmatic = false;
                                this.error = None;
                                cx.emit(SidePaneEvent::Changed);
                                cx.notify();
                            }
                            Err(_) => {
                                this.error = Some("Changed file is not valid UTF-8 text.".into());
                                cx.notify();
                            }
                        },
                    }
                });
            }
        }));
    }

    pub fn set_terminal_provider(
        &mut self,
        provider: impl Fn(&App) -> Option<Entity<TerminalSession>> + 'static,
    ) {
        self.terminal_provider = Some(Rc::new(provider));
    }

    /// Select the start of `line` once the new text is laid out
    /// (`scrollToLine`).
    fn select_line(&mut self, text: &str, line: usize, cx: &mut Context<Self>) {
        let offset = edtext::line_start_offset(text, line);
        let state = self.state.clone();
        cx.spawn(async move |_, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(30))
                .await;
            state.update(cx, |s, cx| s.set_selected_range(offset..offset, cx));
        })
        .detach();
        log::info!("Scrolled editor to line {line}");
    }

    /// Write the text to `path` (`saveAs(to:)`). Returns success.
    fn write_to(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.flush_native_edits(window, cx);
        let expected = (self.path.as_ref() == Some(&path))
            .then_some(self.loaded_hash)
            .flatten();
        match edtext::can_save_file(&path, expected) {
            Ok(true) => {}
            Ok(false) => {
                self.error =
                    Some("File changed externally. Reload and merge before saving.".into());
                self.autosave_task = None;
                cx.notify();
                return false;
            }
            Err(error) => {
                self.error = Some(format!("Cannot verify current file: {error}"));
                cx.notify();
                return false;
            }
        }
        let content = self.content(cx);
        let tmp = path.with_extension(format!(
            "{}.chau7-tmp",
            path.extension().and_then(|e| e.to_str()).unwrap_or("")
        ));
        let result = std::fs::write(&tmp, &content).and_then(|_| std::fs::rename(&tmp, &path));
        match result {
            Ok(()) => {
                if self.path.as_ref() != Some(&path) {
                    self.language = EditorLanguage::detect(&path.to_string_lossy());
                    self.path = Some(path.clone());
                    self.install_highlighter(cx);
                }
                self.loaded_hash = Some(edtext::content_hash(content.as_bytes()));
                self.dirty = false;
                self.error = None;
                self.autosaved_until = self
                    .autosave
                    .then(|| Instant::now() + Duration::from_secs(2));
                log::info!("Saved file: {}", path.display());
                cx.emit(SidePaneEvent::Changed);
                cx.notify();
                true
            }
            Err(err) => {
                let _ = std::fs::remove_file(&tmp);
                log::error!("Failed to save file: {err}");
                self.error = Some(format!("Failed to save file: {err}"));
                cx.notify();
                false
            }
        }
    }

    /// Save button / Cmd+S: save in place, or ask for a path when untitled.
    /// The task resolves to whether the text was saved.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Task<bool> {
        match self.path.clone() {
            Some(path) => Task::ready(self.write_to(path, window, cx)),
            None => self.save_as(window, cx),
        }
    }

    /// Save As panel (`NSSavePanel`, "untitled.txt").
    fn save_as(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Task<bool> {
        let directory = self
            .path
            .as_ref()
            .and_then(|p| p.parent().map(Path::to_path_buf))
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("/"));
        let answer = cx.prompt_for_new_path(&directory, Some(DEFAULT_FILENAME));
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(path))) = answer.await else {
                return false;
            };
            this.update_in(cx, |this, window, cx| {
                let saved = this.write_to(path.clone(), window, cx);
                if saved {
                    let root = chau7_next_core::data_root::DataRoot::from_env();
                    this.autosave |= edtext::default_autosave(&path, root.config_dir())
                        || edtext::default_autosave(&path, root.state_dir());
                    this.watch_file(path, window, cx);
                }
                saved
            })
            .unwrap_or(false)
        })
    }

    /// Open File button (`fileImporter`).
    fn open_file(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let answer = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Open".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            if let Ok(Ok(Some(paths))) = answer.await
                && let Some(path) = paths.into_iter().next()
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    this.load_file(path, None, window, cx)
                });
            }
        })
        .detach();
    }

    /// `appendText`: the trimmed text on a new line at the end; marks the
    /// editor unsaved.
    pub fn append_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.flush_native_edits(window, cx);
        let content = self.content(cx);
        let Some(updated) = edtext::append_text(&content, text) else {
            return;
        };
        let addition = updated[content.len()..].to_string();
        #[cfg(target_os = "macos")]
        if self.is_markdown_file()
            && let Some(native) = &self.native_markdown
            && native.append(&content, &addition)
        {
            self.flush_native_edits(window, cx);
            self.dirty = true;
            self.schedule_autosave(cx);
            cx.emit(SidePaneEvent::Changed);
            cx.notify();
            return;
        }
        self.programmatic = true;
        let state = self.state.clone();
        state.update(cx, |s, cx| {
            let selection = s.selected_range();
            let end = s.text().len();
            s.set_selected_range(end..end, cx);
            s.insert(addition, window, cx);
            s.set_selected_range(selection, cx);
        });
        self.programmatic = false;
        self.dirty = true;
        self.schedule_autosave(cx);
        log::info!(
            "Appended text to editor: {}...",
            text.trim().chars().take(50).collect::<String>()
        );
        cx.emit(SidePaneEvent::Changed);
        cx.notify();
    }

    /// Close button (`attemptClose`): asks first when the text is unsaved
    /// and not blank. Resolves to whether the pane may close.
    pub fn confirm_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Task<bool> {
        self.flush_native_edits(window, cx);
        if !self.dirty || self.content(cx).trim().is_empty() {
            return Task::ready(true);
        }
        self.autosave_task = None;
        let answer = crate::l10n::prompt(
            window,
            PromptLevel::Warning,
            "Save changes?",
            Some("Your changes will be lost if you don't save them."),
            &["Save", "Don't Save", "Cancel"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| match answer.await.ok() {
            Some(0) => {
                let Ok(saved) = this.update_in(cx, |this, window, cx| this.save(window, cx)) else {
                    return false;
                };
                // A cancelled Save As keeps the pane.
                saved.await
            }
            Some(1) => this
                .update(cx, |this, _| {
                    this.autosave_task = None;
                    true
                })
                .unwrap_or(false),
            _ => {
                let _ = this.update(cx, |this, cx| this.schedule_autosave(cx));
                false
            }
        })
    }

    fn attempt_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let confirm = self.confirm_close(window, cx);
        cx.spawn(async move |this, cx| {
            if confirm.await {
                let _ = this.update(cx, |_, cx| cx.emit(SidePaneEvent::Close));
            }
        })
        .detach();
    }

    // ----- editing helpers ----------------------------------------------

    /// Bracket matching: when the caret moves next to a bracket, flash its
    /// match (`highlightMatchingBracket`, `showFindIndicator`).
    fn update_bracket(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let cursor = self.state.read(cx).cursor();
        if cursor == self.last_cursor {
            return;
        }
        self.last_cursor = cursor;
        if !self.config.bracket_matching {
            return;
        }
        let text = self.state.read(cx).text().to_string();
        let Some((_, matched)) = edtext::bracket_pair_near(&text, cursor) else {
            return;
        };
        let decoration = RangeDecoration::new(matched..matched + 1)
            .with_style(RangeDecorationStyle::Fill)
            .with_color(gpui::hsla(0.14, 0.95, 0.55, 0.55));
        match &self.bracket {
            Some(collection) => collection.set(vec![decoration], cx),
            None => {
                let collection = self.state.update(cx, |s, cx| {
                    s.create_range_decorations_collection(vec![decoration], cx)
                });
                self.bracket = Some(collection);
            }
        }
        // The indicator fades after a moment.
        self.bracket_clear = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(500))
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(collection) = &this.bracket {
                    collection.clear(cx);
                }
            });
        }));
    }

    fn jump_to_matching_bracket(&mut self, cx: &mut Context<Self>) {
        #[cfg(target_os = "macos")]
        if self.is_markdown_file()
            && !self.markdown_mode
            && let Some(native) = &self.native_markdown
        {
            native.jump();
            return;
        }
        let (text, cursor) = {
            let s = self.state.read(cx);
            (s.text().to_string(), s.cursor())
        };
        if let Some(target) = edtext::matching_bracket(&text, cursor) {
            self.state
                .update(cx, |s, cx| s.set_selected_range(target..target, cx));
        }
    }

    /// Enter (`handleAutoIndent`): with auto-indent on, a newline plus the
    /// leading whitespace of the caret's line (the code editor's own Enter
    /// would add a level after `{` and split bracket pairs, which Swift does
    /// not); with it off, a bare newline.
    fn on_enter(&mut self, action: &Enter, window: &mut Window, cx: &mut Context<Self>) {
        if action.secondary {
            return;
        }
        let insert = if self.config.auto_indent {
            let s = self.state.read(cx);
            let text = s.text().to_string();
            edtext::newline_with_indent(&text, s.selected_range().start)
        } else {
            "\n".to_string()
        };
        cx.stop_propagation();
        self.state
            .update(cx, |s, cx| s.replace(&insert, window, cx));
    }

    /// Shift+Tab (`handleOutdent`): remove one indent (the tab string, else
    /// a tab) from the start of the caret's line.
    fn on_outdent(&mut self, _: &OutdentInline, window: &mut Window, cx: &mut Context<Self>) {
        let (text, selection) = {
            let s = self.state.read(cx);
            (s.text().to_string(), s.selected_range())
        };
        let tab = self.config.tab_string();
        // Multi-line selections keep the editor's own outdent.
        if text[selection.clone()].contains('\n') {
            return;
        }
        cx.stop_propagation();
        let Some((start, len)) = edtext::outdent(&text, selection.start, &tab) else {
            return;
        };
        self.state.update(cx, |s, cx| {
            s.set_selected_range(start..start + len, cx);
            s.replace("", window, cx);
            let shift = |o: usize| {
                if o >= start + len {
                    o - len
                } else {
                    o.min(start)
                }
            };
            s.set_selected_range(shift(selection.start)..shift(selection.end), cx);
        });
    }

    // ----- render ------------------------------------------------------

    fn copy_file_name(&mut self, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(self.file_name()));
        self.copied_until = Some(Instant::now() + Duration::from_millis(1200));
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1250))
                .await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
        cx.notify();
    }

    fn render_header(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let copied = self.copied_until.is_some_and(|t| t > Instant::now());
        let markdown = self.is_markdown_file();
        let can_save = self.is_dirty() || self.path.is_none();
        header(chrome)
            .child(
                Icon::new(IconName::FileText)
                    .size(px(12.0))
                    .text_color(chrome.text_muted),
            )
            .child(
                div()
                    .id("editor-file-name")
                    .min_w(px(24.0))
                    .flex_shrink(1.0)
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .cursor_pointer()
                    .truncate()
                    .child(self.file_name())
                    .on_click(cx.listener(|this, _, _, cx| this.copy_file_name(cx))),
            )
            .when(copied, |d| {
                d.child(
                    div()
                        .text_size(px(9.0))
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Copied")),
                )
            })
            .when(self.dirty, |d| {
                d.child(
                    div()
                        .flex_none()
                        .size(px(6.0))
                        .rounded_full()
                        .bg(gpui::rgb(0xff9500)),
                )
            })
            .child(div().flex_1().min_w(px(4.0)))
            .child(
                header_button("editor-open", "Open", chrome, true)
                    .on_click(cx.listener(|this, _, window, cx| this.open_file(window, cx))),
            )
            .child(
                header_button("editor-save", "Save", chrome, can_save).when(can_save, |d| {
                    d.on_click(cx.listener(|this, _, window, cx| {
                        this.save(window, cx).detach();
                    }))
                }),
            )
            .when(self.path.is_some(), |d| {
                d.child(
                    header_button(
                        "editor-autosave",
                        if self.autosave {
                            "Auto-save On"
                        } else {
                            "Auto-save Off"
                        },
                        chrome,
                        true,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.autosave = !this.autosave;
                        this.schedule_autosave(cx);
                        cx.notify();
                    })),
                )
            })
            .when(
                self.autosaved_until
                    .is_some_and(|until| until > Instant::now()),
                |d| d.child(div().text_color(chrome.text_muted).child("Auto-saved")),
            )
            .when(markdown, |d| {
                let label = if self.markdown_mode {
                    "Show Source"
                } else {
                    "Show Runbook"
                };
                d.child(
                    header_button("editor-md-toggle", label, chrome, true).on_click(cx.listener(
                        |this, _, window, cx| {
                            this.toggle_markdown_mode(window, cx);
                        },
                    )),
                )
                .when(self.markdown_mode, |d| {
                    d.child(
                        header_button("editor-run-all", "▶ Run All", chrome, true)
                            .on_click(cx.listener(|this, _, _, cx| this.run_all(cx))),
                    )
                })
            })
            .child(
                header_button("editor-close", "✕", chrome, true)
                    .on_click(cx.listener(|this, _, window, cx| this.attempt_close(window, cx))),
            )
    }

    /// Run sequentially, observing real shell integration command completion.
    fn run_all(&mut self, cx: &mut Context<Self>) {
        let blocks = markdown::parse_markdown(&self.content(cx))
            .into_iter()
            .enumerate()
            .filter_map(|(index, section)| match section {
                markdown::MarkdownSection::CodeBlock { language, code }
                    if markdown::is_shell_language(language.as_deref()) =>
                {
                    Some((index, code))
                }
                _ => None,
            })
            .collect();
        self.run_commands(blocks, cx);
    }

    fn run_commands(&mut self, blocks: Vec<(usize, String)>, cx: &mut Context<Self>) {
        self.run_task = None;
        self.run_generation += 1;
        let generation = self.run_generation;
        let Some(terminal) = self
            .terminal_provider
            .as_ref()
            .and_then(|provider| provider(cx))
        else {
            self.error = Some("Runbook requires a terminal pane.".into());
            cx.notify();
            return;
        };
        if terminal.read(cx).command_running
            || terminal
                .read(cx)
                .pending_command()
                .is_some_and(|command| !command.is_empty())
        {
            self.error =
                Some("Wait for the terminal command to finish before running a block.".into());
            cx.notify();
            return;
        }
        self.error = None;
        self.run_states.clear();
        self.run_task = Some(cx.spawn(async move |this, cx| {
            for (index, block) in blocks {
                let previous = terminal.update(cx, |terminal, _| terminal.blocks().blocks().iter().map(|block| block.id).collect::<HashSet<_>>());
                if this.update(cx, |this, cx| {
                    this.run_states.insert((index, block.clone()), super::runbook::BlockStatus::Running);
                    cx.emit(SidePaneEvent::RunCommand(format!("{block}\n"))); cx.notify();
                }).is_err() { return; }
                let deadline = Instant::now() + Duration::from_secs(60);
                loop {
                    cx.background_executor().timer(Duration::from_millis(250)).await;
                    if this.update(cx, |this, _| this.run_generation != generation).unwrap_or(true) { return; }
                    let completed = terminal.update(cx, |terminal, _| markdown::completed_command(terminal.blocks().blocks(), &previous, &block));
                    if let Some(success) = completed {
                        let _ = this.update(cx, |this, cx| {
                            this.run_states.insert((index, block.clone()), if success { super::runbook::BlockStatus::Succeeded } else { super::runbook::BlockStatus::Failed }); cx.notify();
                        }); break;
                    }
                    if Instant::now() >= deadline {
                        let _ = this.update(cx, |this, cx| {
                            this.run_states.insert((index, block.clone()), super::runbook::BlockStatus::Failed);
                            this.error = Some("Runbook stopped: shell did not report command completion within 60 seconds.".into()); cx.notify();
                        }); return;
                    }
                }
            }
        }));
    }

    fn toggle_checkbox(&mut self, line: usize, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(content) = markdown::toggle_checkbox(&self.content(cx), line) {
            self.programmatic = true;
            self.state
                .update(cx, |state, cx| state.set_value(content, window, cx));
            self.programmatic = false;
            self.dirty = true;
            self.schedule_autosave(cx);
            cx.emit(SidePaneEvent::Changed);
            cx.notify();
        }
    }

    fn run_block(&mut self, code: (usize, String), cx: &mut Context<Self>) {
        self.run_commands(vec![code], cx);
    }
}

/// Width of the minimap column.
const MINIMAP_WIDTH: f32 = 80.0;

impl EditorPane {
    /// Minimap: one bar per line (indent and length scaled down), the
    /// visible rows framed; a click scrolls there ("Minimap" setting).
    fn render_minimap(&self, palette: Palette, cx: &mut Context<Self>) -> gpui::AnyElement {
        let state = self.state.read(cx);
        let text = state.text().to_string();
        let lines: Vec<(f32, f32)> = text
            .split('\n')
            .map(|line| {
                let indent = line.chars().take_while(|c| c.is_whitespace()).count();
                let len = line.chars().count();
                (indent as f32, len.saturating_sub(indent) as f32)
            })
            .collect();
        let visible = state.visible_row_range();
        let line_height = state.line_height();
        let ink = palette.foreground().opacity(0.35);
        let frame = palette.foreground().opacity(0.12);
        let bounds_cell =
            std::rc::Rc::new(std::cell::Cell::new(None::<gpui::Bounds<gpui::Pixels>>));
        let painted = bounds_cell.clone();
        let count = lines.len().max(1);
        div()
            .id("editor-minimap")
            .w(px(MINIMAP_WIDTH))
            .flex_none()
            .h_full()
            .border_l_1()
            .border_color(frame)
            .child(
                gpui::canvas(
                    move |bounds, _, _| painted.set(Some(bounds)),
                    move |bounds, _, window, _| {
                        let row = (f32::from(bounds.size.height) / count as f32).min(2.0);
                        let scale = 0.5;
                        for (i, (indent, len)) in lines.iter().enumerate() {
                            if *len == 0.0 {
                                continue;
                            }
                            let x = bounds.origin.x + px(4.0 + indent * scale);
                            let y = bounds.origin.y + px(i as f32 * row);
                            let w = px((len * scale).min(MINIMAP_WIDTH - 8.0 - indent * scale));
                            window.paint_quad(gpui::fill(
                                gpui::Bounds::new(
                                    gpui::point(x, y),
                                    gpui::size(w, px(row.max(1.0) * 0.8)),
                                ),
                                ink,
                            ));
                        }
                        if let Some(range) = &visible {
                            let top = bounds.origin.y + px(range.start as f32 * row);
                            let height = px(((range.end - range.start).max(1)) as f32 * row);
                            window.paint_quad(gpui::fill(
                                gpui::Bounds::new(
                                    gpui::point(bounds.origin.x, top),
                                    gpui::size(bounds.size.width, height),
                                ),
                                frame,
                            ));
                        }
                    },
                )
                .size_full(),
            )
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(move |this, event: &gpui::MouseDownEvent, _, cx| {
                    let (Some(bounds), Some(line_height)) = (bounds_cell.get(), line_height) else {
                        return;
                    };
                    let row = (f32::from(bounds.size.height) / count as f32).min(2.0);
                    let line = (f32::from(event.position.y - bounds.origin.y) / row).max(0.0);
                    let offset = gpui::point(px(0.0), -(line_height * line.floor()));
                    this.state
                        .update(cx, |s, cx| s.set_scroll_offset(offset, cx));
                }),
            )
            .into_any_element()
    }
}

fn tab_size(config: &EditorConfig) -> TabSize {
    TabSize {
        tab_size: config.tab_size as usize,
        hard_tabs: !config.use_spaces_for_tabs,
    }
}

impl Focusable for EditorPane {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        if self.markdown_mode {
            self.focus_handle.clone()
        } else {
            self.state.read(cx).focus_handle(cx)
        }
    }
}

impl Render for EditorPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let host = window.window_handle();
        if self.window_handle != host {
            self.window_handle = host;
            #[cfg(target_os = "macos")]
            self.native_guard_subscriptions.clear();
            // A pending autosave must also follow its transferred document.
            self.schedule_autosave(cx);
        }
        if std::mem::take(&mut self.settings_pending) {
            self.apply_settings(window, cx);
        }
        #[cfg(target_os = "macos")]
        if self.is_markdown_file() && !self.markdown_mode && !self.loading {
            if self.native_markdown.is_none() {
                self.native_markdown = native_markdown::NativeMarkdown::create(
                    window,
                    cx,
                    self.native_pending.clone(),
                );
            }
            if let Some(native) = &self.native_markdown {
                native.sync(&self.content(cx), &self.config);
            }
            if self.native_markdown.is_some()
                && self.native_guard_subscriptions.is_empty()
                && let Some(Some(root)) = window.root::<gpui_kit::base::Root>()
            {
                if let Ok(workspace) = root
                    .read(cx)
                    .view()
                    .clone()
                    .downcast::<crate::workspace::Workspace>()
                {
                    self.native_guard_subscriptions.push(cx.observe_in(
                        &workspace,
                        window,
                        |this, workspace, _, cx| {
                            if !workspace.read(cx).native_editor_allowed(cx)
                                && let Some(native) = &this.native_markdown
                            {
                                native.detach();
                            }
                            cx.notify();
                        },
                    ));
                }
                self.native_guard_subscriptions.push(cx.on_focus_out(
                    &self.focus_handle,
                    window,
                    |this, _, window, cx| {
                        if window
                            .context_stack()
                            .iter()
                            .any(|c| c.contains("PopupMenu"))
                            && let Some(native) = &this.native_markdown
                        {
                            native.detach();
                        }
                        cx.notify();
                    },
                ));
                self.native_guard_subscriptions.push(cx.observe_in(
                    &root,
                    window,
                    |this, _, window, cx| {
                        use gpui_kit::component::WindowExt;
                        if (window.has_active_dialog(cx) || window.has_active_sheet(cx))
                            && let Some(native) = &this.native_markdown
                        {
                            native.detach();
                        }
                        cx.notify();
                    },
                ));
            }
        }
        let chrome = Chrome::get(cx);
        let palette = self.palette;
        let header = self.render_header(chrome, cx);
        let body = if self.loading {
            loading(chrome).into_any_element()
        } else if let Some(error) = self.error.clone().filter(|_| self.path.is_none()) {
            placeholder(IconName::TriangleAlert, None, error, None, chrome).into_any_element()
        } else if self.markdown_mode && self.is_markdown_file() {
            let content = self.content(cx);
            super::runbook::render(
                &content,
                &self.run_states,
                chrome,
                super::text_background(palette, cx),
                super::mono_family(window, cx),
                cx.listener(|this, code: &(usize, String), _, cx| this.run_block(code.clone(), cx)),
                cx.listener(|this, line: &usize, window, cx| {
                    this.toggle_checkbox(*line, window, cx)
                }),
            )
            .into_any_element()
        } else {
            let style = super::editor_style(palette, self.config.highlight_current_line, cx);
            let editor = Editor::new(&self.state)
                .appearance(false)
                .h_full()
                .font_family(super::mono_family(window, cx))
                .text_size(px(self.config.font_size as f32));
            let minimap = self
                .config
                .show_minimap
                .then(|| self.render_minimap(palette, cx));
            let editor =
                super::style_override::with_style(editor, &self.state, style).into_any_element();
            #[cfg(target_os = "macos")]
            let editor = if self.is_markdown_file()
                && let Some(native) = &self.native_markdown
            {
                native_markdown::element(native.clone(), editor).into_any_element()
            } else {
                editor
            };
            div()
                .size_full()
                .flex()
                .bg(super::text_background(palette, cx))
                .child(div().flex_1().min_w_0().h_full().child(editor))
                .children(minimap)
                .into_any_element()
        };
        div()
            .id("editor-pane")
            .key_context(CONTEXT)
            .track_focus(&self.focus_handle)
            .size_full()
            .flex()
            .flex_col()
            .on_any_mouse_down(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Focused)))
            .capture_action(cx.listener(Self::on_enter))
            .capture_action(cx.listener(Self::on_outdent))
            .map(|pane| {
                #[cfg(target_os = "macos")]
                let pane = pane
                    .on_action(cx.listener(|this, _: &crate::actions::Cut, _, cx| {
                        this.native_menu_command(native_markdown::MenuCommand::Cut, cx)
                    }))
                    .on_action(cx.listener(|this, _: &crate::actions::Copy, _, cx| {
                        this.native_menu_command(native_markdown::MenuCommand::Copy, cx)
                    }))
                    .on_action(cx.listener(|this, _: &crate::actions::Paste, _, cx| {
                        this.native_menu_command(native_markdown::MenuCommand::Paste, cx)
                    }))
                    .on_action(cx.listener(|this, _: &crate::actions::SelectAll, _, cx| {
                        this.native_menu_command(native_markdown::MenuCommand::SelectAll, cx)
                    }))
                    .on_action(
                        cx.listener(|this, _: &crate::actions::ToggleSearch, _, cx| {
                            this.native_menu_command(native_markdown::MenuCommand::Find, cx)
                        }),
                    )
                    .on_action(cx.listener(|this, _: &crate::actions::FindNext, _, cx| {
                        this.native_menu_command(native_markdown::MenuCommand::FindNext, cx)
                    }))
                    .on_action(
                        cx.listener(|this, _: &crate::actions::FindPrevious, _, cx| {
                            this.native_menu_command(native_markdown::MenuCommand::FindPrevious, cx)
                        }),
                    )
                    .on_action(cx.listener(
                        |this, _: &crate::actions::UseSelectionForFind, _, cx| {
                            this.native_menu_command(
                                native_markdown::MenuCommand::UseSelectionForFind,
                                cx,
                            )
                        },
                    ));
                pane
            })
            .on_action(cx.listener(|this, _: &ToggleMarkdownMode, window, cx| {
                this.toggle_markdown_mode(window, cx);
            }))
            .on_action(cx.listener(|this, _: &SaveEditor, window, cx| {
                this.save(window, cx).detach();
            }))
            .on_action(cx.listener(|this, _: &JumpToMatchingBracket, _, cx| {
                this.jump_to_matching_bracket(cx)
            }))
            .child(header)
            .when_some(
                self.error.clone().filter(|_| self.path.is_some()),
                |d, error| {
                    d.child(
                        div()
                            .px_2()
                            .py_1()
                            .text_size(px(11.0))
                            .text_color(chrome.danger)
                            .child(error)
                            .child(
                                header_button("editor-reload", "Reload", chrome, true).on_click(
                                    cx.listener(|this, _, window, cx| {
                                        let confirm = if this.dirty {
                                            Some(crate::l10n::prompt(
                                                window,
                                                PromptLevel::Warning,
                                                "Reload file?",
                                                Some("Unsaved changes will be lost."),
                                                &["Reload", "Cancel"],
                                                cx,
                                            ))
                                        } else {
                                            None
                                        };
                                        cx.spawn_in(window, async move |this, cx| {
                                            if let Some(confirm) = confirm
                                                && confirm.await.ok() != Some(0)
                                            {
                                                return;
                                            }
                                            let _ = this.update_in(cx, |this, window, cx| {
                                                if let Some(path) = this.path.clone() {
                                                    this.load_file(path, None, window, cx);
                                                }
                                            });
                                        })
                                        .detach();
                                    }),
                                ),
                            ),
                    )
                },
            )
            .child(div().flex_1().min_h_0().overflow_hidden().child(body))
    }
}

#[cfg(test)]
mod markdown_live_tests {
    use super::*;
    use gpui::{
        AppContext, Bounds, TestAppContext, WindowBounds, WindowHandle, WindowOptions, size,
    };
    use gpui_kit::{base::Root, test::TestWindowExt};

    pub(super) fn editor(cx: &mut TestAppContext) -> (WindowHandle<Root>, Entity<EditorPane>) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            bind_keys(cx);
        });
        cx.update(|cx| {
            let (handle, pane) = gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(800.), px(480.)),
                    ))),
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    cx.new(|cx| {
                        let mut pane = EditorPane::new(window, cx);
                        pane.path = Some(PathBuf::from("NOTE.MARKDOWN"));
                        pane.language = EditorLanguage::detect("NOTE.MARKDOWN");
                        pane.install_highlighter(cx);
                        pane
                    })
                },
            )
            .unwrap();
            (handle.downcast::<Root>().unwrap(), pane)
        })
    }

    #[gpui::test]
    fn live_attributes_leave_selection_and_actual_undo_redo_intact(cx: &mut TestAppContext) {
        let (handle, pane) = editor(cx);
        let state = cx.update(|cx| pane.read(cx).state.clone());
        cx.update_window(handle.into(), |_, window, cx| {
            window.click(("input", state.entity_id()), cx);
            window.input("**café**", cx);
            assert_eq!(state.read(cx).value(), "**café**");
        })
        .unwrap();
        // Emitted InputEvent effects are delivered at the application update boundary.
        cx.update(|cx| {
            assert_eq!(pane.read(cx).markdown_styles.text(), "**café**");
            assert!(
                !pane
                    .read(cx)
                    .markdown_decorations
                    .as_ref()
                    .unwrap()
                    .get_ranges(cx)
                    .is_empty()
            );
        });
        let (selected, caret) = cx
            .update_window(handle.into(), |_, window, cx| {
                window.press("shift-left", cx);
                window.press("shift-left", cx);
                let selected = state.read(cx).selected_range();
                let caret = state.read(cx).cursor();
                pane.update(cx, |pane, cx| pane.refresh_markdown_styles(cx));
                assert_eq!(state.read(cx).selected_range(), selected);
                assert_eq!(state.read(cx).cursor(), caret);
                window.input("!", cx);
                assert_eq!(state.read(cx).value(), "**café!");
                (selected, caret)
            })
            .unwrap();
        cx.update_window(handle.into(), |_, window, cx| {
            window.press("secondary-z", cx);
            assert_eq!(state.read(cx).value(), "**café**");
            assert_eq!(state.read(cx).selected_range(), selected);
            assert_eq!(state.read(cx).cursor(), caret);
        })
        .unwrap();
        cx.update_window(handle.into(), |_, window, cx| {
            window.press(
                if cfg!(target_os = "macos") {
                    "cmd-shift-z"
                } else {
                    "ctrl-y"
                },
                cx,
            );
            assert_eq!(state.read(cx).value(), "**café!");
        })
        .unwrap();
        cx.update(|cx| assert_eq!(pane.read(cx).markdown_styles.text(), "**café!"));
    }

    #[cfg(target_os = "macos")]
    #[gpui::test]
    fn pending_native_text_is_saved_before_coalesced_delivery(cx: &mut TestAppContext) {
        let path = std::env::temp_dir().join(format!(
            "chau7-next-pending-save-{}.md",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, "# old").unwrap();
        let (handle, pane) = editor(cx);
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.finish_load(path.clone(), "# old".into(), None, window, cx);
                let typed = "# café😀";
                pane.native_pending.borrow_mut().typed(
                    typed,
                    objc2_foundation::NSRange::new(2, typed.encode_utf16().count() - 2),
                );
                assert_eq!(pane.state.read(cx).value(), "# old");
                assert_eq!(pane.content(cx), typed);
                assert!(pane.is_dirty());
                assert!(pane.write_to(path.clone(), window, cx));
                assert_eq!(std::fs::read_to_string(&path).unwrap(), typed);
                assert_eq!(pane.state.read(cx).value(), typed);
                assert_eq!(pane.state.read(cx).selected_range(), 2..typed.len());
                // The signal queued before Save arrives later: there is no old
                // text left to replace the saved mirror or mark it dirty again.
                let (text, selection) = pane.native_pending.borrow_mut().take_edits("# old");
                assert!(!pane.mirror_native_edits(text, selection, window, cx));
                assert!(!pane.is_dirty());
                pane.file_monitor = None;
                pane.file_monitor_task = None;
            });
        })
        .unwrap();
        cx.update(|cx| assert!(!pane.read(cx).is_dirty()));
        std::fs::remove_file(path).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[gpui::test]
    fn pending_native_text_survives_append_and_preview(cx: &mut TestAppContext) {
        let (handle, pane) = editor(cx);
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                let typed = "# café😀";
                pane.native_pending
                    .borrow_mut()
                    .typed(typed, objc2_foundation::NSRange::new(2, 0));
                let body = "```sh\nprintf '%s' 'body'\n```";
                let expected = edtext::append_text(typed, body).unwrap();
                pane.append_text(body, window, cx);
                assert_eq!(pane.content(cx), expected);
                assert_eq!(pane.state.read(cx).selected_range(), 2..2);
                assert!(pane.is_dirty());
                let (text, selection) = pane.native_pending.borrow_mut().take_edits(typed);
                assert!(!pane.mirror_native_edits(text, selection, window, cx));
                assert_eq!(pane.content(cx), expected);
                let edited = format!("{expected}\nmore");
                pane.native_pending.borrow_mut().typed(
                    &edited,
                    objc2_foundation::NSRange::new(edited.encode_utf16().count(), 0),
                );
                pane.toggle_markdown_mode(window, cx);
                assert!(pane.markdown_mode);
                assert_eq!(pane.state.read(cx).value(), edited);
                assert!(!pane.has_pending_native_edits());
                assert_eq!(
                    pane.state.read(cx).selected_range(),
                    edited.len()..edited.len()
                );
                pane.toggle_markdown_mode(window, cx);
                assert!(!pane.markdown_mode);
                assert_eq!(pane.content(cx), edited);
            });
        })
        .unwrap();
    }

    #[gpui::test]
    fn actual_markdown_load_opens_source_and_preserves_same_file_preview(cx: &mut TestAppContext) {
        let directory =
            std::env::temp_dir().join(format!("chau7-next-markdown-load-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let first = directory.join("NOTE.MARKDOWN");
        let second = directory.join("OTHER.md");
        std::fs::write(&first, "# café\n").unwrap();
        std::fs::write(&second, "# other\n").unwrap();
        let (handle, pane) = editor(cx);
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.finish_load(first.clone(), "# café\n".into(), None, window, cx);
                assert!(!pane.markdown_mode);
                assert!(!pane.dirty);
                pane.toggle_markdown_mode(window, cx);
                assert!(pane.markdown_mode);
                pane.finish_load(first.clone(), "# reloaded\n".into(), None, window, cx);
                assert!(pane.markdown_mode);
                assert_eq!(pane.content(cx), "# reloaded\n");
                assert!(!pane.dirty);
            });
        })
        .unwrap();
        // Verify the event boundary too: a programmatic load is not a user edit.
        cx.update(|cx| assert!(!pane.read(cx).dirty));
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.finish_load(second, "# other\n".into(), None, window, cx);
                assert!(!pane.markdown_mode);
                assert!(!pane.dirty);
                assert_eq!(pane.markdown_styles.text(), "# other\n");
                pane.file_monitor = None;
                pane.file_monitor_task = None;
            });
        })
        .unwrap();
        cx.update(|cx| assert!(!pane.read(cx).dirty));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[gpui::test]
    fn uppercase_markdown_source_preview_binding_preserves_buffer_history(cx: &mut TestAppContext) {
        let (handle, pane) = editor(cx);
        let state = cx.update(|cx| pane.read(cx).state.clone());
        cx.update_window(handle.into(), |_, window, cx| {
            window.click(("input", state.entity_id()), cx);
            window.input("# note", cx);
            assert!(pane.read(cx).is_markdown_file());
            assert!(!pane.read(cx).markdown_mode);
            window.press(
                if cfg!(target_os = "macos") {
                    "cmd-shift-p"
                } else {
                    "ctrl-shift-p"
                },
                cx,
            );
            assert!(pane.read(cx).markdown_mode);
            assert_eq!(state.read(cx).value(), "# note");
            pane.update(cx, |pane, cx| pane.toggle_markdown_mode(window, cx));
            state.update(cx, |state, cx| state.focus(window, cx));
            window.press("secondary-z", cx);
            assert_eq!(state.read(cx).value(), "");
        })
        .unwrap();
    }
}

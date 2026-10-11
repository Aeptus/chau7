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

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chau7_next_core::editor::config::EditorConfig;
use chau7_next_core::editor::language::{EditorLanguage, PLAIN_TEXT};
use chau7_next_core::editor::markdown;
use chau7_next_core::editor::text as edtext;
use gpui::{
    App, ClipboardItem, Context, Entity, EventEmitter, FocusHandle, Focusable, KeyBinding,
    PathPromptOptions, PromptLevel, Render, Subscription, Task, Window, div, prelude::*, px,
};
use gpui_kit::base::input::{
    EditorState, Enter, InputEvent, OutdentInline, RangeDecoration, RangeDecorationCollection,
    RangeDecorationStyle, TabSize,
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
    ]
);

const CONTEXT: &str = "EditorPane";

/// Editor key bindings (Cmd+S on macOS, Ctrl+S elsewhere, inside the pane).
pub fn bind_keys(cx: &mut App) {
    if cfg!(target_os = "macos") {
        cx.bind_keys([
            KeyBinding::new("cmd-s", SaveEditor, Some(CONTEXT)),
            KeyBinding::new("cmd-shift-\\", JumpToMatchingBracket, Some(CONTEXT)),
        ]);
    } else {
        cx.bind_keys([
            KeyBinding::new("ctrl-s", SaveEditor, Some(CONTEXT)),
            KeyBinding::new("ctrl-shift-\\", JumpToMatchingBracket, Some(CONTEXT)),
        ]);
    }
}

/// Suggested name in the Save As panel (`editor.defaultFilename`).
const DEFAULT_FILENAME: &str = "untitled.txt";

pub struct EditorPane {
    state: Entity<EditorState>,
    path: Option<PathBuf>,
    dirty: bool,
    loading: bool,
    error: Option<String>,
    /// Rendered runbook instead of the source (`.md` files open rendered).
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
    bracket_clear: Option<Task<()>>,
    last_cursor: usize,
    /// Settings changed; applied at the next render (it needs the window).
    settings_pending: bool,
    focus_handle: FocusHandle,
    _subscriptions: Vec<Subscription>,
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
                        if !this.programmatic && !this.dirty {
                            this.dirty = true;
                            cx.emit(SidePaneEvent::Changed);
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
            bracket_clear: None,
            last_cursor: 0,
            settings_pending: false,
            focus_handle,
            _subscriptions: subscriptions,
        }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// `fileName`: the file name or "Untitled".
    pub fn file_name(&self) -> String {
        edtext::editor_file_name(self.path.as_deref().and_then(Path::to_str))
    }

    pub fn content(&self, cx: &App) -> String {
        self.state.read(cx).value().to_string()
    }

    fn is_markdown_file(&self) -> bool {
        self.path
            .as_ref()
            .is_some_and(|p| p.to_string_lossy().ends_with(".md"))
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
        if changed_colors {
            self.install_highlighter(cx);
        }
        cx.notify();
    }

    fn install_highlighter(&mut self, cx: &mut Context<Self>) {
        let factory = highlight::factory(HighlightMode::Language(self.language), self.palette);
        let id = self.language.id;
        self.state.update(cx, |s, cx| {
            s.set_highlighter_factory(factory, cx);
            s.set_highlighter(id, cx);
        });
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
        text: String,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.language = EditorLanguage::detect(&path.to_string_lossy());
        self.path = Some(path.clone());
        self.dirty = false;
        // A markdown file opens as a runbook (`isMarkdownMode` follows the path).
        self.markdown_mode = self.is_markdown_file();
        self.install_highlighter(cx);
        self.programmatic = true;
        let state = self.state.clone();
        state.update(cx, |s, cx| s.set_value(text.clone(), window, cx));
        self.programmatic = false;
        if let Some(line) = line {
            self.select_line(&text, line, cx);
        }
        log::info!("Loaded file: {}", path.display());
        cx.emit(SidePaneEvent::Changed);
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
    fn write_to(&mut self, path: PathBuf, cx: &mut Context<Self>) -> bool {
        let content = self.content(cx);
        let tmp = path.with_extension(format!(
            "{}.chau7-tmp",
            path.extension().and_then(|e| e.to_str()).unwrap_or("")
        ));
        let result = std::fs::write(&tmp, content).and_then(|_| std::fs::rename(&tmp, &path));
        match result {
            Ok(()) => {
                if self.path.as_ref() != Some(&path) {
                    self.language = EditorLanguage::detect(&path.to_string_lossy());
                    self.path = Some(path.clone());
                    self.install_highlighter(cx);
                }
                self.dirty = false;
                self.error = None;
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
            Some(path) => Task::ready(self.write_to(path, cx)),
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
            this.update(cx, |this, cx| this.write_to(path, cx))
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
        let content = self.content(cx);
        let Some(updated) = edtext::append_text(&content, text) else {
            return;
        };
        let addition = updated[content.len()..].to_string();
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
        if !self.dirty || self.content(cx).trim().is_empty() {
            return Task::ready(true);
        }
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
            Some(1) => true,
            _ => false,
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
        let can_save = self.dirty || self.path.is_none();
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
            .when(markdown, |d| {
                let label = if self.markdown_mode {
                    "Show Source"
                } else {
                    "Show Runbook"
                };
                d.child(
                    header_button("editor-md-toggle", label, chrome, true).on_click(cx.listener(
                        |this, _, _, cx| {
                            this.markdown_mode = !this.markdown_mode;
                            cx.notify();
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

    /// Run All: every code block, 0.5 s apart, so the shell takes them one
    /// at a time.
    fn run_all(&mut self, cx: &mut Context<Self>) {
        let blocks = markdown::code_blocks(&self.content(cx));
        cx.spawn(async move |this, cx| {
            for (i, block) in blocks.into_iter().enumerate() {
                if i > 0 {
                    cx.background_executor()
                        .timer(Duration::from_millis(500))
                        .await;
                }
                if this
                    .update(cx, |_, cx| {
                        cx.emit(SidePaneEvent::RunCommand(format!("{block}\n")))
                    })
                    .is_err()
                {
                    return;
                }
            }
        })
        .detach();
    }

    fn run_block(&mut self, code: String, cx: &mut Context<Self>) {
        cx.emit(SidePaneEvent::RunCommand(format!("{code}\n")));
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
        if std::mem::take(&mut self.settings_pending) {
            self.apply_settings(window, cx);
        }
        let chrome = Chrome::get(cx);
        let palette = self.palette;
        let header = self.render_header(chrome, cx);
        let body =
            if self.loading {
                loading(chrome).into_any_element()
            } else if let Some(error) = self.error.clone().filter(|_| self.path.is_none()) {
                placeholder(IconName::TriangleAlert, None, error, None, chrome).into_any_element()
            } else if self.markdown_mode && self.is_markdown_file() {
                let content = self.content(cx);
                super::runbook::render(
                    &content,
                    chrome,
                    super::text_background(palette, cx),
                    super::mono_family(window, cx),
                    cx.listener(|this, code: &String, _, cx| this.run_block(code.clone(), cx)),
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
                div()
                    .size_full()
                    .flex()
                    .bg(super::text_background(palette, cx))
                    .child(div().flex_1().min_w_0().h_full().child(
                        super::style_override::with_style(editor, &self.state, style),
                    ))
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
                            .child(error),
                    )
                },
            )
            .child(div().flex_1().min_h_0().overflow_hidden().child(body))
    }
}

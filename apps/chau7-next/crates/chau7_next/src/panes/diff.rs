//! Diff viewer pane (`SplitPanes/DiffViewerPaneView.swift`,
//! `DiffViewerModel`): `git diff` (Working) or `git diff --cached` (Staged)
//! of one file, as numbered rows with colored hunk headers, additions and
//! deletions, a find bar (Cmd+F), +N / -N in the header, Refresh, and a
//! "No changes" state. An empty working-tree diff falls back to the staged
//! one.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chau7_next_core::editor::HighlightColor;
use chau7_next_core::editor::diff::{DiffMode, DiffRowKind, diff_rows, parse_unified_diff};
use chau7_next_core::editor::text as edtext;
use gpui::{
    App, Context, Entity, EventEmitter, FocusHandle, Focusable, Render, Subscription, Task, Window,
    div, prelude::*, px,
};
use gpui_kit::base::input::{EditorState, InputEvent};
use gpui_kit::component::IconName;
use gpui_kit::component::input::Editor;

use super::highlight::{self, HighlightMode, Palette};
use super::{SidePaneEvent, header, header_button, loading, placeholder};
use crate::settings::Settings;
use crate::theme::Chrome;

/// Run git in `directory` (`GitDiffTracker.runGit`: no credential prompt,
/// killed after 5 seconds). Empty output on any failure.
pub fn run_git(args: &[String], directory: &str) -> String {
    let child = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return String::new();
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        if let Some(stdout) = stdout.as_mut() {
            let _ = std::io::Read::read_to_end(stdout, &mut out);
        }
        out
    });
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
        }
    }
    String::from_utf8_lossy(&reader.join().unwrap_or_default()).into_owned()
}

/// Pathspec for a file named relative to the repository root (porcelain
/// paths), so the diff works from a subdirectory too.
fn pathspec(file: &str) -> String {
    if Path::new(file).is_absolute() {
        file.to_string()
    } else {
        format!(":(top){file}")
    }
}

struct Loaded {
    rows: Vec<(DiffRowKind, String)>,
    additions: usize,
    deletions: usize,
    mode: DiffMode,
}

/// `loadDiff`: the diff of `file` in `mode`; an empty working-tree diff
/// falls back to the staged one (reported as Staged).
fn load(file: &str, directory: &str, mode: DiffMode) -> Loaded {
    let spec = pathspec(file);
    let mut output = run_git(&mode.git_args(&spec), directory);
    let mut parsed = parse_unified_diff(&output);
    let mut effective = mode;
    if output.is_empty() && parsed.hunks.is_empty() && mode == DiffMode::WorkingTree {
        let staged = run_git(&DiffMode::Staged.git_args(&spec), directory);
        if !staged.is_empty() {
            output = staged;
            parsed = parse_unified_diff(&output);
            effective = DiffMode::Staged;
        }
    }
    let rows = diff_rows(&parsed.hunks)
        .into_iter()
        .map(|row| (row.kind, row.display()))
        .collect();
    log::info!(
        "Loaded diff: {file} ({} hunks, +{}/-{})",
        parsed.hunks.len(),
        parsed.additions,
        parsed.deletions
    );
    Loaded {
        rows,
        additions: parsed.additions,
        deletions: parsed.deletions,
        mode: effective,
    }
}

pub struct DiffPane {
    state: Entity<EditorState>,
    file: Option<String>,
    directory: Option<String>,
    mode: DiffMode,
    loading: bool,
    has_hunks: bool,
    additions: usize,
    deletions: usize,
    palette: Palette,
    kinds: Arc<Vec<DiffRowKind>>,
    load_token: u64,
    load_task: Option<Task<()>>,
    focus_handle: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<SidePaneEvent> for DiffPane {}

impl DiffPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let palette = super::palette(cx);
        let state = cx.new(|cx| {
            EditorState::new(window, cx)
                .language("text")
                .folding(false)
                .indent_guides(false)
                .line_number(false)
                .soft_wrap(true)
        });
        let subscriptions = vec![cx.subscribe(&state, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Focus) {
                cx.emit(SidePaneEvent::Focused);
            }
        })];
        Self {
            state,
            file: None,
            directory: None,
            mode: DiffMode::WorkingTree,
            loading: false,
            has_hunks: false,
            additions: 0,
            deletions: 0,
            palette,
            kinds: Arc::new(Vec::new()),
            load_token: 0,
            load_task: None,
            focus_handle: cx.focus_handle(),
            _subscriptions: subscriptions,
        }
    }

    pub fn file(&self) -> Option<&str> {
        self.file.as_deref()
    }

    pub fn directory(&self) -> Option<&str> {
        self.directory.as_deref()
    }

    pub fn mode(&self) -> DiffMode {
        self.mode
    }

    pub fn file_name(&self) -> String {
        edtext::preview_file_name(self.file.as_deref())
    }

    pub fn apply_settings(&mut self, cx: &mut Context<Self>) {
        let palette = super::palette(cx);
        if palette != self.palette {
            self.palette = palette;
            self.install_highlighter(cx);
        }
        cx.notify();
    }

    fn install_highlighter(&mut self, cx: &mut Context<Self>) {
        let factory = highlight::factory(HighlightMode::Diff(self.kinds.clone()), self.palette);
        self.state.update(cx, |s, cx| {
            s.set_highlighter_factory(factory, cx);
            s.set_highlighter("text", cx);
        });
    }

    /// `loadDiff(file:in:mode:)`; results of an earlier load are ignored.
    pub fn load_diff(
        &mut self,
        file: String,
        directory: String,
        mode: DiffMode,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.file = Some(file.clone());
        self.directory = Some(directory.clone());
        self.mode = mode;
        self.loading = true;
        self.load_token += 1;
        let token = self.load_token;
        cx.emit(SidePaneEvent::Changed);
        cx.notify();
        let task = cx.background_spawn(async move { load(&file, &directory, mode) });
        self.load_task = Some(cx.spawn_in(window, async move |this, cx| {
            let loaded = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.load_token != token {
                    return;
                }
                this.finish(loaded, window, cx);
            });
        }));
    }

    fn finish(&mut self, loaded: Loaded, window: &mut Window, cx: &mut Context<Self>) {
        self.loading = false;
        self.has_hunks = !loaded.rows.is_empty();
        self.additions = loaded.additions;
        self.deletions = loaded.deletions;
        self.mode = loaded.mode;
        let kinds: Vec<DiffRowKind> = loaded.rows.iter().map(|(k, _)| *k).collect();
        let text = loaded
            .rows
            .into_iter()
            .map(|(_, line)| line)
            .collect::<Vec<_>>()
            .join("\n");
        self.kinds = Arc::new(kinds);
        self.install_highlighter(cx);
        self.state.update(cx, |s, cx| s.set_value(text, window, cx));
        cx.emit(SidePaneEvent::Changed);
        cx.notify();
    }

    /// Refresh button (`refresh`).
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let (Some(file), Some(directory)) = (self.file.clone(), self.directory.clone()) {
            self.load_diff(file, directory, self.mode, window, cx);
        }
    }

    fn set_mode(&mut self, mode: DiffMode, window: &mut Window, cx: &mut Context<Self>) {
        if mode != self.mode {
            self.mode = mode;
            self.refresh(window, cx);
        }
    }

    fn render_header(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let palette = self.palette;
        let segment = |id: &'static str, label: &'static str, mode: DiffMode| {
            let selected = self.mode == mode;
            div()
                .id(id)
                .px_2()
                .py(px(1.0))
                .rounded_sm()
                .text_size(px(10.0))
                .cursor_pointer()
                .when(selected, |d| {
                    d.bg(chrome.tab_selected_bg).text_color(chrome.text)
                })
                .when(!selected, |d| d.text_color(chrome.text_muted))
                .child(label)
                .on_click(cx.listener(move |this, _, window, cx| this.set_mode(mode, window, cx)))
        };
        header(chrome)
            .child(div().text_color(chrome.text_muted).child("⇄"))
            .child(
                div()
                    .min_w_0()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .truncate()
                    .child(self.file_name()),
            )
            .when(self.additions > 0 || self.deletions > 0, |d| {
                d.child(
                    div()
                        .flex()
                        .gap_1()
                        .text_size(px(10.0))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(
                            div()
                                .text_color(palette.status(HighlightColor::Green))
                                .child(format!("+{}", self.additions)),
                        )
                        .child(
                            div()
                                .text_color(palette.status(HighlightColor::Red))
                                .child(format!("-{}", self.deletions)),
                        ),
                )
            })
            .child(div().flex_1())
            .child(
                div()
                    .flex()
                    .p(px(1.0))
                    .rounded_md()
                    .bg(chrome.terminal_bg.opacity(0.5))
                    .child(segment("diff-working", "Working", DiffMode::WorkingTree))
                    .child(segment("diff-staged", "Staged", DiffMode::Staged)),
            )
            .child(
                header_button("diff-refresh", "⟳", chrome, true)
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            .child(
                header_button("diff-close", "✕", chrome, true)
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Close))),
            )
    }
}

impl Focusable for DiffPane {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        if self.has_hunks {
            self.state.read(cx).focus_handle(cx)
        } else {
            self.focus_handle.clone()
        }
    }
}

impl Render for DiffPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let header = self.render_header(chrome, cx);
        let body = if self.loading {
            loading(chrome).into_any_element()
        } else if !self.has_hunks {
            let detail = match self.mode {
                DiffMode::WorkingTree => "Working tree is clean for this file",
                DiffMode::Staged => "No staged changes for this file",
            };
            placeholder(
                IconName::CircleCheck,
                Some(self.palette.status(HighlightColor::Green)),
                "No changes",
                Some(detail.into()),
                chrome,
            )
            .into_any_element()
        } else {
            let style = super::editor_style(self.palette, false, cx);
            let font_size = Settings::get(cx).appearance.zoomed_font_size();
            let editor = Editor::new(&self.state)
                .appearance(false)
                .readonly(true)
                .h_full()
                .font_family(super::mono_family(window, cx))
                .text_size(px(font_size));
            div()
                .size_full()
                .bg(super::text_background(self.palette, cx))
                .child(super::style_override::with_style(
                    editor,
                    &self.state,
                    style,
                ))
                .into_any_element()
        };
        div()
            .id("diff-pane")
            .track_focus(&self.focus_handle)
            .size_full()
            .flex()
            .flex_col()
            .on_any_mouse_down(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Focused)))
            .child(header)
            .child(div().flex_1().min_h_0().overflow_hidden().child(body))
    }
}

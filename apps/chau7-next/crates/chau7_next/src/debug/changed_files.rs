//! Changed Files panel (`ChangedFilesView`, Cmd+Opt+G): the files the last
//! command of the selected tab changed, with a filter box and the
//! `git diff --stat` summary of each file. Open Diff and Preview File hand
//! the file to the diff viewer and the file preview, which are separate
//! modules (their actions are placeholders until those land).

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use chau7_next_core::debug_console::{
    Tone, changed_files_title, diff_stat_summary, file_glyph, files_count_label, filter_files,
};
use gpui::{
    AnyWindowHandle, App, Bounds, ClipboardItem, Context, Entity, Global, IntoElement, Render,
    SharedString, Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::{snapshot, ui};
use crate::theme::Chrome;

#[derive(Default)]
struct PanelWindow(Option<AnyWindowHandle>);
impl Global for PanelWindow {}

/// Show the panel for the selected tab (a panel that is open is replaced).
pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<PanelWindow>().and_then(|w| w.0) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    let Some(tab) = snapshot::tabs(cx).into_iter().find(|t| t.selected) else {
        log::info!("Show Changed Files: no tab");
        return;
    };
    let bounds = Bounds::centered(None, size(px(520.0), px(480.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(360.0), px(260.0))),
        ..TitleBar::window_options()
    };
    let cwd = tab.cwd.clone();
    let files = tab.changed_files.clone();
    match gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| ChangedFilesView::new(cwd, files, window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(PanelWindow(Some(handle))),
        Err(err) => log::error!("changed files: {err}"),
    }
}

/// `git diff --stat -- <file>` summary line (`GitDiffTracker.diffStat`).
fn diff_stat(cwd: &str, file: &str) -> Option<String> {
    let output = Command::new("git")
        .args(["diff", "--stat", "--", file])
        .current_dir(cwd)
        .output()
        .ok()?;
    diff_stat_summary(&String::from_utf8_lossy(&output.stdout))
}

struct ChangedFilesView {
    cwd: String,
    files: Vec<String>,
    stats: HashMap<String, String>,
    filter: Entity<InputState>,
    query: String,
    selected: Option<String>,
    _subscription: gpui::Subscription,
}

impl ChangedFilesView {
    fn new(cwd: String, files: Vec<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let filter = cx
            .new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Filter files...")));
        let subscription = cx.subscribe(&filter, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.query = input.read(cx).value().to_string();
                cx.notify();
            }
        });
        // Stats come from git, off the UI thread.
        let jobs: Vec<(String, String)> = files.iter().map(|f| (cwd.clone(), f.clone())).collect();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    jobs.into_iter()
                        .filter_map(|(cwd, file)| diff_stat(&cwd, &file).map(|s| (file, s)))
                        .collect::<HashMap<_, _>>()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.stats = result;
                cx.notify();
            });
        })
        .detach();
        window.set_window_title(&changed_files_title(files.len()));
        Self {
            cwd,
            files,
            stats: HashMap::new(),
            filter,
            query: String::new(),
            selected: None,
            _subscription: subscription,
        }
    }

    /// The path as git printed it, resolved against the tab's directory.
    fn absolute(&self, file: &str) -> String {
        if file.starts_with('/') {
            file.to_string()
        } else {
            Path::new(&self.cwd)
                .join(file)
                .to_string_lossy()
                .into_owned()
        }
    }
}

impl Render for ChangedFilesView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let shown: Vec<String> = filter_files(&self.files, &self.query)
            .into_iter()
            .cloned()
            .collect();
        let mut list = div().flex().flex_col();
        for (i, file) in shown.iter().enumerate() {
            let active = self.selected.as_deref() == Some(file.as_str());
            let path = self.absolute(file);
            let select = file.clone();
            let copy_path = path.clone();
            let diff_path = path.clone();
            let mut row = div()
                .id(SharedString::from(format!("changed-{i}")))
                .flex()
                .items_center()
                .gap_2()
                .px_3()
                .py_1()
                .cursor_pointer()
                .when(active, |d| d.bg(chrome.accent.opacity(0.2)))
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.selected = Some(select.clone());
                    cx.notify();
                }))
                .child(
                    div()
                        .w(px(28.0))
                        .flex_none()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(file_glyph(file)),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .overflow_hidden()
                        .text_sm()
                        .font_family("Menlo")
                        .child(file.clone()),
                );
            if let Some(stat) = self.stats.get(file) {
                row = row.child(
                    div()
                        .flex_none()
                        .text_xs()
                        .text_color(ui::tone_color(Tone::Muted, chrome))
                        .child(stat.clone()),
                );
            }
            if active {
                row = row
                    .child(
                        ui::button(
                            SharedString::from(format!("changed-copy-{i}")),
                            "Copy Path",
                            chrome,
                        )
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(copy_path.clone()))
                        }),
                    )
                    .child(
                        ui::button(
                            SharedString::from(format!("changed-diff-{i}")),
                            "Open Diff",
                            chrome,
                        )
                        .on_click(move |_, window, cx| {
                            log::info!("Open Diff: {diff_path}");
                            window.dispatch_action(Box::new(crate::actions::OpenDiffViewer), cx)
                        }),
                    )
                    .child(
                        ui::button(
                            SharedString::from(format!("changed-preview-{i}")),
                            "Preview File",
                            chrome,
                        )
                        .on_click(|_, window, cx| {
                            window.dispatch_action(Box::new(crate::actions::OpenFilePreview), cx)
                        }),
                    );
            }
            list = list.child(row);
        }
        if shown.is_empty() {
            list = list.child(ui::empty_note(
                if self.files.is_empty() {
                    "No changed files in the last command"
                } else {
                    "No file matches the filter"
                },
                chrome,
            ));
        }

        let all_paths = shown.join("\n");
        let all_absolute = shown
            .iter()
            .map(|f| self.absolute(f))
            .collect::<Vec<_>>()
            .join("\n");
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                TitleBar::new().child(div().text_sm().child(changed_files_title(self.files.len()))),
            )
            .child(div().p_2().child(Input::new(&self.filter)))
            .child(
                div()
                    .id("changed-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(list),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(chrome.border)
                    .child(
                        div()
                            .flex_1()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(files_count_label(shown.len())),
                    )
                    .child(
                        ui::button("changed-copy-all", "Copy All Paths", chrome).on_click(
                            move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(
                                    all_absolute.clone(),
                                ))
                            },
                        ),
                    )
                    .child(
                        ui::button("changed-copy-names", "Copy All", chrome).on_click(
                            move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(all_paths.clone()))
                            },
                        ),
                    ),
            )
    }
}

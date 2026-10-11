//! Changed Files panel (`Debug/ChangedFilesPanel.swift`, View > Show
//! Changed Files): a floating window listing the files the last AI command
//! of the tab changed, with a filter, `git diff --stat` per file and a
//! context menu: Open Diff and Preview File (open in the tab's diff and
//! preview panes, SPL-023), Copy Path, Copy All Paths.

use std::path::Path;

use gpui::{
    Action, AnyWindowHandle, App, ClipboardItem, Context, Entity, FocusHandle, Global, MouseButton,
    MouseDownEvent, Render, Subscription, WeakEntity, Window, WindowBounds, WindowKind,
    WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::{Icon, IconName, TitleBar};

use crate::theme::Chrome;
use crate::workspace::Workspace;

/// Context menu choice on one file.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = chau7_changed_files, no_json)]
pub struct ChangedFileMenu {
    pub index: usize,
    pub op: ChangedFileOp,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum ChangedFileOp {
    OpenDiff,
    PreviewFile,
    CopyPath,
    CopyAllPaths,
}

#[derive(Default)]
struct PanelHandle(Option<AnyWindowHandle>);
impl Global for PanelHandle {}

/// `showChangedFiles`: the panel for the selected tab of `workspace`;
/// nothing when the last AI command changed no file.
pub fn show(workspace: &Entity<Workspace>, workspace_window: AnyWindowHandle, cx: &mut App) {
    let (files, directory) = workspace.read(cx).last_changed_files(cx);
    if files.is_empty() {
        log::info!("showChangedFiles: no changed files for the selected tab");
        return;
    }
    // Dismiss the existing panel.
    if let Some(handle) = cx.try_global::<PanelHandle>().and_then(|h| h.0) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    let height = ((files.len() * 24 + 80) as f32).min(500.0);
    let bounds = gpui::Bounds::centered(None, size(px(420.0), px(height.max(200.0))), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(300.0), px(200.0))),
        kind: WindowKind::Floating,
        ..TitleBar::window_options()
    };
    let target = workspace.downgrade();
    match gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&format!("Changed Files ({})", files.len()));
        cx.new(|cx| ChangedFilesView::new(files, directory, target, workspace_window, window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(PanelHandle(Some(handle))),
        Err(err) => log::error!("changed files panel: {err}"),
    }
}

pub struct ChangedFilesView {
    files: Vec<String>,
    directory: Option<String>,
    stats: Vec<Option<String>>,
    filter: Entity<InputState>,
    workspace: WeakEntity<Workspace>,
    workspace_window: AnyWindowHandle,
    /// Menu choices are dispatched to the focused element: the panel keeps
    /// focus inside itself.
    focus_handle: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl ChangedFilesView {
    fn new(
        files: Vec<String>,
        directory: Option<String>,
        workspace: WeakEntity<Workspace>,
        workspace_window: AnyWindowHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let filter = cx
            .new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Filter files...")));
        let subscriptions = vec![cx.subscribe(&filter, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })];
        // `loadDiffStats`, in the background.
        if let Some(dir) = directory.clone() {
            let list = files.clone();
            let task = cx.background_spawn(async move {
                list.iter()
                    .map(|file| diff_stat(file, &dir))
                    .collect::<Vec<_>>()
            });
            cx.spawn(async move |this, cx| {
                let stats = task.await;
                let _ = this.update(cx, |this, cx| {
                    this.stats = stats;
                    cx.notify();
                });
            })
            .detach();
        }
        let focus_handle = cx.focus_handle();
        window.focus(&focus_handle, cx);
        Self {
            focus_handle,
            stats: vec![None; files.len()],
            files,
            directory,
            filter,
            workspace,
            workspace_window,
            _subscriptions: subscriptions,
        }
    }

    fn filtered(&self, cx: &App) -> Vec<usize> {
        let query = self.filter.read(cx).value().to_lowercase();
        (0..self.files.len())
            .filter(|i| query.is_empty() || self.files[*i].to_lowercase().contains(&query))
            .collect()
    }

    fn on_menu(&mut self, action: &ChangedFileMenu, _: &mut Window, cx: &mut Context<Self>) {
        let Some(file) = self.files.get(action.index).cloned() else {
            return;
        };
        match action.op {
            ChangedFileOp::CopyPath => cx.write_to_clipboard(ClipboardItem::new_string(file)),
            ChangedFileOp::CopyAllPaths => self.copy_all(cx),
            ChangedFileOp::OpenDiff | ChangedFileOp::PreviewFile => {
                let Some(dir) = self.directory.clone() else {
                    return;
                };
                let Some(workspace) = self.workspace.upgrade() else {
                    return;
                };
                let op = action.op;
                let _ = self.workspace_window.update(cx, |_, window, cx| {
                    window.activate_window();
                    workspace.update(cx, |ws, cx| match op {
                        ChangedFileOp::OpenDiff => ws.open_diff_viewer(file, dir, window, cx),
                        _ => {
                            let full = Path::new(&dir).join(&file);
                            ws.open_file_preview(Some(full), window, cx)
                        }
                    });
                });
            }
        }
    }

    fn copy_all(&self, cx: &mut App) {
        cx.write_to_clipboard(ClipboardItem::new_string(self.files.join("\n")));
    }
}

/// `GitDiffTracker.diffStat`: the summary line of `git diff --stat`, else
/// of the staged diff.
fn diff_stat(file: &str, directory: &str) -> Option<String> {
    let summary = |staged: bool| {
        let mut args = vec!["diff".to_string()];
        if staged {
            args.push("--cached".into());
        }
        args.extend(["--stat".into(), "--".into(), file.to_string()]);
        super::diff::run_git(&args, directory)
            .lines()
            .rev()
            .find(|l| l.contains("changed"))
            .map(|l| l.trim().to_string())
    };
    summary(false)
        .or_else(|| summary(true))
        .filter(|s| !s.is_empty())
}

/// File icon by extension (`iconForFile`).
fn icon_for(path: &str) -> IconName {
    let ext = Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "md" => IconName::BookOpen,
        "json" | "yaml" | "yml" | "toml" => IconName::FileText,
        _ => IconName::File,
    }
}

impl Render for ChangedFilesView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let rows = self.filtered(cx);
        let count = rows.len();
        let mut list = div().id("changed-files-list").flex_1().overflow_y_scroll();
        for index in rows {
            let file = self.files[index].clone();
            let stat = self.stats.get(index).cloned().flatten();
            list = list.child(
                div()
                    .id(("changed-file", index))
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .px_2()
                    .h(px(24.0))
                    .hover(|d| d.bg(chrome.tab_hover_bg))
                    .child(
                        Icon::new(icon_for(&file))
                            .size(px(12.0))
                            .text_color(chrome.text_muted),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .font_family("monospace")
                            .text_size(px(12.0))
                            .child(file),
                    )
                    .children(stat.map(|s| {
                        div()
                            .flex_none()
                            .font_family("monospace")
                            .text_size(px(10.0))
                            .text_color(chrome.text_muted)
                            .child(s)
                    }))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |_, event: &MouseDownEvent, window, cx| {
                            let op =
                                |op| Box::new(ChangedFileMenu { index, op }) as Box<dyn Action>;
                            NativeMenu::new()
                                .menu(crate::l10n::tr("Open Diff"), op(ChangedFileOp::OpenDiff))
                                .menu(
                                    crate::l10n::tr("Preview File"),
                                    op(ChangedFileOp::PreviewFile),
                                )
                                .separator()
                                .menu(crate::l10n::tr("Copy Path"), op(ChangedFileOp::CopyPath))
                                .menu(
                                    crate::l10n::tr("Copy All Paths"),
                                    op(ChangedFileOp::CopyAllPaths),
                                )
                                .show(event.position, window, cx);
                        }),
                    ),
            );
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .track_focus(&self.focus_handle)
            .on_action(cx.listener(Self::on_menu))
            .child(TitleBar::new())
            .child(div().p_2().child(Input::new(&self.filter)))
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(list)
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(
                div()
                    .flex()
                    .items_center()
                    .p_2()
                    .text_size(px(11.0))
                    .text_color(chrome.text_muted)
                    .child(format!("{count} file{}", if count == 1 { "" } else { "s" }))
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("changed-files-copy-all")
                            .cursor_pointer()
                            .hover(|d| d.text_color(chrome.text))
                            .child(crate::l10n::tr("Copy All"))
                            .on_click(cx.listener(|this, _, _, cx| this.copy_all(cx))),
                    ),
            )
    }
}

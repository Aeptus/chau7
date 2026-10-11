//! Split pane actions on the selected tab (the panes live in `crate::pane`):
//! terminal splits, and the editor, preview and diff panes of the View >
//! Panes menu (`AppDelegate.openTextEditorPane`, `openFilePreviewPane`,
//! `openDiffViewerPane`, `appendSelectionToEditor`).

use std::path::PathBuf;

use chau7_next_core::command_block::git_changes;
use chau7_next_core::editor::diff::DiffMode;
use gpui::{Axis, Context, Div, Stateful, Window, prelude::*};

use super::Workspace;
use crate::actions::{
    AppendSelectionToEditor, ClosePane, FocusNextPane, FocusPreviousPane, OpenDiffViewer,
    OpenFilePreview, OpenTextEditor, ShowChangedFiles, SplitDown, SplitRight,
};

impl Workspace {
    /// Open `path` in the selected tab's editor pane, at 1-based `line`
    /// (`chau7://open`, Changed Files).
    pub fn open_file_in_editor(
        &mut self,
        path: PathBuf,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(panes) = self.selected_panes() {
            panes.update(cx, |p, cx| p.open_file_in_editor(path, line, window, cx));
        }
    }

    /// A new editor pane beside the focused pane, showing `path`
    /// (`openTextEditorInCurrentTab(filePath:)`).
    pub fn open_text_editor(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(panes) = self.selected_panes() {
            panes.update(cx, |p, cx| {
                p.open_text_editor(Some(path), None, window, cx);
            });
        }
    }

    /// Show `path` in the selected tab's preview pane (`openFilePreviewInCurrentTab`).
    pub fn open_file_preview(
        &mut self,
        path: Option<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(panes) = self.selected_panes() {
            panes.update(cx, |p, cx| p.open_file_preview(path, None, window, cx));
        }
    }

    /// Show the diff of `file` in `directory` (`openDiffViewerInCurrentTab`).
    pub fn open_diff_viewer(
        &mut self,
        file: String,
        directory: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(panes) = self.selected_panes() {
            panes.update(cx, |p, cx| {
                p.open_diff_viewer(file, directory, DiffMode::WorkingTree, window, cx)
            });
        }
    }

    /// Files the last AI command of the selected tab changed, and the tab's
    /// directory (`CommandBlockManager.lastChangedFiles`).
    pub fn last_changed_files(&self, cx: &gpui::App) -> (Vec<String>, Option<String>) {
        let Some(panes) = self.selected_panes() else {
            return (Vec::new(), None);
        };
        let tree = panes.read(cx);
        let directory = tree.cwd(cx).map(|p| p.to_string_lossy().into_owned());
        let focused = tree.focused_session(cx);
        let mut sessions: Vec<_> = focused.into_iter().collect();
        sessions.extend(tree.pane_sessions(cx).into_iter().map(|(_, s)| s));
        let files = sessions
            .iter()
            .map(|s| s.read(cx).blocks().last_changed_files().to_vec())
            .find(|files| !files.is_empty())
            .unwrap_or_default();
        (files, directory)
    }

    /// `openDiffViewerPane`: the first file the last AI command changed,
    /// else the first dirty file of `git status --porcelain`.
    fn open_diff_for_last_change(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (files, directory) = self.last_changed_files(cx);
        let Some(directory) = directory else {
            return;
        };
        if let Some(file) = files.into_iter().next() {
            self.open_diff_viewer(file, directory, window, cx);
            return;
        }
        let dir = directory.clone();
        let task = cx.background_spawn(async move {
            let porcelain =
                crate::panes::diff::run_git(&["status".into(), "--porcelain".into()], &dir);
            git_changes::first_changed_path(&porcelain)
        });
        cx.spawn_in(window, async move |this, cx| {
            if let Some(file) = task.await {
                let _ = this.update_in(cx, |this, window, cx| {
                    this.open_diff_viewer(file, directory, window, cx)
                });
            }
        })
        .detach();
    }
}

pub(super) fn register_pane_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &SplitRight, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| p.split(Axis::Horizontal, window, cx));
        }
    }))
    .on_action(cx.listener(|this, _: &SplitDown, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| p.split(Axis::Vertical, window, cx));
        }
    }))
    .on_action(cx.listener(|this, _: &ClosePane, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| p.close_focused(window, cx));
        }
    }))
    .on_action(cx.listener(|this, _: &FocusNextPane, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| p.focus_step(1, window, cx));
        }
    }))
    .on_action(cx.listener(|this, _: &FocusPreviousPane, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| p.focus_step(-1, window, cx));
        }
    }))
    .on_action(cx.listener(|this, _: &OpenTextEditor, window, cx| {
        if let Some(p) = this.selected_panes() {
            p.update(cx, |p, cx| {
                p.open_text_editor(None, None, window, cx);
            });
        }
    }))
    .on_action(
        cx.listener(|this, _: &OpenFilePreview, window, cx| {
            this.open_file_preview(None, window, cx)
        }),
    )
    .on_action(cx.listener(|this, _: &OpenDiffViewer, window, cx| {
        this.open_diff_for_last_change(window, cx)
    }))
    .on_action(cx.listener(|_, _: &ShowChangedFiles, window, cx| {
        let workspace = cx.entity();
        let handle = window.window_handle();
        cx.defer(move |cx| crate::panes::changed_files::show(&workspace, handle, cx));
    }))
    .on_action(
        cx.listener(|this, _: &AppendSelectionToEditor, window, cx| {
            let Some(p) = this.selected_panes() else {
                return;
            };
            match p.read(cx).terminal_selection(cx) {
                Some(text) => p.update(cx, |p, cx| p.append_to_editor(&text, window, cx)),
                None => log::warn!("No text selected to append"),
            }
        }),
    )
}

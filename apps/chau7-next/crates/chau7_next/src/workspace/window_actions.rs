//! Window helpers for the app shell: the active directory (per-repo config)
//! and new tabs that run a command (URL scheme). Close Other Tabs and Move
//! Tab live in `mod.rs`, Export Text and Use Selection for Find in `keys.rs`.

use gpui::{Context, Window};

use super::Workspace;

impl Workspace {
    /// Working directory of the selected tab (per-repo config resolution).
    pub fn active_directory(&self, cx: &gpui::App) -> Option<std::path::PathBuf> {
        self.selected_cwd(cx)
    }

    /// A new tab that runs `command` (URL scheme: `run`, `ssh`, `cd`). The
    /// shell gets a moment to start before the command is typed.
    pub fn new_tab_with_command(
        &mut self,
        command: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = self.add_tab(None, true, window, cx);
        self.focus_selected(window, cx);
        let Some(panes) = self.entries.get(&id).map(|e| e.panes.clone()) else {
            return;
        };
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(300))
                .await;
            let _ = this.update(cx, |_, cx| {
                let line = format!("{command}\n");
                crate::pane::PaneTree::send_input(&panes, line.as_bytes(), cx);
            });
        })
        .detach();
    }
}

//! Group overlay host for the reusable, independently scoped dashboard controller.
use super::Workspace;
use crate::{
    panes::{DashboardPane, SidePaneEvent},
    theme::Chrome,
};
use gpui::{App, Context, Entity, Subscription, Window, div, prelude::*};
#[derive(Default)]
pub(super) struct DashboardUi {
    root: Option<String>,
    view: Option<Entity<DashboardPane>>,
    subscription: Option<Subscription>,
}
impl DashboardUi {
    #[cfg(target_os = "macos")]
    pub(super) fn is_open(&self) -> bool {
        self.view.is_some()
    }

    pub(super) fn dismiss(&mut self) {
        self.root = None;
        self.subscription = None;
        self.view = None;
    }
}
impl Workspace {
    pub(super) fn toggle_dashboard(
        &mut self,
        root: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.dashboard.root.as_ref() == Some(&root) {
            self.dashboard.dismiss();
        } else {
            self.dashboard.dismiss();
            let view = cx.new(|cx| DashboardPane::new(root.clone(), false, window, cx));
            let sub = cx.subscribe_in(&view, window, |this, _, event, window, cx| match event {
                SidePaneEvent::Close => {
                    this.dashboard.dismiss();
                    this.focus_selected(window, cx);
                    cx.notify();
                }
                SidePaneEvent::OpenDashboard(root) => {
                    let root = root.clone();
                    this.dashboard.dismiss();
                    if let Some(panes) = this.selected_panes() {
                        panes.update(cx, |p, cx| p.open_dashboard(root, window, cx));
                    }
                    cx.notify();
                }
                SidePaneEvent::OpenEditor(path) => {
                    this.dashboard.dismiss();
                    this.open_file_in_editor(path.clone(), None, window, cx);
                }
                _ => {}
            });
            self.dashboard.root = Some(root);
            self.dashboard.view = Some(view);
            self.dashboard.subscription = Some(sub);
            self.hover = None;
            self.idle_open = false;
        }
        cx.notify();
    }
    /// Actual current presentation, including group overlays, for timer suspension.
    pub(crate) fn dashboard_contains(&self, id: gpui::EntityId, cx: &App) -> bool {
        if let Some(overlay) = &self.dashboard.view {
            return overlay.entity_id() == id;
        }
        self.selected_panes().is_some_and(|panes| {
            panes
                .read(cx)
                .leaves()
                .iter()
                .any(|pane| pane.entity_id() == id)
        })
    }
    pub(crate) fn dashboard_live_sessions(
        &self,
        cx: &App,
    ) -> Vec<(
        uuid::Uuid,
        Entity<crate::terminal::session::TerminalSession>,
    )> {
        self.state
            .tabs()
            .iter()
            .filter_map(|tab| {
                let session = self
                    .entries
                    .get(&tab.id)?
                    .panes
                    .read(cx)
                    .focused_session(cx)?;
                Some((tab.uuid, session))
            })
            .collect()
    }
    pub(crate) fn focus_dashboard_tab(
        &mut self,
        tab: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(id) = self.mcp_find(tab) {
            self.select_tab(id, window, cx);
        }
    }
    pub(super) fn render_dashboard(
        &mut self,
        chrome: Chrome,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let view = self.dashboard.view.as_ref()?;
        debug_assert_eq!(
            self.dashboard.root.as_deref(),
            Some(view.read(cx).repository_root())
        );
        Some(
            div()
                .absolute()
                .inset_0()
                .occlude()
                .bg(chrome.terminal_bg)
                .child(view.clone())
                .into_any_element(),
        )
    }
}

//! Recovery commands: refresh the selected terminal or redraw the tab bar.

use gpui::{Context, Div, Stateful, prelude::*};

use crate::actions::RefreshTabBar;
use crate::commands::ForceRefreshTab;
use crate::workspace::Workspace;

pub(super) fn register(div: Stateful<Div>, cx: &mut Context<Workspace>) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &ForceRefreshTab, _, cx| {
        let session = this
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx));
        if let Some(session) = session {
            session.update(cx, |s, cx| s.refresh(cx));
        }
    }))
    .on_action(cx.listener(|this, _: &RefreshTabBar, window, cx| {
        this.sync_window_menu(cx);
        // Invalidate retained painting without changing tabs or selection.
        window.refresh();
        cx.notify();
    }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn recovery_action_requests_redraw_without_replacing_tabs() {
        let source = include_str!("extras.rs");
        let handler = source
            .split("|this, _: &RefreshTabBar, window, cx|")
            .nth(1)
            .unwrap();
        let handler = handler.split("#[cfg(test)]").next().unwrap();
        assert!(handler.contains("this.sync_window_menu(cx);"));
        assert!(handler.contains("window.refresh();"));
        assert!(handler.contains("cx.notify();"));
        assert!(!handler.contains("state ="));
        assert!(!handler.contains("remove_window"));
    }
}

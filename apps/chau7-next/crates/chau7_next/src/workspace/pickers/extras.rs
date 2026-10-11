//! Tab commands of the command palette that have no menu item: Force
//! Refresh Tab.

use gpui::{Context, Div, Stateful, prelude::*};

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
}

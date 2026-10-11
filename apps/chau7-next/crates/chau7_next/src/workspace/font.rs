//! Font size of the selected tab (Bigger, Smaller, Actual Size): Swift zooms
//! the selected tab's session (`OverlayTabsModel.zoomIn` ->
//! `TerminalSessionModel.updateFontSize`, 8 to 72 pt); other tabs keep theirs.

use gpui::{Context, Div, Stateful, prelude::*};

use super::Workspace;
use crate::actions::{DecreaseFontSize, IncreaseFontSize, ResetFontSize};
use crate::settings::Settings;

impl Workspace {
    /// Change the selected tab's font size by `delta` points, or back to
    /// the configured size when `delta` is `None`.
    fn zoom_selected_tab(&mut self, delta: Option<f32>, cx: &mut Context<Self>) {
        let Some(panes) = self.selected_panes() else {
            return;
        };
        let default = Settings::get(cx).appearance.zoomed_font_size();
        let current = panes
            .read(cx)
            .focused_view()
            .map(|v| v.read(cx).font_size())
            .unwrap_or(self.font_size);
        let size = match delta {
            Some(delta) => (current + delta).clamp(8.0, 72.0),
            None => default,
        };
        self.font_size = size;
        panes.update(cx, |p, cx| p.set_font_size(size, cx));
    }
}

pub(super) fn register_font_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(
        cx.listener(|this, _: &IncreaseFontSize, _, cx| this.zoom_selected_tab(Some(1.0), cx)),
    )
    .on_action(
        cx.listener(|this, _: &DecreaseFontSize, _, cx| this.zoom_selected_tab(Some(-1.0), cx)),
    )
    .on_action(cx.listener(|this, _: &ResetFontSize, _, cx| this.zoom_selected_tab(None, cx)))
}

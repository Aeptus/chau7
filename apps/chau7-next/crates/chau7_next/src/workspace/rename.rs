//! Rename panel (`RenameOverlayView`): title and color of a tab (Cmd+Opt+R,
//! double-click, or the tab menu; "Tab Color…" opens it on the color row).
//!
//! `commitRename` rules: an empty title clears the custom title, an
//! unchanged one is not stored, a changed color becomes a manual override
//! (beats the automatic AI color). Cancel leaves title and color as they were.

use chau7_next_core::tabs_state::TabColor;
use gpui::{Context, Div, Entity, Stateful, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{InputEvent, InputState};

use super::Workspace;
use super::panel::PanelKind;
use super::widgets::{button, chrome_input};
use crate::actions::RenameTab;
use crate::tab_bar::TabId;
use crate::theme::{Chrome, tab_color};

pub(super) fn register_rename_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &RenameTab, window, cx| {
        if let Some(id) = this.state.selected() {
            this.begin_rename(id, window, cx);
        }
    }))
}

pub(super) struct RenameState {
    pub(super) tab: TabId,
    input: Entity<InputState>,
    color: TabColor,
    original_title: String,
    /// Arrow keys move through the colors (opened by "Tab Color…").
    pub(super) color_focus: bool,
    _subscription: Subscription,
}

impl Workspace {
    pub(super) fn begin_rename(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        self.begin_rename_with(id, false, window, cx);
    }

    /// `beginRename(tabID:)`: selects the tab, then opens the panel with its
    /// shown title and its color.
    pub(super) fn begin_rename_with(
        &mut self,
        id: TabId,
        color_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.state.selected() != Some(id) {
            self.select_tab(id, window, cx);
        }
        self.dismiss_hover_card(cx);
        self.close_other_panels(Some(PanelKind::Rename), cx);
        let title = self.tab_title(id, cx);
        let color = self
            .state
            .get(id)
            .map(|t| t.color)
            .unwrap_or(TabColor::Blue);
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("Tab name"))
                .default_value(title.clone())
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.commit_rename(window, cx),
                InputEvent::Focus => {
                    if let Some(rename) = this.rename.as_mut()
                        && rename.color_focus
                    {
                        rename.color_focus = false;
                        cx.notify();
                    }
                }
                _ => {}
            },
        );
        self.panel_generation += 1;
        self.rename = Some(RenameState {
            tab: id,
            input,
            color,
            original_title: title,
            color_focus,
            _subscription: subscription,
        });
        // A native Markdown editor may still own AppKit's first responder.
        // Focus both layers so typing reaches the selected rename field.
        crate::platform::terminal_focus::claim_gpui_keyboard(window);
        if color_focus {
            self.focus_handle.focus(window, cx);
        } else {
            self.focus_rename_title(window, cx);
        }
        cx.notify();
    }

    fn focus_rename_title(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(rename) = self.rename.as_mut() {
            rename.color_focus = false;
            rename.input.update(cx, |input, cx| {
                input.focus(window, cx);
                input.select_all(window, cx);
            });
        }
    }

    pub(super) fn commit_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(rename) = self.rename.take() {
            let text = rename.input.read(cx).value().to_string();
            if let Some(meta) = self.state.get_mut(rename.tab) {
                meta.apply_rename(&text, &rename.original_title, rename.color);
                log::info!(
                    "Tab rename commit: tab={} title={:?} color={}",
                    rename.tab,
                    meta.custom_title,
                    meta.color.name()
                );
            }
        }
        self.focus_selected(window, cx);
        cx.notify();
    }

    pub(super) fn cancel_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.rename = None;
        self.focus_selected(window, cx);
        cx.notify();
    }

    /// Keys while the color row has focus (the window root has keyboard
    /// focus then): arrows pick a color, Enter saves, Escape cancels.
    pub(super) fn rename_color_keys(
        &mut self,
        event: &gpui::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // This listener is attached to the Workspace and receives bubbled
        // events from its child title input. Keep color shortcuts active only
        // while the Workspace itself owns focus.
        if !self.focus_handle.is_focused(window)
            || !self.rename.as_ref().is_some_and(|r| r.color_focus)
        {
            return;
        }
        match event.keystroke.key.as_str() {
            "escape" => self.cancel_rename(window, cx),
            "enter" => self.commit_rename(window, cx),
            "left" => self.step_rename_color(-1, cx),
            "right" => self.step_rename_color(1, cx),
            "tab" => {
                // Tab moves to the title field.
                self.focus_rename_title(window, cx);
                cx.notify();
            }
            _ => return,
        }
        cx.stop_propagation();
    }

    /// Left and right arrows on the color row.
    fn step_rename_color(&mut self, delta: isize, cx: &mut Context<Self>) {
        if let Some(rename) = self.rename.as_mut() {
            let all = TabColor::ALL;
            let index = all.iter().position(|c| *c == rename.color).unwrap_or(0) as isize;
            rename.color = all[(index + delta).rem_euclid(all.len() as isize) as usize];
            cx.notify();
        }
    }

    pub(super) fn render_rename(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let rename = self.rename.as_ref()?;
        let selected_color = rename.color;
        let color_focus = rename.color_focus;
        let swatches = TabColor::ALL.into_iter().map(|color| {
            let chosen = color == selected_color;
            div()
                .id(("swatch", color as usize))
                .size(px(20.0))
                .rounded_full()
                .bg(tab_color(color))
                .border(px(if chosen { 2.5 } else { 1.5 }))
                .border_color(gpui::white().opacity(if chosen { 1.0 } else { 0.3 }))
                .on_click(cx.listener(move |this, _, _, cx| {
                    if let Some(rename) = this.rename.as_mut() {
                        rename.color = color;
                    }
                    cx.notify();
                }))
        });
        let content = div()
            .flex()
            .flex_col()
            .gap(px(10.0))
            .px_3()
            .pb_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(220.0))
                            .child(chrome_input(&rename.input, chrome)),
                    )
                    .child(button("rename-cancel", "Cancel", chrome, false).on_click(
                        cx.listener(|this, _, window, cx| this.cancel_rename(window, cx)),
                    ))
                    .child(button("rename-ok", "Save", chrome, true).on_click(
                        cx.listener(|this, _, window, cx| this.commit_rename(window, cx)),
                    )),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .p_1()
                    .rounded_md()
                    .when(color_focus, |d| d.border_1().border_color(chrome.accent))
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::tr("Color:")),
                    )
                    .children(swatches),
            )
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.cancel_rename(window, cx);
                }
            }))
            .into_any_element();
        Some(self.floating_panel(PanelKind::Rename, 520.0, chrome, content, cx))
    }
}

#[cfg(test)]
#[path = "rename_tests.rs"]
mod tests;

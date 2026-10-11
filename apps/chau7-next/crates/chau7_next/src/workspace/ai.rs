//! The workspace side of AI and monitoring: events from a tab's sessions
//! go to the AI event feed with the tab filled in, changed files feed the
//! conflict detector, an answered prompt clears the permission border, and
//! the "Explain This Error" panel (`ErrorExplanationView.swift`).

use std::collections::HashSet;

use chau7_next_core::ai::error_explainer::{can_apply, confidence_badge};
use chau7_next_core::llm_provider::{ExplanationConfidence, FixRiskLevel};
use chau7_next_core::monitoring::dev_server::DevServerInfo;
use gpui::{ClipboardItem, Context, Hsla, MouseButton, div, prelude::*, px};

use super::{AppData, Workspace};
use crate::ai::events_out::{self, tab_uuid};
use crate::ai::explain::{self, ExplainPanels, Phase};
use crate::ai::hub;
use crate::pane::PaneEvent;
use crate::tab_bar::{StyleColor, TabId, style_color};
use crate::theme::Chrome;

impl Workspace {
    /// `PaneEvent::Ai`, `ChangedFiles` and `PermissionResolved`.
    pub(super) fn handle_ai_pane_event(
        &mut self,
        id: TabId,
        event: &PaneEvent,
        cx: &mut Context<Self>,
    ) {
        match event {
            PaneEvent::Ai {
                event,
                notify,
                tab_name_as_tool,
            } => {
                let mut event = (**event).clone();
                if event.tab_id.is_none() {
                    event.tab_id = Some(tab_uuid(id));
                }
                if event.directory.is_none() {
                    event.directory = self
                        .entries
                        .get(&id)
                        .and_then(|e| e.panes.read(cx).focused_session(cx))
                        .and_then(|s| s.read(cx).cwd.clone())
                        .map(|p| p.to_string_lossy().into_owned());
                }
                if *tab_name_as_tool {
                    event.tool = self.tab_title(id, cx);
                }
                let notify = *notify;
                cx.defer(move |cx| events_out::publish(event, notify, cx));
            }
            PaneEvent::ChangedFiles(files) => {
                let files = files.clone();
                cx.defer(move |cx| {
                    let live: HashSet<TabId> = AppData::live(cx)
                        .into_iter()
                        .flat_map(|(_, ws)| ws.read(cx).entries.keys().copied().collect::<Vec<_>>())
                        .collect();
                    hub::record_changed_files(id, files, &live, cx);
                    cx.refresh_windows();
                });
            }
            PaneEvent::PermissionResolved => {
                self.clear_persistent_style(id, cx);
            }
            _ => {}
        }
    }

    /// A command finished in tab `id`: offer "Explain This Error" for a
    /// failure (setting `error_explain_enabled`).
    pub(super) fn offer_explain(&mut self, id: TabId, code: i32, cx: &mut Context<Self>) {
        let command = self
            .entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
            .and_then(|s| {
                s.read(cx)
                    .blocks()
                    .blocks()
                    .last()
                    .map(|b| b.command.clone())
            })
            .filter(|c| !c.trim().is_empty());
        explain::command_finished(id, code, command, cx);
        cx.notify();
    }

    /// The dev server of a tab's focused pane.
    pub(super) fn dev_server(&self, id: TabId, cx: &gpui::App) -> Option<DevServerInfo> {
        self.entries
            .get(&id)?
            .panes
            .read(cx)
            .focused_session(cx)?
            .read(cx)
            .dev_server()
            .cloned()
    }

    /// `DevServerBadge`: the selected tab's dev server, green capsule at
    /// the right end of the tab bar; a click opens its URL.
    pub(super) fn render_dev_server_capsule(
        &self,
        chrome: Chrome,
        cx: &gpui::App,
    ) -> Option<gpui::AnyElement> {
        let id = self.state.selected()?;
        let server = self.dev_server(id, cx)?;
        let url = server.url.clone();
        Some(
            div()
                .id("dev-server-capsule")
                .flex_shrink_0()
                .flex()
                .items_center()
                .gap(px(6.0))
                .px(px(10.0))
                .py(px(4.0))
                .rounded_full()
                .bg(gpui::hsla(0.36, 0.6, 0.45, 0.25))
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(chrome.text)
                .cursor_pointer()
                .child("▦")
                .child(server.name.clone())
                .when_some(server.port, |d, port| {
                    d.child(
                        div()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .text_color(chrome.text_muted)
                            .child(format!(":{port}")),
                    )
                })
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(move |_, _, cx| {
                    if let Some(url) = &url {
                        cx.open_url(url);
                    }
                })
                .into_any_element(),
        )
    }

    fn explain_now(&mut self, id: TabId, cx: &mut Context<Self>) {
        let Some(session) = self
            .entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
        else {
            return;
        };
        let output = session.read(cx).buffer_text();
        explain::explain(id, output, cx);
        cx.notify();
    }

    /// Apply: types the fix at the prompt of the tab's focused pane (not run).
    fn apply_fix(&mut self, id: TabId, command: String, cx: &mut Context<Self>) {
        if let Some(session) = self
            .entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
        {
            session.read(cx).write_input(command.as_bytes());
        }
        explain::dismiss(id, cx);
    }

    /// The explanation panel of the selected tab, bottom right of the
    /// terminal.
    pub(super) fn render_explain(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let id = self.state.selected()?;
        let state = cx.try_global::<ExplainPanels>()?.0.get(&id)?;
        let muted = chrome.text_muted;
        let mono = "Menlo";
        let color = |c: StyleColor| style_color(c, chrome.text);
        let dismiss = div()
            .id("explain-dismiss")
            .px_1()
            .rounded_sm()
            .text_color(muted)
            .cursor_pointer()
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .child("✕")
            .on_click(cx.listener(move |_, _, _, cx| explain::dismiss(id, cx)));
        let body: gpui::AnyElement = match &state.phase {
            Phase::Offer => div()
                .flex()
                .items_center()
                .gap_2()
                .text_xs()
                .child(
                    div()
                        .text_color(color(StyleColor::Red))
                        .child(format!("✗ Exit {}", state.exit_code)),
                )
                .child(
                    div()
                        .id("explain-start")
                        .px_2()
                        .py_0p5()
                        .rounded_md()
                        .border_1()
                        .border_color(chrome.border)
                        .cursor_pointer()
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .child(crate::l10n::tr("Explain This Error"))
                        .on_click(cx.listener(move |this, _, _, cx| this.explain_now(id, cx))),
                )
                .child(dismiss)
                .into_any_element(),
            Phase::Loading => div()
                .flex()
                .items_center()
                .gap_2()
                .font_family(mono)
                .text_sm()
                .text_color(muted)
                .child("◌")
                .child(crate::l10n::tr("Analyzing error..."))
                .into_any_element(),
            Phase::Failed(error) => div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().text_color(color(StyleColor::Yellow)).child("⚠"))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .font_family(mono)
                        .text_xs()
                        .text_color(muted)
                        .child(error.clone()),
                )
                .child(dismiss)
                .into_any_element(),
            Phase::Done { explanation, fixes } => {
                let badge_color: Hsla = match explanation.confidence {
                    ExplanationConfidence::High => color(StyleColor::Green),
                    ExplanationConfidence::Medium => color(StyleColor::Orange),
                    ExplanationConfidence::Low => color(StyleColor::Red),
                };
                let header = div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .px_1()
                            .rounded_sm()
                            .bg(badge_color.opacity(0.2))
                            .text_color(badge_color)
                            .font_family(mono)
                            .text_xs()
                            .font_weight(gpui::FontWeight::BOLD)
                            .child(confidence_badge(explanation.confidence)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .font_family(mono)
                            .text_sm()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(explanation.summary.clone()),
                    )
                    .child(dismiss);
                let details = div()
                    .font_family(mono)
                    .text_xs()
                    .text_color(muted)
                    .child(explanation.details.clone());
                let rows = fixes.iter().enumerate().map(|(index, fix)| {
                    let (shield, shield_color) = match fix.risk_level {
                        FixRiskLevel::Safe => ("✔", color(StyleColor::Green)),
                        FixRiskLevel::Moderate => ("!", color(StyleColor::Orange)),
                        FixRiskLevel::Dangerous => ("✕", color(StyleColor::Red)),
                    };
                    let command = fix.command.clone();
                    let apply = can_apply(fix.risk_level);
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(div().w(px(14.0)).text_color(shield_color).child(shield))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(
                                    div()
                                        .font_family(mono)
                                        .text_xs()
                                        .child(fix.description.clone()),
                                )
                                .child(
                                    div()
                                        .font_family(mono)
                                        .text_xs()
                                        .text_color(color(StyleColor::Blue))
                                        .child(fix.command.clone()),
                                ),
                        )
                        .child(
                            div()
                                .id(("explain-fix", index))
                                .px_2()
                                .py_0p5()
                                .rounded_md()
                                .border_1()
                                .border_color(chrome.border)
                                .text_xs()
                                .cursor_pointer()
                                .hover(|d| d.bg(chrome.tab_hover_bg))
                                .child(if apply { "Apply" } else { "Copy" })
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if apply {
                                        this.apply_fix(id, command.clone(), cx);
                                    } else {
                                        cx.write_to_clipboard(ClipboardItem::new_string(
                                            command.clone(),
                                        ));
                                    }
                                })),
                        )
                });
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(header)
                    .child(details)
                    .when(!fixes.is_empty(), |d| {
                        d.child(div().h(px(1.0)).bg(chrome.border)).children(rows)
                    })
                    .into_any_element()
            }
        };
        Some(
            div()
                .absolute()
                .right(px(12.0))
                .bottom(px(12.0))
                .max_w(px(520.0))
                .child(
                    div()
                        .id("explain-panel")
                        .occlude()
                        .p_3()
                        .rounded(px(8.0))
                        .bg(chrome.panel_bg)
                        .border_1()
                        .border_color(muted.opacity(0.3))
                        .shadow_lg()
                        .text_color(chrome.text)
                        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .child(body),
                )
                .into_any_element(),
        )
    }
}

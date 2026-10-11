//! Remote viewer status button and panel (`RemoteViewerStatusView.swift`,
//! RMT-028). The Swift view was never placed in a window; as designed
//! ("viewer count is shown in the status bar"), Chau7 Next shows the eye
//! button at the right end of the tab bar while viewer sharing is on, with
//! the panel in a popover. The same panel is in Settings > Remote Control.

use chau7_next_core::remote::viewer::RemoteViewerMode;
use chrono::{DateTime, Utc};
use gpui::{App, ClipboardItem, SharedString, div, prelude::*, px};
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::popover::Popover;

use crate::theme::Chrome;

fn small_button(
    id: impl Into<SharedString>,
    label: &'static str,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(gpui::ElementId::Name(id.into()))
        .px_1p5()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .border_1()
        .border_color(chrome.border)
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(label)
}

fn heading(title: &'static str, chrome: Chrome) -> gpui::Div {
    div().text_sm().text_color(chrome.text_muted).child(title)
}

/// The panel: sharing switch, share link, pending and connected viewers.
pub fn panel(viewer: &RemoteViewerMode, chrome: Chrome, now: DateTime<Utc>) -> gpui::Div {
    let sharing = viewer.is_sharing;
    let header = div()
        .flex()
        .items_center()
        .justify_between()
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(crate::l10n::tr("Remote Viewers")),
        )
        .child(
            div()
                .id("viewer-sharing")
                .w(px(34.0))
                .h(px(20.0))
                .rounded_full()
                .p(px(2.0))
                .flex()
                .cursor_pointer()
                .when(sharing, |d| d.justify_end())
                .bg(if sharing {
                    chrome.accent
                } else {
                    chrome.border
                })
                .child(div().size(px(16.0)).rounded_full().bg(gpui::white()))
                .on_click(move |_, _, cx| super::set_sharing(!sharing, cx)),
        );
    let mut body = div().flex().flex_col().gap_3().child(header);
    if !sharing {
        return body.child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr(
                    "Enable sharing to allow remote viewing of your terminal session.",
                )),
        );
    }

    if let Some(link) = viewer.share_link.clone() {
        body = body.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Share Link")),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .gap_2()
                        .child(
                            div()
                                .min_w_0()
                                .text_xs()
                                .font_family("Menlo")
                                .truncate()
                                .child(link.clone()),
                        )
                        .child(small_button("viewer-copy-link", "Copy", chrome).on_click(
                            move |_, _, cx: &mut App| {
                                cx.write_to_clipboard(ClipboardItem::new_string(link.clone()))
                            },
                        )),
                ),
        );
    }

    if !viewer.pending.is_empty() {
        let mut pending = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(heading("Pending Approval", chrome));
        for v in &viewer.pending {
            let (approve_id, deny_id) = (v.id.clone(), v.id.clone());
            pending = pending.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(div().text_xs().child(v.name.clone()))
                    .child(
                        div()
                            .flex()
                            .gap_1()
                            .child(
                                small_button(format!("viewer-approve-{}", v.id), "Approve", chrome)
                                    .text_color(gpui::green())
                                    .on_click(move |_, _, cx| {
                                        super::update_viewer(cx, |m| {
                                            m.approve(&approve_id, Utc::now());
                                        })
                                    }),
                            )
                            .child(
                                small_button(format!("viewer-deny-{}", v.id), "Deny", chrome)
                                    .text_color(chrome.danger)
                                    .on_click(move |_, _, cx| {
                                        super::update_viewer(cx, |m| m.deny(&deny_id))
                                    }),
                            ),
                    ),
            );
        }
        body = body.child(pending);
    }

    let mut connected = div().flex().flex_col().gap_1().child(
        div()
            .flex()
            .items_center()
            .gap_1p5()
            .child(heading("Connected", chrome))
            .child(div().text_xs().text_color(chrome.text_muted).child(format!(
                "({}/{})",
                viewer.connected.len(),
                viewer.max_viewers()
            ))),
    );
    if viewer.connected.is_empty() {
        connected = connected.child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr("No viewers connected")),
        );
    }
    for v in &viewer.connected {
        let known = viewer.known_ids.contains(&v.id);
        let (trust_id, drop_id) = (v.id.clone(), v.id.clone());
        connected = connected.child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().size(px(6.0)).rounded_full().bg(gpui::green()))
                .child(div().flex_1().text_xs().child(v.name.clone()))
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .text_color(chrome.text_muted)
                        .child(v.connection_duration(now)),
                )
                .child(
                    small_button(
                        format!("viewer-trust-{}", v.id),
                        if known { "Revoke" } else { "Trust" },
                        chrome,
                    )
                    .on_click(move |_, _, cx| {
                        super::update_viewer(cx, |m| {
                            if known {
                                m.revoke(&trust_id)
                            } else {
                                m.trust(&trust_id)
                            }
                        })
                    }),
                )
                .child(
                    small_button(format!("viewer-disconnect-{}", v.id), "Disconnect", chrome)
                        .on_click(move |_, _, cx| {
                            super::update_viewer(cx, |m| m.disconnect(&drop_id))
                        }),
                ),
        );
    }
    body.child(connected)
}

/// The eye button with the viewer count and an orange dot for pending
/// viewers, shown while viewer sharing is enabled.
pub fn title_bar_button(chrome: Chrome, cx: &App) -> Option<gpui::AnyElement> {
    let status = super::status(cx)?;
    let viewer = status.viewer;
    if !viewer.enabled {
        return None;
    }
    let mut label = String::from("👁");
    if !viewer.connected.is_empty() {
        label.push_str(&format!(" {}", viewer.connected.len()));
    }
    if !viewer.pending.is_empty() {
        label.push_str(" \u{2022}");
    }
    let trigger = Button::new("remote-viewer-button")
        .ghost()
        .xsmall()
        .label(label)
        .when(viewer.is_sharing, |b| b.text_color(chrome.accent));
    Some(
        Popover::new("remote-viewer-popover")
            .anchor(gpui::Anchor::TopRight)
            .trigger(trigger)
            .content(move |_, _, cx| {
                let viewer = super::status(cx).map(|s| s.viewer).unwrap_or_default();
                div()
                    .w(px(320.0))
                    .p_2()
                    .child(panel(&viewer, chrome, Utc::now()))
            })
            .into_any_element(),
    )
}

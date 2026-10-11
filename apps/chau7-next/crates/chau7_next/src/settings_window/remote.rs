//! Remote Control (`RemoteSettingsView.swift`): agent status, the enable
//! switch, the relay URL, pairing (code, copy, regenerate) and paired
//! devices with revoke. Below them, read-only viewer sharing
//! (`RemoteViewerStatusView.swift`, never shown by the Swift app).

use chau7_next_core::remote::agent_state::AgentPairedDevice;
use chrono::Utc;
use gpui::{
    App, ClipboardItem, Context, Entity, PromptLevel, SharedString, Subscription, Window, div,
    prelude::*,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{button, description, row, section as titled, stepper, toggle};
use super::{SectionContext, SettingsView, update};
use crate::remote::{self, RemoteStatus};
use crate::settings::Settings;

/// The relay URL field.
pub(crate) struct RemoteInputs {
    relay: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl RemoteInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let value = Settings::get(cx).remote.relay_url.clone();
        let relay = cx.new(|cx| InputState::new(window, cx).default_value(value));
        let subscription = cx.subscribe(&relay, |_, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                let value = input.read(cx).value().trim().to_string();
                if value != Settings::get(cx).remote.relay_url {
                    update(cx, |s| s.remote.relay_url = value);
                }
            }
        });
        Self {
            relay,
            _subscriptions: vec![subscription],
        }
    }
}

fn caption(text: impl Into<SharedString>, ctx: &SectionContext) -> gpui::Div {
    div()
        .text_xs()
        .text_color(ctx.chrome.text_muted)
        .child(text.into())
}

fn copy(text: String, cx: &mut App) {
    cx.write_to_clipboard(ClipboardItem::new_string(text));
}

/// Status, access, relay, pairing and paired devices.
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let status = ctx.remote.clone().unwrap_or(RemoteStatus {
        agent_running: false,
        ipc_connected: false,
        session_status: None,
        last_error: None,
        pairing_info: None,
        devices: Vec::new(),
        viewer: Default::default(),
    });

    // Status
    let mut detail = div().flex().flex_col().items_end().gap_0p5().child(
        div()
            .text_sm()
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .child(if status.agent_running {
                "Running"
            } else {
                "Stopped"
            }),
    );
    if let Some(error) = status.last_error.as_ref().filter(|e| !e.is_empty()) {
        detail = detail.child(caption(error.clone(), ctx));
    } else if let Some(session) = status.session_status.as_ref().filter(|s| !s.is_empty()) {
        detail = detail.child(caption(format!("Session: {session}"), ctx));
        if let Some((device, _)) = status.devices.iter().find(|(_, connected)| *connected) {
            detail = detail.child(caption(
                format!("Connected device: {}", device.display_name()),
                ctx,
            ));
        }
    } else {
        detail = detail.child(caption(
            if status.ipc_connected {
                "IPC connected"
            } else {
                "IPC not connected"
            },
            ctx,
        ));
    }
    let status_block = titled("Status", chrome).child(row("Remote Agent", detail, chrome));

    // Access and relay
    let access = titled("Remote Access", chrome)
        .child(row(
            "Enable Remote Control",
            toggle(
                "remote-enabled",
                ctx.settings.remote.enabled,
                chrome,
                |s, v| s.remote.enabled = v,
            ),
            chrome,
        ))
        .child(description(
            "Allow Chau7 Next to be controlled from the iOS app",
            chrome,
        ));
    let relay = titled("Relay", chrome)
        .child(row(
            "Relay URL",
            div()
                .w(gpui::px(360.0))
                .child(Input::new(&ctx.view.remote_inputs.relay)),
            chrome,
        ))
        .child(description("WebSocket relay base URL", chrome));

    // Pairing
    let mut pairing = titled("Pairing", chrome);
    match &status.pairing_info {
        Some(info) => {
            let json = info.qr_payload_string();
            let code = info.pairing_code.clone();
            pairing = pairing
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .child(format!("Device ID: {}", info.device_id)),
                )
                .child(
                    div()
                        .text_lg()
                        .font_family("Menlo")
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .child(format!("Pairing Code: {}", info.pairing_code)),
                )
                .child(caption(format!("Expires: {}", info.expires_at), ctx))
                .child(caption(format!("Relay: {}", info.relay_url), ctx))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            button("remote-copy-json", "Copy Pairing JSON", chrome)
                                .on_click(move |_, _, cx| copy(json.clone(), cx)),
                        )
                        .child(
                            button("remote-copy-code", "Copy Pairing Code", chrome)
                                .on_click(move |_, _, cx| copy(code.clone(), cx)),
                        )
                        .child(
                            button("remote-regenerate", "Regenerate", chrome)
                                .on_click(|_, _, cx| remote::regenerate(cx)),
                        ),
                );
        }
        None => {
            pairing = pairing.child(caption(
                "Pairing info will appear once the remote agent connects.",
                ctx,
            ));
        }
    }

    // Paired devices
    let mut devices = titled("Paired Devices", chrome);
    if status.devices.is_empty() {
        devices = devices.child(caption("No paired devices yet.", ctx));
    }
    for (index, (device, connected)) in status.devices.iter().enumerate() {
        devices = devices.child(device_row(index, device, *connected, ctx));
    }

    div()
        .flex()
        .flex_col()
        .child(status_block)
        .child(access)
        .child(relay)
        .child(pairing)
        .child(devices)
}

fn device_row(
    index: usize,
    device: &AgentPairedDevice,
    connected: bool,
    ctx: &SectionContext,
) -> gpui::Div {
    let chrome = ctx.chrome;
    let mut info = div()
        .flex()
        .flex_col()
        .gap_0p5()
        .child(
            div()
                .flex()
                .gap_2()
                .items_center()
                .child(
                    div()
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .child(device.display_name()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(if connected {
                            gpui::green()
                        } else {
                            chrome.text_muted
                        })
                        .child(if connected {
                            "Connected"
                        } else {
                            "Not Connected"
                        }),
                ),
        )
        .child(
            div()
                .text_xs()
                .font_family("Menlo")
                .text_color(chrome.text_muted)
                .child(format!("Fingerprint: {}", device.display_fingerprint())),
        );
    if let Some(paired) = &device.paired_at {
        info = info.child(caption(format!("Paired: {paired}"), ctx));
    }
    if let Some(last) = &device.last_connected_at {
        info = info.child(caption(format!("Last connected: {last}"), ctx));
    }
    let id = device.id.clone();
    let name = device.display_name();
    div()
        .flex()
        .items_start()
        .justify_between()
        .gap_3()
        .py_1p5()
        .when(index > 0, |d| d.border_t_1().border_color(chrome.border))
        .child(info)
        .child(
            button(
                SharedString::from(format!("remote-revoke-{index}")),
                "Revoke",
                chrome,
            )
            .text_color(chrome.danger)
            .on_click(move |_, window, cx| confirm_revoke(id.clone(), &name, window, cx)),
        )
}

/// "Revoke Pairing?" (confirmation dialog of the Swift view).
fn confirm_revoke(id: String, name: &str, window: &mut Window, cx: &mut App) {
    let message =
        format!("This will remove {name} and force it to pair again before it can reconnect.");
    let answer = crate::l10n::prompt(
        window,
        PromptLevel::Warning,
        "Revoke Pairing?",
        Some(&message),
        &["Revoke Device", "Cancel"],
        cx,
    );
    cx.spawn(async move |cx| {
        if answer.await.ok() == Some(0) {
            cx.update(|cx| remote::revoke_device(id, cx));
        }
    })
    .detach();
}

/// Read-only viewer sharing: the feature switch, its options, and the
/// viewer panel (share link, pending and connected viewers).
pub(super) fn viewers(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let r = &ctx.settings.remote;
    let mut block = titled("Remote Viewers", chrome)
        .child(row(
            "Read-Only Viewer Sharing",
            toggle("remote-viewer-enabled", r.viewer_enabled, chrome, |s, v| {
                s.remote.viewer_enabled = v
            }),
            chrome,
        ))
        .child(description(
            "Share a link so others can watch your terminal without typing in it. You approve each viewer.",
            chrome,
        ));
    if !r.viewer_enabled {
        return block;
    }
    block = block
        .child(row(
            "Maximum Viewers",
            stepper(
                "remote-viewer-max",
                r.viewer_max.to_string(),
                chrome,
                |s, d| s.remote.viewer_max = (s.remote.viewer_max as i32 + d).clamp(1, 10) as u32,
            ),
            chrome,
        ))
        .child(row(
            "Auto-Approve Known Viewers",
            toggle(
                "remote-viewer-auto",
                r.viewer_auto_approve_known,
                chrome,
                |s, v| s.remote.viewer_auto_approve_known = v,
            ),
            chrome,
        ));
    let Some(status) = &ctx.remote else {
        return block;
    };
    block.child(remote::viewer_ui::panel(&status.viewer, chrome, Utc::now()))
}

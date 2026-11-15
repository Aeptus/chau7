//! Remote Control (`RemoteSettingsView.swift`): agent status, the enable
//! switch, the relay URL, pairing (a QR the phone scans, refresh) and paired
//! devices with revoke. Below them, read-only viewer sharing
//! (`RemoteViewerStatusView.swift`, never shown by the Swift app).

use chau7_next_core::remote::agent_state::AgentPairedDevice;
use chau7_next_core::remote::models::RemotePairingInfo;
use chrono::DateTime;
use chrono::Utc;
use gpui::{
    App, Context, Entity, PromptLevel, SharedString, Subscription, Window, div, prelude::*,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{button, description, row, section as titled, stepper, toggle};
use super::{SectionContext, SettingsView, update};
use crate::l10n::{l, lf};
use crate::remote::agent::AgentExit;
use crate::remote::{self, AgentState, RemoteStatus};
use crate::settings::{Settings, is_placeholder_relay_url};
use chau7_next_core::l10n::Arg;

/// The relay URL field.
pub(crate) struct RemoteInputs {
    relay: Entity<InputState>,
    pub(super) pairing: Entity<super::pairing_qr::PairingQrView>,
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
            pairing: cx.new(|_| super::pairing_qr::PairingQrView::default()),
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

/// The agent's state in the Status row.
fn agent_state_text(state: AgentState) -> String {
    match state {
        AgentState::Running => l("status.running", "Running"),
        AgentState::Starting => l("status.starting", "Starting..."),
        AgentState::Stopped => l("status.stopped", "Stopped"),
        AgentState::Restarting { seconds } => lf(
            "settings.remote.agent.restarting",
            "Restarting in %d s",
            &[Arg::Int(i64::try_from(seconds).unwrap_or(i64::MAX))],
        ),
    }
}

/// How the agent last ended on its own.
fn agent_exit_text(exit: AgentExit) -> String {
    match exit {
        AgentExit::Code(code) => lf(
            "settings.remote.agent.lastExit.status",
            "Last exit: status %d",
            &[Arg::Int(i64::from(code))],
        ),
        AgentExit::Signal(signal) => lf(
            "settings.remote.agent.lastExit.signal",
            "Last exit: signal %d",
            &[Arg::Int(i64::from(signal))],
        ),
        AgentExit::Unknown => l(
            "settings.remote.agent.lastExit.unknown",
            "Last exit: unknown reason",
        ),
    }
}

/// What the Pairing block shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PairingDisplay {
    /// No relay URL of the user's own yet: no QR, no code, only what to do.
    RelayUnset,
    /// Nothing to pair with yet: the agent is not running and connected, or
    /// has not sent a code. A code left by an earlier agent is not shown.
    Waiting,
    /// The code is past its expiry (or has none that can be read): it is not
    /// shown; the agent issues a new one.
    Expired,
    /// The QR and the pairing details.
    Ready,
}

pub(super) fn pairing_display(
    relay_url: &str,
    agent_connected: bool,
    info: Option<&RemotePairingInfo>,
    now: DateTime<Utc>,
) -> PairingDisplay {
    if is_placeholder_relay_url(relay_url) {
        return PairingDisplay::RelayUnset;
    }
    let Some(info) = info.filter(|_| agent_connected) else {
        return PairingDisplay::Waiting;
    };
    match DateTime::parse_from_rfc3339(&info.expires_at) {
        Ok(expiry) if expiry.to_utc() > now => PairingDisplay::Ready,
        _ => PairingDisplay::Expired,
    }
}

/// Status, access, relay, pairing and paired devices.
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let status = ctx.remote.clone().unwrap_or(RemoteStatus {
        agent_running: false,
        agent: AgentState::Stopped,
        last_exit: None,
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
            .child(agent_state_text(status.agent)),
    );
    if let Some(exit) = status
        .last_exit
        .filter(|_| status.agent != AgentState::Running)
    {
        detail = detail.child(caption(agent_exit_text(exit), ctx));
    }
    let relay_unset = is_placeholder_relay_url(&ctx.settings.remote.relay_url);
    if ctx.settings.remote.enabled && relay_unset {
        detail = detail.child(caption(
            l(
                "settings.remote.agent.needsRelay",
                "Not started: no relay URL set",
            ),
            ctx,
        ));
    } else if let Some(error) = status.last_error.as_ref().filter(|e| !e.is_empty()) {
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
        .child(if relay_unset {
            description(
                l(
                    "settings.remote.relayUrl.unset",
                    "Enter the WebSocket URL of your own relay. Relay URLs are specific to you, so there is no default.",
                ),
                chrome,
            )
        } else {
            description("WebSocket relay base URL", chrome)
        });

    // Pairing
    let mut pairing = titled("Pairing", chrome);
    let display = pairing_display(
        &ctx.settings.remote.relay_url,
        status.agent_running && status.ipc_connected,
        status.pairing_info.as_ref(),
        Utc::now(),
    );
    let refresh = || {
        button("remote-regenerate", "Refresh QR Code", chrome)
            .on_click(|_, _, cx| remote::regenerate(cx))
    };
    match (display, status.pairing_info.as_ref()) {
        (PairingDisplay::RelayUnset, _) => {
            pairing = pairing.child(caption(
                l(
                    "settings.remote.pairing.needsRelay",
                    "Set your relay URL above to pair an iPhone. No pairing QR code is shown until then.",
                ),
                ctx,
            ));
        }
        (PairingDisplay::Ready, Some(info)) => {
            let line = |key: &str, default: &str, value: &str| {
                lf(key, default, &[Arg::Str(value.to_string())])
            };
            pairing = pairing
                .child(ctx.view.remote_inputs.pairing.clone())
                .child(div().text_xs().font_family("Menlo").child(line(
                    "remote.deviceId",
                    "Device ID: %@",
                    &info.device_id,
                )))
                .child(caption(
                    line("remote.expiresAt", "Expires: %@", &info.expires_at),
                    ctx,
                ))
                .child(caption(
                    line("remote.relayUrl", "Relay: %@", &info.relay_url),
                    ctx,
                ))
                .child(div().flex().gap_2().child(refresh()));
        }
        // The QR view says the code expired; no stale code or expiry is shown.
        (PairingDisplay::Expired, _) => {
            pairing = pairing
                .child(ctx.view.remote_inputs.pairing.clone())
                .child(div().flex().gap_2().child(refresh()));
        }
        (PairingDisplay::Waiting | PairingDisplay::Ready, _) => {
            pairing = pairing.child(caption(
                l(
                    "settings.remote.pairing.waiting",
                    "The pairing QR code appears once the remote agent is running and connected.",
                ),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::RemoteSettings;

    #[test]
    fn agent_state_and_last_exit_have_text_in_every_language() {
        use chau7_next_core::l10n::{Lang, localized_format, table};
        for lang in Lang::ALL {
            let restarting = localized_format(
                lang,
                "settings.remote.agent.restarting",
                "",
                &[Arg::Int(42)],
            );
            assert!(restarting.contains("42"), "{}: {restarting}", lang.code());
            for key in [
                "settings.remote.agent.lastExit.status",
                "settings.remote.agent.lastExit.signal",
            ] {
                let text = localized_format(lang, key, "", &[Arg::Int(137)]);
                assert!(text.contains("137"), "{}: {text}", lang.code());
            }
            assert!(!table(lang)["settings.remote.agent.lastExit.unknown"].is_empty());
        }
        assert_eq!(
            localized_format(
                Lang::En,
                "settings.remote.agent.restarting",
                "",
                &[Arg::Int(8)]
            ),
            "Restarting in 8 s"
        );
        assert_eq!(
            localized_format(
                Lang::En,
                "settings.remote.agent.lastExit.status",
                "",
                &[Arg::Int(1)]
            ),
            "Last exit: status 1"
        );
    }

    fn info(expires_at: &str) -> RemotePairingInfo {
        RemotePairingInfo {
            device_id: "fixture-device".into(),
            mac_pub: "fixture-public-key".into(),
            pairing_code: "123456".into(),
            expires_at: expires_at.into(),
            relay_url: "wss://relay.test/connect".into(),
            relay_key_id: None,
            relay_secret: None,
            pairing_key: None,
            relay_pair_id: None,
            relay_pair_secret: None,
        }
    }

    #[test]
    fn no_pairing_qr_or_code_while_the_relay_url_is_empty_or_the_placeholder() {
        let now = Utc::now();
        let fresh = info(&(now + chrono::Duration::minutes(10)).to_rfc3339());
        let placeholder = RemoteSettings::default().relay_url;
        for url in ["", "  ", placeholder.as_str()] {
            // Even pairing info left over from an earlier agent is not shown.
            assert_eq!(
                pairing_display(url, true, Some(&fresh), now),
                PairingDisplay::RelayUnset
            );
            assert_eq!(
                pairing_display(url, false, None, now),
                PairingDisplay::RelayUnset
            );
        }
        let own = "wss://relay.test/connect";
        assert_eq!(
            pairing_display(own, true, None, now),
            PairingDisplay::Waiting
        );
        assert_eq!(
            pairing_display(own, true, Some(&fresh), now),
            PairingDisplay::Ready
        );
    }

    #[test]
    fn an_expired_or_orphaned_pairing_code_is_never_shown() {
        let own = "wss://relay.test/connect";
        let issued = DateTime::parse_from_rfc3339("2026-10-10T10:00:00Z")
            .unwrap()
            .to_utc();
        let code = info("2026-10-10T10:10:00Z");
        let at = |minutes: i64| issued + chrono::Duration::minutes(minutes);
        assert_eq!(
            pairing_display(own, true, Some(&code), at(9)),
            PairingDisplay::Ready
        );
        // Codes last 10 minutes: at the expiry and after, it is not shown.
        assert_eq!(
            pairing_display(own, true, Some(&code), at(10)),
            PairingDisplay::Expired
        );
        assert_eq!(
            pairing_display(own, true, Some(&code), at(45)),
            PairingDisplay::Expired
        );
        // An expiry that cannot be read is not trusted.
        assert_eq!(
            pairing_display(own, true, Some(&info("soon")), at(0)),
            PairingDisplay::Expired
        );
        // The agent stopped or disconnected: its last code is not shown.
        assert_eq!(
            pairing_display(own, false, Some(&code), at(1)),
            PairingDisplay::Waiting
        );
    }
}

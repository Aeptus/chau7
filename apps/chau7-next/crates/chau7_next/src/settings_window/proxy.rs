//! API Analytics (`ProxySettingsView.swift`): the proxy switch and status,
//! privacy options, port, data folder buttons, the TLS certificate trust
//! (Chau7 Next's own entry), supported tools and how it works.

use gpui::{
    App, Context, Entity, PromptLevel, SharedString, Subscription, Window, div, prelude::*,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{button, description, row, section as titled, toggle};
use super::{SectionContext, SettingsView, set_message, update};
use crate::platform::cert_trust;
use crate::proxy::{self, ProxyStatus};
use crate::settings::Settings;
use crate::workspace::AppData;

/// The port field.
pub(crate) struct ProxyInputs {
    port: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl ProxyInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let value = Settings::get(cx).proxy.port.to_string();
        let port = cx.new(|cx| InputState::new(window, cx).default_value(value));
        let subscription =
            cx.subscribe_in(&port, window, |_, input, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    let text = input.read(cx).value().trim().to_string();
                    let current = Settings::get(cx).proxy.port;
                    // Not a number: back to the current port (`format: .number`).
                    let port = text
                        .parse::<i64>()
                        .map(chau7_next_core::proxy::clamp_port)
                        .unwrap_or(current);
                    if port.to_string() != text {
                        input.update(cx, |state, cx| {
                            state.set_value(port.to_string(), window, cx)
                        });
                    }
                    if port != current {
                        update(cx, |s| s.proxy.port = port);
                    }
                }
            });
        Self {
            port,
            _subscriptions: vec![subscription],
        }
    }
}

fn dot(color: gpui::Hsla) -> gpui::Div {
    div().size(gpui::px(8.0)).rounded_full().bg(color)
}

/// PRX-015: Disabled, Starting..., Running on port N, or the error.
fn status_view(status: &ProxyStatus, ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let orange = gpui::hsla(0.08, 0.9, 0.55, 1.0);
    let (color, text): (gpui::Hsla, String) = match status {
        ProxyStatus::Disabled => (chrome.text_muted, "Disabled".into()),
        ProxyStatus::Starting => (orange, "Starting...".into()),
        ProxyStatus::Running(port) => (gpui::green(), format!("Running on port {port}")),
        ProxyStatus::Error(message) => (chrome.danger, message.clone()),
    };
    div()
        .flex()
        .items_center()
        .gap_1()
        .child(dot(color))
        .child(div().text_sm().text_color(color).child(text))
}

fn code(text: &'static str, ctx: &SectionContext) -> gpui::Div {
    div()
        .px_1p5()
        .py_0p5()
        .rounded_sm()
        .bg(ctx.chrome.text_muted.opacity(0.1))
        .text_xs()
        .font_family("Menlo")
        .child(text)
}

fn tool_row(name: &'static str, full: bool, ctx: &SectionContext) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .gap_1p5()
        .text_sm()
        .child(
            div()
                .text_color(if full {
                    gpui::green()
                } else {
                    gpui::hsla(0.08, 0.9, 0.55, 1.0)
                })
                .child(if full { "\u{2714}" } else { "\u{26a0}" }),
        )
        .child(div().text_color(ctx.chrome.text).child(name))
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let p = &ctx.settings.proxy;
    let status = ctx.proxy_status.clone().unwrap_or(ProxyStatus::Disabled);

    let mut tracking = titled("API Call Tracking", chrome)
        .child(row(
            "Enable API Analytics",
            toggle("proxy-enabled", p.enabled, chrome, |s, v| s.proxy.enabled = v),
            chrome,
        ))
        .child(description(
            "Route LLM API calls through a local proxy to capture token usage, costs, and latency metrics. Authentication is handled by CLI tools - no API keys are stored by Chau7 Next.",
            chrome,
        ))
        .child(row("Status", status_view(&status, ctx), chrome));
    // PRX-019: today's numbers from the proxy (`GET /stats`).
    if matches!(status, ProxyStatus::Running(_))
        && let Some(stats) = &ctx.proxy_stats
    {
        tracking = tracking.child(description(
            format!(
                "Today: {} calls, {} tokens, {}, avg latency {}",
                stats.call_count,
                chau7_next_core::proxy::format_grouped(stats.total_tokens()),
                chau7_next_core::proxy::format_cost(stats.total_cost),
                chau7_next_core::proxy::format_latency(stats.average_latency_ms.round() as i64),
            ),
            chrome,
        ));
    }

    tracking = tracking.child(
        button("proxy-open-analytics", "Open API Analytics", chrome)
            .on_click(|_, _, cx| proxy::analytics::open(cx)),
    );

    let privacy = titled("Privacy", chrome)
        .child(row(
            "Log Prompt Previews",
            toggle("proxy-log-prompts", p.log_prompts, chrome, |s, v| {
                s.proxy.log_prompts = v
            }),
            chrome,
        ))
        .child(description(
            "Store the first 500 characters of prompts and responses for debugging. Disable for maximum privacy.",
            chrome,
        ))
        .child(row(
            "Route OpenAI-Compatible Clients",
            toggle("proxy-include-openai", p.include_openai, chrome, |s, v| {
                s.proxy.include_openai = v
            }),
            chrome,
        ))
        .child(description(
            "Inject OPENAI_BASE_URL so Codex CLI and other OpenAI-compatible clients are routed through the proxy. Disable if you only want Anthropic and Gemini analytics.",
            chrome,
        ));

    let advanced = titled("Advanced", chrome)
        .child(row(
            "Port",
            div()
                .w(gpui::px(90.0))
                .child(Input::new(&ctx.view.proxy_inputs.port)),
            chrome,
        ))
        .child(description(
            format!(
                "Local proxy port for intercepting API calls (TLS on port {}). Chau7 uses 18080; Chau7 Next has its own port so both can run.",
                chau7_next_core::proxy::tls_port(p.port)
            ),
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .pt_1()
                .child(
                    button("proxy-open-folder", "Open Database Folder", chrome)
                        .on_click(|_, _, cx| proxy::open_database_folder(cx)),
                )
                .child(
                    button("proxy-clear-data", "Clear All Data", chrome)
                        .on_click(|_, window, cx| confirm_clear(window, cx)),
                ),
        );

    // PRX-005: the proxy's own certificate, trusted for Codex over TLS.
    let cert_path = ctx.root.proxy_tls_cert();
    let certificate = titled("TLS Certificate", chrome)
        .child(description(
            format!(
                "OpenAI-compatible clients reach the proxy over TLS with a self-signed certificate, created by the proxy at {}. Trust it in your login keychain so they accept it.",
                cert_path.display()
            ),
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .pt_1()
                .child(
                    button("proxy-trust-cert", "Trust Certificate", chrome)
                        .on_click(|_, _, cx| change_trust(true, cx)),
                )
                .child(
                    button("proxy-check-cert", "Check Trust", chrome)
                        .on_click(|_, _, cx| check_trust(cx)),
                )
                .child(
                    button("proxy-untrust-cert", "Remove Trust", chrome)
                        .on_click(|_, _, cx| change_trust(false, cx)),
                ),
        );

    let tools = titled("Supported Tools", chrome)
        .child(tool_row("Claude Code", true, ctx))
        .child(tool_row("Codex CLI", true, ctx))
        .child(tool_row("Gemini CLI", false, ctx))
        .child(tool_row("Aider", true, ctx))
        .child(tool_row("Cursor", true, ctx))
        .child(description(
            "Gemini CLI support is partial - may not work when Google OAuth session is cached.",
            chrome,
        ));

    let how = titled("How It Works", chrome)
        .child(description(
            "When enabled, Chau7 Next sets environment variables to route API calls:",
            chrome,
        ))
        .child(
            div()
                .flex()
                .flex_col()
                .items_start()
                .gap_1()
                .py_1()
                .child(code("ANTHROPIC_BASE_URL", ctx))
                .child(code("OPENAI_BASE_URL", ctx))
                .child(code("GOOGLE_GEMINI_BASE_URL", ctx)),
        )
        .child(description(
            "OpenAI SDKs expect OPENAI_BASE_URL to include /v1. Chau7 Next sets this automatically.",
            chrome,
        ))
        .child(description(
            "The proxy logs metadata (model, tokens, latency) then forwards requests to the real APIs. Auth headers pass through unchanged.",
            chrome,
        ));

    div()
        .flex()
        .flex_col()
        .child(tracking)
        .child(privacy)
        .child(advanced)
        .child(certificate)
        .child(tools)
        .child(how)
}

/// "Clear Analytics Data" confirmation (PRX-017).
fn confirm_clear(window: &mut Window, cx: &mut App) {
    let answer = crate::l10n::prompt(
        window,
        PromptLevel::Warning,
        "Clear Analytics Data",
        Some("This will delete all captured API call data. This action cannot be undone."),
        &["Clear All", "Cancel"],
        cx,
    );
    cx.spawn(async move |cx| {
        if answer.await.ok() == Some(0) {
            cx.update(proxy::clear_all_data);
        }
    })
    .detach();
}

fn certificate_der(cx: &App) -> Result<Vec<u8>, String> {
    let path = cx.global::<AppData>().root.proxy_tls_cert();
    let pem = std::fs::read_to_string(&path).map_err(|_| {
        "No certificate yet: enable API Analytics once so the proxy creates it.".to_string()
    })?;
    cert_trust::pem_to_der(&pem).ok_or_else(|| "The proxy certificate is not valid PEM.".into())
}

fn check_trust(cx: &mut App) {
    let result =
        certificate_der(cx).and_then(|der| cert_trust::is_trusted(&der).map_err(|e| e.to_string()));
    let (text, error) = match result {
        Ok(true) => ("The proxy certificate is trusted.".to_string(), false),
        Ok(false) => (
            "The proxy certificate is not trusted yet.".to_string(),
            false,
        ),
        Err(err) => (err, true),
    };
    set_message(cx, text, error);
}

fn change_trust(trust: bool, cx: &mut App) {
    let der = match certificate_der(cx) {
        Ok(der) => der,
        Err(err) => {
            set_message(cx, err, true);
            return;
        }
    };
    // The keychain shows a password prompt: keep it off the UI thread.
    let task = cx.background_spawn(async move {
        if trust {
            cert_trust::trust(&der)
        } else {
            cert_trust::remove_trust(&der)
        }
    });
    cx.spawn(async move |cx| {
        let result = task.await;
        cx.update(|cx| {
            let (text, error): (SharedString, bool) = match result {
                Ok(()) if trust => ("The proxy certificate is now trusted.".into(), false),
                Ok(()) => ("Trust removed from the proxy certificate.".into(), false),
                Err(err) => (format!("Certificate trust: {err}").into(), true),
            };
            set_message(cx, text.to_string(), error);
        });
    })
    .detach();
}

//! AI Integration (`AIIntegrationSettingsView.swift`, `LLMSettingsView.swift`):
//! custom detection rules, the LLM provider with its API key in the
//! Keychain and "Test Connection", the "Explain This Error" switch, and the
//! list of built-in detected CLIs.

use chau7_next_core::ai::llm_client::{test_connection_request, test_connection_result};
use chau7_next_core::l10n::numbers::RegionalNumberFormat;
use chau7_next_core::llm_provider::LLMProviderType;
use chau7_next_core::tabs_state::TabColor;
use gpui::{App, Context, Entity, SharedString, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{button, chip, description, row, section as titled, toggle};
use super::{SectionContext, SettingsView, update};
use crate::ai::llm;
use crate::settings::{CustomAiRule, Settings};
use crate::theme::tab_color;

/// Text fields and transient state of this section.
pub(crate) struct AiInputs {
    pattern: Entity<InputState>,
    name: Entity<InputState>,
    api_key: Entity<InputState>,
    endpoint: Entity<InputState>,
    model: Entity<InputState>,
    max_tokens: Entity<InputState>,
    /// Color of the rule being added (gray by default).
    new_color: TabColor,
    /// "OK: <model>" or "Error: ..." of the last test.
    test_result: Option<String>,
    testing: bool,
    /// Feedback of the key Save button.
    key_saved: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl AiInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let ai = Settings::get(cx).ai.clone();
        let provider = ai.llm_provider;
        let field = |value: String,
                     placeholder: String,
                     window: &mut Window,
                     cx: &mut Context<SettingsView>| {
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder)
                    .default_value(value)
            })
        };
        let pattern = field(String::new(), "Pattern".into(), window, cx);
        let name = field(String::new(), "Name".into(), window, cx);
        let api_key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .default_value(llm::api_key(provider))
        });
        let endpoint = field(
            ai.llm_endpoint.clone(),
            provider.default_endpoint().into(),
            window,
            cx,
        );
        let model = field(
            ai.llm_model.clone(),
            provider.default_model().into(),
            window,
            cx,
        );
        let max_tokens = field(ai.llm_max_tokens.to_string(), "1024".into(), window, cx);
        let on_commit = |apply: fn(&mut Settings, String)| {
            move |_: &mut SettingsView,
                  input: Entity<InputState>,
                  event: &InputEvent,
                  cx: &mut Context<SettingsView>| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    let value = input.read(cx).value().trim().to_string();
                    update(cx, |s| apply(s, value));
                }
            }
        };
        let subscriptions = vec![
            cx.subscribe(&endpoint, on_commit(|s, v| s.ai.llm_endpoint = v)),
            cx.subscribe(&model, on_commit(|s, v| s.ai.llm_model = v)),
            cx.subscribe(
                &max_tokens,
                on_commit(|s, v| s.ai.llm_max_tokens = v.parse::<i64>().unwrap_or(1024).max(1)),
            ),
            cx.subscribe_in(
                &pattern,
                window,
                |this, _, event: &InputEvent, window, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        this.ai_inputs.add_rule(window, cx);
                    }
                },
            ),
        ];
        Self {
            pattern,
            name,
            api_key,
            endpoint,
            model,
            max_tokens,
            new_color: TabColor::Gray,
            test_result: None,
            testing: false,
            key_saved: None,
            _subscriptions: subscriptions,
        }
    }

    /// `addNewRule`: pattern required, name optional, then the fields reset.
    fn add_rule(&mut self, window: &mut Window, cx: &mut Context<SettingsView>) {
        let pattern = self.pattern.read(cx).value().trim().to_string();
        if pattern.is_empty() {
            return;
        }
        let name = self.name.read(cx).value().trim().to_string();
        let rule = CustomAiRule::new(&pattern, &name, self.new_color);
        update(cx, |s| s.ai.custom_rules.push(rule));
        self.new_color = TabColor::Gray;
        self.pattern.update(cx, |s, cx| s.set_value("", window, cx));
        self.name.update(cx, |s, cx| s.set_value("", window, cx));
        cx.notify();
    }
}

/// A new provider: its key, and empty endpoint and model (its defaults).
fn select_provider(
    view: Option<Entity<SettingsView>>,
    provider: LLMProviderType,
    window: &mut Window,
    cx: &mut App,
) {
    update(cx, |s| {
        s.ai.llm_provider = provider;
        s.ai.llm_endpoint.clear();
        s.ai.llm_model.clear();
    });
    let Some(view) = view else {
        return;
    };
    view.update(cx, |view, cx| {
        let inputs = &mut view.ai_inputs;
        inputs.test_result = None;
        inputs.key_saved = None;
        let key = llm::api_key(provider);
        inputs
            .api_key
            .update(cx, |s, cx| s.set_value(key, window, cx));
        inputs.endpoint.update(cx, |s, cx| {
            s.set_value("", window, cx);
            s.set_placeholder(provider.default_endpoint(), window, cx);
        });
        inputs.model.update(cx, |s, cx| {
            s.set_value("", window, cx);
            s.set_placeholder(provider.default_model(), window, cx);
        });
        cx.notify();
    });
}

/// `saveAPIKey`.
fn save_key(view: Entity<SettingsView>, cx: &mut App) {
    let provider = Settings::get(cx).ai.llm_provider;
    view.update(cx, |view, cx| {
        let key = view.ai_inputs.api_key.read(cx).value().trim().to_string();
        view.ai_inputs.key_saved = Some(match llm::save_api_key(provider, &key) {
            Ok(()) if key.is_empty() => "Key removed".into(),
            Ok(()) => "Saved to Keychain".into(),
            Err(err) => format!("Error: {err}"),
        });
        cx.notify();
    });
}

/// `testConnection`: sends "Reply with OK." with the fields as typed.
fn test_connection(view: Entity<SettingsView>, cx: &mut App) {
    let mut ai = Settings::get(cx).ai.clone();
    let key = view.update(cx, |view, cx| {
        let inputs = &mut view.ai_inputs;
        inputs.testing = true;
        inputs.test_result = None;
        ai.llm_endpoint = inputs.endpoint.read(cx).value().trim().to_string();
        ai.llm_model = inputs.model.read(cx).value().trim().to_string();
        ai.llm_max_tokens = inputs
            .max_tokens
            .read(cx)
            .value()
            .trim()
            .parse()
            .unwrap_or(1024);
        cx.notify();
        inputs.api_key.read(cx).value().trim().to_string()
    });
    let config = ai.llm_config(&key);
    cx.spawn(async move |cx| {
        let result = cx
            .background_executor()
            .spawn(async move { llm::send(&test_connection_request(), &config) })
            .await;
        let text = test_connection_result(&result);
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                view.ai_inputs.testing = false;
                view.ai_inputs.test_result = Some(text);
                cx.notify();
            })
        });
    })
    .detach();
}

/// Built-in detection rows (`SettingsDetectionRow`).
const BUILT_IN: [(&str, &str, TabColor); 7] = [
    ("Claude Code", "claude, claude-code", TabColor::Purple),
    ("OpenAI Codex", "codex, codex-cli", TabColor::Green),
    ("Gemini", "gemini", TabColor::Blue),
    ("ChatGPT", "chatgpt, gpt", TabColor::Green),
    ("GitHub Copilot", "gh copilot, copilot", TabColor::Orange),
    ("Aider", "aider, aider-chat", TabColor::Pink),
    ("Cursor", "cursor", TabColor::Teal),
];

fn dot(color: TabColor, size: f32) -> gpui::Div {
    div()
        .size(px(size))
        .flex_none()
        .rounded_full()
        .bg(tab_color(color))
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let ai = &ctx.settings.ai;
    let inputs = &ctx.view.ai_inputs;
    let entity = ctx.view.entity.clone();

    // Custom rules (first: actionable).
    let rules = ai.custom_rules.iter().map(|rule| {
        let id = rule.id.clone();
        let title = if rule.display_name.is_empty() {
            rule.pattern.clone()
        } else {
            rule.display_name.clone()
        };
        div()
            .flex()
            .items_center()
            .gap_2()
            .min_h(px(30.0))
            .child(div().flex_1().min_w_0().text_sm().child(title))
            .child(dot(rule.color(), 10.0))
            .child(
                div()
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(chrome.text_muted)
                    .child(rule.pattern.clone()),
            )
            .child(
                div()
                    .id(SharedString::from(format!("remove-rule-{id}")))
                    .px_1()
                    .rounded_sm()
                    .text_color(chrome.danger)
                    .cursor_pointer()
                    .hover(|d| d.bg(chrome.tab_hover_bg))
                    .child("🗑︎")
                    .on_click(move |_, _, cx| {
                        let id = id.clone();
                        update(cx, move |s| s.ai.custom_rules.retain(|r| r.id != id))
                    }),
            )
    });
    let colors = TabColor::ALL.into_iter().map(|color| {
        let entity = entity.clone();
        div()
            .id(SharedString::from(format!("rule-color-{}", color.name())))
            .p(px(3.0))
            .rounded_full()
            .border_1()
            .border_color(if inputs.new_color == color {
                chrome.accent
            } else {
                gpui::transparent_black()
            })
            .cursor_pointer()
            .child(dot(color, 10.0))
            .on_click(move |_, _, cx| {
                let _ = entity.update(cx, |view, cx| {
                    view.ai_inputs.new_color = color;
                    cx.notify();
                });
            })
    });
    let add_entity = entity.clone();
    let rules_block = titled("Custom Detection Rules", chrome)
        .child(description(
            "Add command or output patterns to tag custom AI CLIs.",
            chrome,
        ))
        .children(rules)
        .child(row(
            "Add New Rule",
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().w(px(120.0)).child(Input::new(&inputs.pattern)))
                .child(div().w(px(100.0)).child(Input::new(&inputs.name)))
                .child(div().flex().gap_0p5().children(colors))
                .child(
                    button("add-rule", "Add", chrome).on_click(move |_, window, cx| {
                        let _ =
                            add_entity.update(cx, |view, cx| view.ai_inputs.add_rule(window, cx));
                    }),
                ),
            chrome,
        ));

    let formats = RegionalNumberFormat::ALL.into_iter().map(|format| {
        chip(
            SharedString::from(format!("number-format-{}", format.id())),
            format!(
                "{} ({})",
                crate::l10n::tr(format.display_name()),
                format.example()
            ),
            ctx.settings.general.regional_number_format == format,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.general.regional_number_format = format))
    });
    let usage_display = titled(crate::l10n::tr("Usage Display"), chrome)
        .child(row(crate::l10n::tr("Number Format"),
            div().flex().flex_wrap().gap_1().children(formats), chrome))
        .child(description(crate::l10n::tr(
            "Controls token, cost, and dashboard number formatting independently from app language."), chrome));

    // LLM provider.
    let providers = LLMProviderType::ALL.into_iter().map(|provider| {
        let entity = entity.clone();
        chip(
            SharedString::from(format!("llm-{}", provider.raw_value())),
            provider.display_name(),
            ai.llm_provider == provider,
            chrome,
        )
        .on_click(move |_, window, cx| select_provider(entity.upgrade(), provider, window, cx))
    });
    let save_entity = entity.clone();
    let test_entity = entity.clone();
    let mut llm_block = titled("LLM Provider", chrome)
        .child(row(
            "Provider",
            div().flex().gap_1().children(providers),
            chrome,
        ))
        .child(description(
            "Choose the LLM backend for error explanation and AI features",
            chrome,
        ));
    if ai.llm_provider.requires_api_key() {
        llm_block = llm_block
            .child(row(
                "API Key",
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .child(div().w(px(240.0)).child(Input::new(&inputs.api_key)))
                    .child(
                        button("save-llm-key", "Save", chrome).on_click(move |_, _, cx| {
                            if let Some(view) = save_entity.upgrade() {
                                save_key(view, cx);
                            }
                        }),
                    ),
                chrome,
            ))
            .child(description(
                inputs
                    .key_saved
                    .clone()
                    .unwrap_or_else(|| "Stored securely in the Keychain".into()),
                chrome,
            ));
    }
    let result_color = |text: &str| {
        if text.starts_with("OK") {
            gpui::hsla(0.36, 0.6, 0.45, 1.0)
        } else {
            chrome.danger
        }
    };
    llm_block = llm_block
        .child(row(
            "Endpoint URL",
            div().w(px(300.0)).child(Input::new(&inputs.endpoint)),
            chrome,
        ))
        .child(description(
            "API endpoint URL (leave empty for provider default)",
            chrome,
        ))
        .child(row(
            "Model",
            div().w(px(200.0)).child(Input::new(&inputs.model)),
            chrome,
        ))
        .child(description(
            "Model identifier (e.g. gpt-4o, claude-sonnet-4-20250514)",
            chrome,
        ))
        .child(row(
            "Max Tokens",
            div().w(px(80.0)).child(Input::new(&inputs.max_tokens)),
            chrome,
        ))
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    button(
                        "test-llm",
                        if inputs.testing {
                            "Testing..."
                        } else {
                            "Test Connection"
                        },
                        chrome,
                    )
                    .when(!inputs.testing, |d| {
                        d.on_click(move |_, _, cx| {
                            if let Some(view) = test_entity.upgrade() {
                                test_connection(view, cx);
                            }
                        })
                    }),
                )
                .children(
                    inputs
                        .test_result
                        .clone()
                        .map(|text| div().text_xs().text_color(result_color(&text)).child(text)),
                ),
        );

    let explain_block = titled("Error Explanation", chrome)
        .child(row(
            "Enable \"Explain This Error\"",
            toggle("error-explain", ai.error_explain_enabled, chrome, |s, v| {
                s.ai.error_explain_enabled = v
            }),
            chrome,
        ))
        .child(description(
            "Show an explain button when commands fail, using the configured LLM provider",
            chrome,
        ));

    let built_in = titled("Built-in AI CLI Detection", chrome)
        .child(description(
            "Chau7 automatically detects these AI CLIs and applies appropriate theming:",
            chrome,
        ))
        .children(BUILT_IN.iter().map(|(name, commands, color)| {
            div()
                .flex()
                .items_center()
                .gap_2()
                .min_h(px(26.0))
                .child(dot(*color, 8.0))
                .child(div().w(px(140.0)).text_sm().child(*name))
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .text_color(chrome.text_muted)
                        .child(*commands),
                )
        }));

    div()
        .flex()
        .flex_col()
        .child(rules_block)
        .child(usage_display)
        .child(llm_block)
        .child(explain_block)
        .child(built_in)
}

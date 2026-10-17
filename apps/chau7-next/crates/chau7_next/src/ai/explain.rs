//! "Explain This Error" (`AI/ErrorExplainer.swift`). The Swift app defines
//! it but never shows it; Chau7 Next wires it as designed: when a command
//! fails in a tab and the setting is on, the tab offers "Explain This
//! Error"; the command and the last 2000 characters of output go to the
//! configured LLM, and the answer is shown with its fixes
//! (`ErrorExplanationView`, drawn by `workspace::ai`).

use std::collections::HashMap;

use chau7_next_core::ai::error_explainer::{parse_explanation, request};
use chau7_next_core::llm_provider::{ErrorExplanation, FixSuggestion};
use gpui::{App, Global, Task};

use super::llm;
use crate::settings::Settings;
use crate::tab_bar::TabId;

/// Where an explanation is.
pub enum Phase {
    /// A command failed: the "Explain" button is offered.
    Offer,
    /// Waiting for the LLM ("Analyzing error...").
    Loading,
    Done {
        explanation: ErrorExplanation,
        fixes: Vec<FixSuggestion>,
    },
    Failed(String),
}

pub struct ExplainState {
    pub exit_code: i32,
    pub command: Option<String>,
    pub phase: Phase,
    _task: Option<Task<()>>,
}

/// Explanations by tab.
#[derive(Default)]
pub struct ExplainPanels(pub HashMap<TabId, ExplainState>);
impl Global for ExplainPanels {}

/// A command finished in `tab`: offer an explanation when it failed and
/// the feature is on (`errorExplainEnabled`); a later success removes an
/// offer nobody used.
pub fn command_finished(tab: TabId, exit_code: i32, command: Option<String>, cx: &mut App) {
    let enabled = Settings::get(cx).ai.error_explain_enabled;
    let panels = cx.default_global::<ExplainPanels>();
    if exit_code == 0 || !enabled {
        if panels
            .0
            .get(&tab)
            .is_some_and(|s| matches!(s.phase, Phase::Offer))
        {
            panels.0.remove(&tab);
        }
        return;
    }
    if panels
        .0
        .get(&tab)
        .is_some_and(|s| matches!(s.phase, Phase::Loading))
    {
        return;
    }
    panels.0.insert(
        tab,
        ExplainState {
            exit_code,
            command,
            phase: Phase::Offer,
            _task: None,
        },
    );
}

/// The dismiss button (`clear`).
pub fn dismiss(tab: TabId, cx: &mut App) {
    cx.default_global::<ExplainPanels>().0.remove(&tab);
    cx.refresh_windows();
}

/// Sends the failed command and its output to the LLM (`explain`).
pub fn explain(tab: TabId, output: String, cx: &mut App) {
    let settings = Settings::get(cx).ai.clone();
    let Some(state) = cx.default_global::<ExplainPanels>().0.get_mut(&tab) else {
        return;
    };
    if matches!(state.phase, Phase::Loading) {
        return;
    }
    let command = state.command.clone();
    state.phase = Phase::Loading;
    let task = cx.spawn(async move |cx| {
        let result = cx
            .background_executor()
            .spawn(async move {
                let key = llm::api_key(settings.llm_provider);
                let config = settings.llm_config(&key);
                let req = request(&output, command.as_deref(), config.max_tokens);
                llm::send(&req, &config)
            })
            .await;
        cx.update(|cx| {
            if let Some(state) = cx.default_global::<ExplainPanels>().0.get_mut(&tab) {
                state.phase = match result {
                    Ok(response) => {
                        log::info!(
                            "ErrorExplainer: got explanation ({} tokens)",
                            response.tokens_used.unwrap_or(0)
                        );
                        let (explanation, fixes) = parse_explanation(&response.content);
                        Phase::Done { explanation, fixes }
                    }
                    Err(err) => {
                        log::error!("ErrorExplainer: {err}");
                        Phase::Failed(err.to_string())
                    }
                };
            }
            cx.refresh_windows();
        });
    });
    if let Some(state) = cx.default_global::<ExplainPanels>().0.get_mut(&tab) {
        state._task = Some(task);
    }
    cx.refresh_windows();
}

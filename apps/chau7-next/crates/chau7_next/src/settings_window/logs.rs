//! Logs & History (`LogsSettingsView.swift`, `HistorySettingsView.swift`):
//! the command history database (enable, capacity, statistics, import and
//! export, clearing), the Claude and Codex history file monitors, the PTY
//! log monitors and the sessions they track.
//!
//! Chau7 Next keeps these under `[next]` in config.toml (Swift stores them in
//! UserDefaults).

use chau7_next_core::history_events::HistorySessionState;
use chau7_next_core::history_monitor::SessionStatus;
use chau7_next_core::history_store::{DEFAULT_MAX_RECORDS, MAX_MAX_RECORDS, MIN_MAX_RECORDS};
use gpui::{
    App, Context, Entity, Global, PathPromptOptions, SharedString, Subscription, Window, div,
    prelude::*, px,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{banner, button, description, info_row, row, section as titled, toggle};
use super::{SectionContext, SettingsView, set_message, update};
use crate::history;
use crate::history::monitor;
use crate::settings::{HistorySettings, Settings};

/// Step of the "Maximum Records" control (the Swift slider step).
const RECORDS_STEP: i32 = 5000;

/// What the section shows besides the settings.
#[derive(Default)]
pub(crate) struct LogsData {
    pub total_records: i64,
    pub database_bytes: u64,
    pub database_open: bool,
    pub sessions: Vec<SessionStatus>,
}

impl LogsData {
    pub(crate) fn read(cx: &App) -> Self {
        let (total_records, database_bytes, database_open) = history::service(cx)
            .map(|s| s.with_store(|st| (st.total_count(), st.database_size_bytes(), true)))
            .unwrap_or((0, 0, false));
        Self {
            total_records,
            database_bytes,
            database_open,
            sessions: monitor::session_statuses(cx),
        }
    }
}

/// "Clear All" waits for a second click.
#[derive(Default)]
struct ConfirmClear(bool);
impl Global for ConfirmClear {}

/// The text fields of this section.
pub(crate) struct LogsInputs {
    idle: Entity<InputState>,
    stale: Entity<InputState>,
    codex_history: Entity<InputState>,
    claude_history: Entity<InputState>,
    codex_terminal: Entity<InputState>,
    claude_terminal: Entity<InputState>,
    older_days: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl LogsInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let h = Settings::get(cx).history.clone();
        let field = |value: String,
                     placeholder: &'static str,
                     window: &mut Window,
                     cx: &mut Context<SettingsView>| {
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder)
                    .default_value(value)
            })
        };
        let idle = field(h.idle_seconds.clone(), "5", window, cx);
        let stale = field(h.stale_seconds.clone(), "180", window, cx);
        let codex_history = field(
            h.codex_history_path.clone(),
            "~/.codex/history.jsonl",
            window,
            cx,
        );
        let claude_history = field(
            h.claude_history_path.clone(),
            "~/.claude/history.jsonl",
            window,
            cx,
        );
        let codex_terminal = field(
            h.codex_terminal_log.clone(),
            "Default: AI logs/codex-pty.log",
            window,
            cx,
        );
        let claude_terminal = field(
            h.claude_terminal_log.clone(),
            "Default: AI logs/claude-pty.log",
            window,
            cx,
        );
        let older_days = field("30".into(), "Days", window, cx);
        let on_commit = |apply: fn(&mut HistorySettings, String)| {
            move |_: &mut SettingsView,
                  input: Entity<InputState>,
                  event: &InputEvent,
                  cx: &mut Context<SettingsView>| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    let value = input.read(cx).value().trim().to_string();
                    update(cx, |s| {
                        apply(&mut s.history, value);
                        s.history.normalize_seconds();
                    });
                }
            }
        };
        let subscriptions = vec![
            cx.subscribe(&idle, on_commit(|h, v| h.idle_seconds = v)),
            cx.subscribe(&stale, on_commit(|h, v| h.stale_seconds = v)),
            cx.subscribe(&codex_history, on_commit(|h, v| h.codex_history_path = v)),
            cx.subscribe(&claude_history, on_commit(|h, v| h.claude_history_path = v)),
            cx.subscribe(&codex_terminal, on_commit(|h, v| h.codex_terminal_log = v)),
            cx.subscribe(
                &claude_terminal,
                on_commit(|h, v| h.claude_terminal_log = v),
            ),
        ];
        Self {
            idle,
            stale,
            codex_history,
            claude_history,
            codex_terminal,
            claude_terminal,
            older_days,
            _subscriptions: subscriptions,
        }
    }
}

fn path_field(
    label: &'static str,
    help: &'static str,
    input: &Entity<InputState>,
    wide: bool,
    chrome: crate::theme::Chrome,
) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(row(
            label,
            div()
                .w(px(if wide { 300.0 } else { 80.0 }))
                .child(Input::new(input)),
            chrome,
        ))
        .child(description(help, chrome))
}

fn switch(
    label: &'static str,
    help: &'static str,
    id: &'static str,
    on: bool,
    apply: fn(&mut Settings, bool),
    chrome: crate::theme::Chrome,
) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(row(label, toggle(id, on, chrome, apply), chrome))
        .child(description(help, chrome))
}

fn step_records(s: &mut Settings, delta: i32) {
    let next = s.history.max_records as i64 + i64::from(delta) * i64::from(RECORDS_STEP);
    s.history.max_records = (next.max(0) as usize).clamp(MIN_MAX_RECORDS, MAX_MAX_RECORDS);
}

fn group_label(text: &'static str, chrome: crate::theme::Chrome) -> gpui::Div {
    div()
        .text_xs()
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .text_color(chrome.text_muted)
        .pt_2()
        .child(text.to_uppercase())
}

pub(super) fn history(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let h = &ctx.settings.history;
    let inputs = &ctx.view.logs_inputs;
    let data = &ctx.logs;
    let confirm = ctx.confirm_clear;

    let capacity = row(
        "Maximum Records",
        super::widgets::stepper(
            "history-max",
            format!("{}", h.max_records),
            chrome,
            step_records,
        ),
        chrome,
    );
    let actions = div()
        .flex()
        .gap_2()
        .child(
            button("history-export", "Export History...", chrome)
                .on_click(|_, _, cx| export_history(cx)),
        )
        .child(
            button("history-import", "Import History...", chrome)
                .on_click(|_, _, cx| import_history(cx)),
        );
    let maintenance = div()
        .flex()
        .items_center()
        .gap_2()
        .child(div().w(px(70.0)).child(Input::new(&inputs.older_days)))
        .child({
            let days = inputs.older_days.clone();
            button("history-clear-older", "Clear Older Than (days)", chrome).on_click(
                move |_, _, cx| {
                    let text = days.read(cx).value().trim().to_string();
                    match text.parse::<u32>() {
                        Ok(n) if n > 0 => {
                            if let Some(s) = history::service(cx) {
                                s.with_store(|st| st.clear_older_than(n));
                            }
                            set_message(cx, format!("Cleared history older than {n} days"), false);
                        }
                        _ => set_message(cx, "Enter a number of days.".into(), true),
                    }
                },
            )
        })
        .child(if confirm {
            div()
                .flex()
                .gap_2()
                .child(
                    button("history-clear-yes", "Clear All (cannot be undone)", chrome)
                        .text_color(chrome.danger)
                        .on_click(|_, _, cx| {
                            if let Some(s) = history::service(cx) {
                                s.with_store(|st| st.clear_all());
                            }
                            cx.set_global(ConfirmClear(false));
                            set_message(cx, "All history cleared".into(), false);
                        }),
                )
                .child(
                    button("history-clear-no", "Cancel", chrome).on_click(|_, _, cx| {
                        cx.set_global(ConfirmClear(false));
                        cx.refresh_windows();
                    }),
                )
        } else {
            div().child(
                button("history-clear-all", "Clear All History", chrome)
                    .text_color(chrome.danger)
                    .on_click(|_, _, cx| {
                        cx.set_global(ConfirmClear(true));
                        cx.refresh_windows();
                    }),
            )
        });

    let mut persistent = titled("Persistent History", chrome)
        .child(switch(
            "Enable Persistent History",
            "Save command history to disk so it persists across app restarts",
            "history-enable",
            h.persistent_history,
            |s, v| s.history.persistent_history = v,
            chrome,
        ))
        .child(capacity)
        .child(description(
            format!(
                "Maximum number of commands to store ({} - {}, default {})",
                MIN_MAX_RECORDS, MAX_MAX_RECORDS, DEFAULT_MAX_RECORDS
            ),
            chrome,
        ))
        .child(group_label("Statistics", chrome));
    if data.database_open {
        persistent = persistent
            .child(info_row(
                "Total Records",
                data.total_records.to_string(),
                chrome,
            ))
            .child(info_row(
                "Database Size",
                history::format_bytes(data.database_bytes),
                chrome,
            ));
    } else {
        persistent = persistent.child(banner(
            "The history database could not be opened.",
            true,
            chrome,
        ));
    }
    persistent = persistent
        .child(group_label("Import / Export", chrome))
        .child(actions)
        .child(group_label("Maintenance", chrome))
        .child(maintenance);

    div().flex().flex_col().gap_4().child(persistent)
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let h = &ctx.settings.history;
    let inputs = &ctx.view.logs_inputs;
    let data = &ctx.logs;
    let history_logs = titled("History Logs", chrome)
        .child(switch(
            "Monitor History Logs",
            "Watch AI CLI history files for session activity and idle detection",
            "logs-monitor-history",
            h.monitor_history_logs,
            |s, v| s.history.monitor_history_logs = v,
            chrome,
        ))
        .child(path_field(
            "Idle Seconds",
            "Seconds of inactivity before sending idle notification",
            &inputs.idle,
            false,
            chrome,
        ))
        .child(path_field(
            "Stale Seconds",
            "Seconds before marking a session as closed",
            &inputs.stale,
            false,
            chrome,
        ))
        .child(path_field(
            "Codex History Path",
            "Path to the OpenAI Codex history file (empty: not followed)",
            &inputs.codex_history,
            true,
            chrome,
        ))
        .child(path_field(
            "Claude History Path",
            "Path to the Claude Code history file (empty: not followed)",
            &inputs.claude_history,
            true,
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    button("history-restart", "Restart Monitors", chrome)
                        .on_click(|_, _, cx| monitor::restart_history(cx)),
                )
                .child(
                    button("history-clear-entries", "Clear History", chrome)
                        .on_click(|_, _, cx| monitor::clear_history(cx)),
                ),
        );

    let terminal_logs = titled("Terminal Logs", chrome)
        .child(switch(
            "Monitor Terminal Logs",
            "Watch PTY wrapper output files for terminal activity",
            "logs-monitor-terminal",
            h.monitor_terminal_logs,
            |s, v| s.history.monitor_terminal_logs = v,
            chrome,
        ))
        .child(switch(
            "Normalize Output",
            "Strip ANSI codes and control characters from log display",
            "logs-normalize",
            h.terminal_normalize,
            |s, v| s.history.terminal_normalize = v,
            chrome,
        ))
        .child(switch(
            "Render ANSI Styling",
            "Display ANSI colors and formatting in log viewer",
            "logs-ansi",
            h.terminal_ansi,
            |s, v| s.history.terminal_ansi = v,
            chrome,
        ))
        .child(path_field(
            "Codex Terminal Log",
            "Path to the Codex PTY wrapper log file",
            &inputs.codex_terminal,
            true,
            chrome,
        ))
        .child(path_field(
            "Claude Terminal Log",
            "Path to the Claude PTY wrapper log file",
            &inputs.claude_terminal,
            true,
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    button("terminal-restart", "Restart Monitors", chrome)
                        .on_click(|_, _, cx| monitor::restart_terminal(cx)),
                )
                .child(
                    button("terminal-reload", "Reload Last Lines", chrome)
                        .on_click(|_, _, cx| monitor::reload_terminal_prefill(cx)),
                )
                .child(
                    button("terminal-clear", "Clear Logs", chrome)
                        .on_click(|_, _, cx| monitor::clear_terminal_logs(cx)),
                ),
        );

    let mut sessions = titled("Active Sessions", chrome);
    if data.sessions.is_empty() {
        sessions = sessions.child(description("No sessions tracked yet.", chrome));
    } else {
        for status in &data.sessions {
            let dot = if status.state == HistorySessionState::Active {
                gpui::hsla(0.33, 0.7, 0.5, 1.0)
            } else {
                chrome.text_muted
            };
            sessions = sessions.child(
                div()
                    .id(SharedString::from(format!("session-{}", status.id)))
                    .flex()
                    .items_center()
                    .gap_2()
                    .py_0p5()
                    .child(div().size(px(8.0)).rounded_full().bg(dot))
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(status.tool.clone()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .child(status.session_id.chars().take(8).collect::<String>()),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(status.state.raw_value().to_uppercase()),
                    ),
            );
        }
    }

    div()
        .flex()
        .flex_col()
        .gap_4()
        .child(history_logs)
        .child(terminal_logs)
        .child(sessions)
}

/// Whether "Clear All" is waiting for its second click.
pub(crate) fn confirm_pending(cx: &App) -> bool {
    cx.try_global::<ConfirmClear>().is_some_and(|c| c.0)
}

/// Export History...: write the JSON the Swift app exports.
fn export_history(cx: &mut App) {
    let Some(json) = history::service(cx).and_then(|s| s.with_store(|st| st.export_json())) else {
        set_message(cx, "Failed to export history".into(), true);
        return;
    };
    let home = cx
        .global::<crate::workspace::AppData>()
        .root
        .home()
        .to_path_buf();
    let path = cx.prompt_for_new_path(&home, Some("chau7-history.json"));
    cx.spawn(async move |cx| {
        if let Ok(Ok(Some(path))) = path.await {
            let result = std::fs::write(&path, json);
            cx.update(|cx| match result {
                Ok(()) => set_message(cx, format!("Exported history to {}", path.display()), false),
                Err(err) => set_message(cx, format!("Export failed: {err}"), true),
            });
        }
    })
    .detach();
}

/// Import History...: add the records of a JSON file.
fn import_history(cx: &mut App) {
    let paths = cx.prompt_for_paths(PathPromptOptions {
        files: true,
        directories: false,
        multiple: false,
        prompt: Some("Import".into()),
    });
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(paths))) = paths.await else {
            return;
        };
        let Some(path) = paths.into_iter().next() else {
            return;
        };
        let text = std::fs::read_to_string(&path);
        cx.update(|cx| {
            let text = match text {
                Ok(text) => text,
                Err(err) => {
                    set_message(cx, format!("Import failed: {err}"), true);
                    return;
                }
            };
            let count = history::service(cx).map(|s| s.with_store(|st| st.import_json(&text)));
            match count {
                Some(n) if n > 0 => set_message(cx, format!("Imported {n} records"), false),
                Some(_) => set_message(cx, "No records imported".into(), true),
                None => set_message(cx, "The history database is not open".into(), true),
            }
        });
    })
    .detach();
}

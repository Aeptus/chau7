//! "Report an Issue" window (`BugReportWindowController`,
//! `BugReportDialogView`, `IssueReportingPrivacyView`): a privacy-first
//! dialog with a live Markdown preview. Every diagnostic is off by default.
//! Submit posts the report to the endpoint in the settings (HTTPS only);
//! Save Locally writes it to the reports folder.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use chau7_next_core::bug_report::{
    BugReportError, Draft, StateSnapshot, curl_args, parse_curl_output, prefilled_issue_url,
    report_file_name, submit_body, success_text, validate_endpoint,
};
use chau7_next_core::debug_console::Tone;
use chau7_next_core::issue_privacy as privacy;
use chrono::Local;
use gpui::{
    AnyWindowHandle, App, Bounds, ClipboardItem, Context, Entity, Global, IntoElement, Render,
    SharedString, Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};

use super::{snapshot, ui};
use crate::settings::Settings;
use crate::settings_window;
use crate::theme::Chrome;
use crate::workspace::AppData;

/// The open window, if any.
#[derive(Default)]
struct ReportWindow(Option<AnyWindowHandle>);
impl Global for ReportWindow {}

/// Open the dialog with a fresh snapshot; a window that is open is replaced
/// (`BugReportWindowController.show`).
pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<ReportWindow>().and_then(|w| w.0) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    if AppData::live(cx).is_empty() {
        // No window to describe: fall back to the browser, as Swift does
        // when the controller is not configured.
        log::warn!("Report Issue: no workspace, opening the prefilled GitHub issue");
        let url = snapshot::issue_url("", cx);
        cx.open_url(&url);
        return;
    }
    let bounds = Bounds::centered(None, size(px(640.0), px(720.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(540.0), px(520.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| ReportView::new(window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(ReportWindow(Some(handle))),
        Err(err) => log::error!("report window: {err}"),
    }
}

/// POST the report with `curl` (no HTTP client in the app): HTTPS only, a
/// 15 s limit, the answer decoded by `chau7_next_core::bug_report`.
fn post_report(endpoint: &str, title: &str, report: &str) -> Result<u64, BugReportError> {
    let url = validate_endpoint(endpoint)?;
    let body = submit_body(title, report);
    let mut child = Command::new("curl")
        .args(curl_args(url))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| BugReportError::Network(err.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(body.as_bytes())
            .map_err(|err| BugReportError::Network(err.to_string()))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|err| BugReportError::Network(err.to_string()))?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(BugReportError::Network(if message.is_empty() {
            "request failed".into()
        } else {
            message
        }));
    }
    parse_curl_output(&String::from_utf8_lossy(&output.stdout))
}

struct ReportView {
    snapshot: StateSnapshot,
    draft: Draft,
    /// `(tab id, label)` of the tabs to pick from.
    tabs: Vec<(String, String)>,
    description: Entity<TextareaState>,
    name: Entity<InputState>,
    handle: Entity<InputState>,
    save_contact: bool,
    show_privacy: bool,
    submitting: bool,
    error: Option<String>,
    success: Option<u64>,
    /// Path shown in the "Report Saved" box.
    saved: Option<String>,
    home: String,
}

impl ReportView {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let snapshot = snapshot::capture(cx);
        let tabs: Vec<(String, String)> = snapshot
            .tab_states
            .iter()
            .map(|t| {
                (
                    t.id.clone(),
                    t.custom_title
                        .clone()
                        .filter(|c| !c.is_empty())
                        .unwrap_or_else(|| t.title.clone()),
                )
            })
            .collect();
        let current = snapshot
            .tab_states
            .get(snapshot.active_tab_index)
            .map(|t| t.id.clone());
        let mut draft = Draft::new(current);
        let general = Settings::get(cx).general.clone();
        draft.contact_name = general.bug_report_contact_name.clone();
        draft.contact_handle = general.bug_report_contact_handle.clone();
        let save_contact = !general.bug_report_contact_name.is_empty()
            || !general.bug_report_contact_handle.is_empty();
        let description = cx.new(|cx| TextareaState::new(window, cx));
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("Your name"))
                .default_value(general.bug_report_contact_name.clone())
        });
        let handle = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("GitHub username or email"))
                .default_value(general.bug_report_contact_handle.clone())
        });
        let home = cx
            .global::<AppData>()
            .root
            .home()
            .to_string_lossy()
            .into_owned();
        Self {
            snapshot,
            draft,
            tabs,
            description,
            name,
            handle,
            save_contact,
            show_privacy: false,
            submitting: false,
            error: None,
            success: None,
            saved: None,
            home,
        }
    }

    /// Copy the text boxes into the draft.
    fn sync(&mut self, cx: &App) {
        self.draft.description = self.description.read(cx).value().to_string();
        self.draft.contact_name = self.name.read(cx).value().trim().to_string();
        self.draft.contact_handle = self.handle.read(cx).value().trim().to_string();
    }

    fn markdown(&mut self, cx: &App) -> String {
        self.sync(cx);
        self.draft.markdown(&self.snapshot, &self.home)
    }

    /// Terminal history of a tab, read when the toggle or the tab changes.
    fn refresh_history(&mut self, cx: &App) {
        self.draft.terminal_history = if self.draft.include_terminal_history {
            self.draft
                .history_tab
                .as_deref()
                .and_then(|tab| snapshot::terminal_history(tab, cx))
        } else {
            None
        };
    }

    /// `persistContactInfoIfNeeded`.
    fn persist_contact(&self, cx: &mut App) {
        let (name, handle) = if self.save_contact {
            (
                self.draft.contact_name.clone(),
                self.draft.contact_handle.clone(),
            )
        } else {
            (String::new(), String::new())
        };
        settings_window::update(cx, |s| {
            s.general.bug_report_contact_name = name;
            s.general.bug_report_contact_handle = handle;
        });
    }

    fn save_locally(&mut self, cx: &mut Context<Self>) {
        let report = self.markdown(cx);
        let dir = cx.global::<AppData>().root.reports_dir();
        let path = dir.join(report_file_name(Local::now().naive_local()));
        match std::fs::create_dir_all(&dir).and_then(|()| std::fs::write(&path, report)) {
            Ok(()) => {
                log::info!("Bug report saved to {}", path.display());
                self.saved = Some(path.display().to_string());
            }
            Err(err) => {
                log::error!("Failed to save bug report: {err}");
                self.error = Some(format!("Could not save the report: {err}"));
            }
        }
        cx.notify();
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Guard against a double click.
        if self.submitting || self.success.is_some() {
            return;
        }
        let report = self.markdown(cx);
        self.persist_contact(cx);
        let endpoint = Settings::get(cx).general.bug_report_issue_endpoint.clone();
        let title = self.snapshot.issue_title("Chau7");
        self.submitting = true;
        self.error = None;
        let task = cx
            .background_executor()
            .spawn(async move { post_report(&endpoint, &title, &report) });
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.submitting = false;
                match result {
                    Ok(number) => {
                        this.success = Some(number);
                        // Close after a short delay, as the Swift dialog does.
                        cx.spawn_in(window, async move |_, cx| {
                            cx.background_executor()
                                .timer(std::time::Duration::from_millis(1500))
                                .await;
                            let _ = cx.update(|window, _| window.remove_window());
                        })
                        .detach();
                    }
                    Err(err) => this.error = Some(err.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}

/// A diagnostic toggle: checkbox, description, and the warning while on.
fn toggle_row(
    id: &'static str,
    label: &'static str,
    description: &'static str,
    warning: Option<&'static str>,
    on: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(SharedString::from(format!("{id}-row")))
        .flex()
        .flex_col()
        .gap_0p5()
        .child(ui::checkbox(id, label, on, chrome))
        .child(
            div()
                .pl_5()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(description),
        )
        .when_some(warning.filter(|_| on), |d, text| {
            d.child(
                div()
                    .pl_5()
                    .text_xs()
                    .text_color(ui::tone_color(Tone::Warn, chrome))
                    .child(format!("\u{26A0} {text}")),
            )
        })
}

impl ReportView {
    fn tab_picker(
        &self,
        id: &'static str,
        selected: Option<&str>,
        chrome: Chrome,
        cx: &mut Context<Self>,
        set: fn(&mut Draft, String),
    ) -> gpui::Div {
        let mut row = div().flex().flex_wrap().gap_1().pl_5();
        for (tab_id, label) in &self.tabs {
            let active = selected == Some(tab_id.as_str());
            let tab_id = tab_id.clone();
            row = row.child(
                ui::chip(
                    SharedString::from(format!("{id}-{tab_id}")),
                    label.clone(),
                    active,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    set(&mut this.draft, tab_id.clone());
                    this.refresh_history(cx);
                    cx.notify();
                })),
            );
        }
        row
    }

    fn privacy_page(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let section = |title: &'static str| {
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::MEDIUM)
                .child(title)
        };
        let bullet = |text: &'static str| {
            div()
                .flex()
                .gap_2()
                .text_xs()
                .text_color(chrome.text_muted)
                .child("\u{2022}")
                .child(div().flex_1().child(text))
        };
        let data_box = |title: &'static str, tone: Tone, rows: &[privacy::DataRow]| {
            let mut group = ui::group("", chrome).child(
                div()
                    .text_xs()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(ui::tone_color(tone, chrome))
                    .child(title),
            );
            for (name, text) in rows {
                group = group.child(
                    div()
                        .flex()
                        .gap_2()
                        .text_xs()
                        .child(
                            div()
                                .w(px(130.0))
                                .flex_none()
                                .font_weight(gpui::FontWeight::MEDIUM)
                                .child(*name),
                        )
                        .child(div().flex_1().text_color(chrome.text_muted).child(*text)),
                );
            }
            group
        };
        let labeled = |label: &'static str, text: &'static str| {
            div()
                .flex()
                .gap_2()
                .text_xs()
                .child(
                    div()
                        .w(px(110.0))
                        .flex_none()
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(label),
                )
                .child(div().flex_1().text_color(chrome.text_muted).child(text))
        };

        let mut content = div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_base()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(privacy::TITLE),
            )
            .child(ui::caption(privacy::INTRO, chrome))
            .child(section(privacy::DATA_HEADER))
            .child(ui::caption(privacy::DATA_INTRO, chrome))
            .child(data_box(
                privacy::ALWAYS_TITLE,
                Tone::Good,
                &privacy::ALWAYS_ROWS,
            ))
            .child(data_box(
                privacy::OPT_IN_TITLE,
                Tone::Warn,
                &privacy::OPT_IN_ROWS,
            ))
            .child(section(privacy::SUBPROCESSORS_HEADER))
            .child(ui::caption(privacy::SUBPROCESSORS_INTRO, chrome));
        for (i, sp) in privacy::SUBPROCESSORS.iter().enumerate() {
            let policy = sp.policy_url;
            let dpa = sp.dpa_url;
            content = content.child(
                ui::group("", chrome)
                    .gap_2()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(sp.name),
                    )
                    .child(labeled("Role", sp.role))
                    .child(labeled("Location", sp.location))
                    .child(labeled("Data processed", sp.data))
                    .child(labeled("Retention", sp.retention))
                    .child(
                        div()
                            .text_xs()
                            .italic()
                            .text_color(chrome.text_muted)
                            .child(sp.note),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_4()
                            .child(
                                div()
                                    .id(SharedString::from(format!("sp-policy-{i}")))
                                    .cursor_pointer()
                                    .text_xs()
                                    .text_color(ui::tone_color(Tone::Info, chrome))
                                    .child("\u{2197} Privacy Policy")
                                    .on_click(move |_, _, cx| cx.open_url(policy)),
                            )
                            .child(
                                div()
                                    .id(SharedString::from(format!("sp-dpa-{i}")))
                                    .cursor_pointer()
                                    .text_xs()
                                    .text_color(ui::tone_color(Tone::Info, chrome))
                                    .child("\u{2197} DPA")
                                    .on_click(move |_, _, cx| cx.open_url(dpa)),
                            ),
                    ),
            );
        }
        content = content.child(section(privacy::CONTROL_HEADER));
        for point in privacy::CONTROL_POINTS {
            content = content.child(bullet(point));
        }
        content = content.child(section(privacy::LEGAL_HEADER));
        for (label, text) in privacy::LEGAL_ROWS {
            content = content.child(labeled(label, text));
        }
        content = content
            .child(section(privacy::RIGHTS_HEADER))
            .child(ui::caption(privacy::RIGHTS_INTRO, chrome));
        for point in privacy::RIGHTS_POINTS {
            content = content.child(bullet(point));
        }
        content = content.child(ui::caption(privacy::RIGHTS_CONTACT, chrome));

        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(ui::page("privacy-page", content.p_3())),
            )
            .child(
                div()
                    .flex()
                    .justify_end()
                    .px_5()
                    .py_3()
                    .border_t_1()
                    .border_color(chrome.border)
                    .child(
                        ui::button("privacy-close", "Close", chrome).on_click(cx.listener(
                            |this, _, _, cx| {
                                this.show_privacy = false;
                                cx.notify();
                            },
                        )),
                    ),
            )
    }
}

impl Render for ReportView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        window.set_window_title(&crate::l10n::tr("Report an Issue - Chau7 Next"));
        let frame = div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                TitleBar::new().child(div().text_sm().child(crate::l10n::tr("Report an Issue"))),
            );
        if self.show_privacy {
            return frame.child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.privacy_page(chrome, cx)),
            );
        }
        let markdown = self.markdown(cx);
        let draft = self.draft.clone();

        let disclosure = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .gap_2()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child("\u{1F512}")
                    .child(div().flex_1().min_w_0().child(crate::l10n::tr("This goes to a private endpoint only Chau7's dev team can see. Nothing leaves your machine until you hit Submit. We read every report, yes, actually."))),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(div().text_color(ui::tone_color(Tone::Warn, chrome)).child("\u{270B}"))
                    .child(
                        div()
                            .flex_1().min_w_0()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(ui::caption("By default this report contains zero data from your Chau7 session. Nada. If you want to help us debug faster, you can opt into sharing diagnostics below, but fair warning: once it's out there, it's out of your hands.", chrome))
                            .child(
                                div()
                                    .id("privacy-link")
                                    .cursor_pointer()
                                    .text_xs()
                                    .text_color(ui::tone_color(Tone::Info, chrome))
                                    .child(crate::l10n::tr("Who sees what? (Third-party providers)"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.show_privacy = true;
                                        cx.notify();
                                    })),
                            ),
                    ),
            );

        let description = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(crate::l10n::tr("What happened?")),
            )
            .child(Textarea::new(&self.description).h(px(110.0)))
            .when(draft.description.is_empty(), |d| {
                d.child(ui::caption(
                    "Describe what happened and what you expected...",
                    chrome,
                ))
            });

        let contact = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(crate::l10n::tr("Your info (optional)")),
            )
            .child(Input::new(&self.name))
            .child(Input::new(&self.handle))
            .child(
                ui::checkbox(
                    "remember-contact",
                    "Remember for future reports",
                    self.save_contact,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.save_contact = !this.save_contact;
                    cx.notify();
                })),
            );

        let globals = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(crate::l10n::tr("Diagnostic information")),
            )
            .child(
                toggle_row(
                    "toggle-flags",
                    "Feature settings",
                    "Which features are enabled or disabled, no personal data.",
                    None,
                    draft.include_feature_flags,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.draft.include_feature_flags = !this.draft.include_feature_flags;
                    cx.notify();
                })),
            )
            .child(
                toggle_row(
                    "toggle-logs",
                    "Application logs",
                    "Last 50 log lines.",
                    Some("May contain file paths and command output."),
                    draft.include_logs,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.draft.include_logs = !this.draft.include_logs;
                    cx.notify();
                })),
            )
            .child(
                toggle_row(
                    "toggle-events",
                    "Recent events",
                    "Last 20 app events, tool calls and notifications.",
                    Some("Shows recent app activity."),
                    draft.include_events,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.draft.include_events = !this.draft.include_events;
                    cx.notify();
                })),
            );

        let mut tab_section = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(crate::l10n::tr("Tab-specific diagnostics")),
            )
            .child(
                toggle_row(
                    "toggle-metadata",
                    "Send tab metadata",
                    "Tab title, active app, status, and working directory.",
                    Some(
                        "Shares tab title, working directory, and app info from the selected tab.",
                    ),
                    draft.include_tab_metadata,
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.draft.include_tab_metadata = !this.draft.include_tab_metadata;
                    cx.notify();
                })),
            );
        if draft.include_tab_metadata {
            tab_section = tab_section.child(self.tab_picker(
                "meta-tab",
                draft.metadata_tab.as_deref(),
                chrome,
                cx,
                |d, id| d.metadata_tab = Some(id),
            ));
        }
        tab_section = tab_section.child(
            toggle_row(
                "toggle-history",
                "Send terminal history",
                "Last 50 lines of terminal output from the selected tab.",
                Some("Terminal output may contain commands, file paths, API keys, or other sensitive content."),
                draft.include_terminal_history,
                chrome,
            )
            .on_click(cx.listener(|this, _, _, cx| {
                this.draft.include_terminal_history = !this.draft.include_terminal_history;
                this.refresh_history(cx);
                cx.notify();
            })),
        );
        if draft.include_terminal_history {
            tab_section = tab_section.child(self.tab_picker(
                "history-tab",
                draft.history_tab.as_deref(),
                chrome,
                cx,
                |d, id| d.history_tab = Some(id),
            ));
        }
        tab_section = tab_section.child(
            toggle_row(
                "toggle-ai",
                "Send AI session info",
                "AI agent state, project name, and recent tool usage.",
                Some("Shares AI agent state and project name."),
                draft.include_ai_session,
                chrome,
            )
            .on_click(cx.listener(|this, _, _, cx| {
                this.draft.include_ai_session = !this.draft.include_ai_session;
                cx.notify();
            })),
        );

        let copy_text = markdown.clone();
        let preview = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(crate::l10n::tr("Report preview")),
                    )
                    .child(
                        div()
                            .id("preview-copy")
                            .cursor_pointer()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::tr("Copy"))
                            .on_click(move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copy_text.clone()))
                            }),
                    ),
            )
            .child(
                div()
                    .id("preview-box")
                    .h(px(200.0))
                    .overflow_y_scroll()
                    .p_2()
                    .rounded_md()
                    .border_1()
                    .border_color(chrome.border)
                    .bg(chrome.tab_bg.opacity(0.4))
                    .text_xs()
                    .font_family("Menlo")
                    .children(markdown.lines().map(|l| div().child(l.to_string()))),
            );

        let mut action_bar = div()
            .flex()
            .items_center()
            .gap_2()
            .px_5()
            .py_3()
            .border_t_1()
            .border_color(chrome.border);
        if let Some(error) = self.error.clone() {
            action_bar = action_bar.child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_xs()
                    .text_color(ui::tone_color(Tone::Bad, chrome))
                    .child(format!("\u{26A0} {error}")),
            );
        } else if let Some(number) = self.success {
            action_bar = action_bar.child(
                div()
                    .flex_1()
                    .text_xs()
                    .text_color(ui::tone_color(Tone::Good, chrome))
                    .child(format!("\u{2713} {}", success_text(number))),
            );
        } else {
            action_bar = action_bar.child(div().flex_1());
        }
        let submit_label = if self.submitting {
            "Submitting..."
        } else {
            "Submit"
        };
        action_bar = action_bar
            .child(
                ui::button("report-cancel", "Cancel", chrome)
                    .on_click(|_, window, _| window.remove_window()),
            )
            .child(
                ui::button("report-save-local", "Save Locally", chrome)
                    .on_click(cx.listener(|this, _, _, cx| this.save_locally(cx))),
            )
            .child(
                ui::button("report-submit", submit_label, chrome)
                    .bg(chrome
                        .accent
                        .opacity(if self.submitting || self.success.is_some() {
                            0.15
                        } else {
                            0.4
                        }))
                    .on_click(cx.listener(|this, _, window, cx| this.submit(window, cx))),
            );

        // "Report Saved" alert, with Show in Finder.
        let saved = self.saved.clone().map(|path| {
            let folder = PathBuf::from(&path)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_default();
            div()
                .flex()
                .items_center()
                .gap_2()
                .px_5()
                .py_2()
                .border_t_1()
                .border_color(chrome.border)
                .bg(ui::tone_color(Tone::Good, chrome).opacity(0.1))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_xs()
                        .child(format!("Report Saved. Saved to {path}")),
                )
                .child(
                    ui::button("saved-reveal", "Show in Finder", chrome)
                        .on_click(move |_, _, cx| cx.reveal_path(&folder)),
                )
                .child(ui::button("saved-ok", "OK", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.saved = None;
                        cx.notify();
                    },
                )))
        });

        frame
            .child(
                div().flex_1().min_h_0().child(ui::page(
                    "report-dialog-page",
                    div()
                        .flex()
                        .flex_col()
                        .gap_4()
                        .p_2()
                        .child(
                            div()
                                .text_lg()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(crate::l10n::tr("Report an Issue")),
                        )
                        .child(disclosure)
                        .child(description)
                        .child(contact)
                        .child(globals)
                        .child(tab_section)
                        .child(preview),
                )),
            )
            .when_some(saved, |d, bar| d.child(bar))
            .child(action_bar)
    }
}

/// The prefilled GitHub issue, used when the dialog cannot open.
#[allow(dead_code)]
pub fn fallback_url(snapshot: &StateSnapshot, report: &str) -> String {
    prefilled_issue_url(&snapshot.issue_title("Chau7"), report)
}

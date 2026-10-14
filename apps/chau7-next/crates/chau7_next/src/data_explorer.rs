//! Data Explorer window (`DataExplorer/*.swift`, View > Data Explorer,
//! Shift+Cmd+D): AI runs grouped by repository, every AI run with its tool
//! calls, and the command history. 900x600 (minimum 600x400), one window,
//! brought to the front and reloaded when opened again.
//!
//! The data comes from an [`ExplorerSource`]. The telemetry store (runs,
//! tool calls, cost) and the SQLite command history are other modules;
//! until they register their source with [`set_source`], runs are empty and
//! commands come from the shell integration's history file (command,
//! directory and time, no exit status or duration).

use std::sync::Arc;

use chau7_next_core::data_explorer::{
    self as dex, CommandTotals, HISTORY_LIMIT, ProviderColor, REPO_RUN_LIMIT, RUN_LIST_LIMIT,
    RateLevel, RepoRunGroup,
};
use chau7_next_core::history_record::HistoryRecord;
use chau7_next_core::telemetry::run::TelemetryRun;
use chrono::{TimeZone, Utc};
use gpui::{
    AnyWindowHandle, App, Context, Entity, Global, Hsla, Render, SharedString, Subscription,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, relative, size,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Icon, IconName, TitleBar};

use crate::theme::Chrome;
use crate::workspace::AppData;

/// Where the Data Explorer reads from (`TelemetryStore`,
/// `PersistentHistoryStore`).
pub trait ExplorerSource: Send + Sync {
    /// The most recent runs, newest first (`listRuns(filter:)`).
    fn runs(&self, limit: usize) -> Vec<TelemetryRun>;
    /// Tool calls of a run by name, most used first (`toolCallSummary`).
    fn tool_calls(&self, run_id: &str) -> Vec<(String, i64)>;
    /// Total cost of a repository's runs (`runStatsForRepo().totalCost`).
    fn repo_cost(&self, repo: &str) -> f64;
    /// Commands run in a repository (`commandStatsForRepo`).
    fn command_totals(&self, repo: &str) -> CommandTotals;
    /// Most recent commands (`recent(limit:)`).
    fn recent_commands(&self, limit: usize) -> Vec<HistoryRecord>;
    /// Commands containing `query` (`search(query:limit:)`).
    fn search_commands(&self, query: &str, limit: usize) -> Vec<HistoryRecord>;
    /// Records in the history (`totalCount`).
    fn command_count(&self) -> i64;
}

/// What is there before the telemetry and history stores register: no
/// runs, and the commands of the shell integration's history file.
struct HistoryFileSource {
    /// Parsed in the background (`history::shell_file`).
    entries: Arc<Vec<chau7_next_core::shell_integration::HistoryEntry>>,
}

impl HistoryFileSource {
    fn all(&self) -> Vec<HistoryRecord> {
        self.entries
            .iter()
            .cloned()
            .map(|entry| {
                let mut record = HistoryRecord::new(entry.command);
                record.directory = (!entry.directory.is_empty()).then_some(entry.directory);
                record.timestamp = Utc
                    .timestamp_opt(entry.time as i64, 0)
                    .single()
                    .unwrap_or(record.timestamp);
                record
            })
            .collect()
    }
}

impl ExplorerSource for HistoryFileSource {
    fn runs(&self, _limit: usize) -> Vec<TelemetryRun> {
        Vec::new()
    }
    fn tool_calls(&self, _run_id: &str) -> Vec<(String, i64)> {
        Vec::new()
    }
    fn repo_cost(&self, _repo: &str) -> f64 {
        0.0
    }
    fn command_totals(&self, _repo: &str) -> CommandTotals {
        CommandTotals::default()
    }
    fn recent_commands(&self, limit: usize) -> Vec<HistoryRecord> {
        self.all().into_iter().take(limit).collect()
    }
    fn search_commands(&self, query: &str, limit: usize) -> Vec<HistoryRecord> {
        let query = query.to_lowercase();
        self.all()
            .into_iter()
            .filter(|r| r.command.to_lowercase().contains(&query))
            .take(limit)
            .collect()
    }
    fn command_count(&self) -> i64 {
        self.entries.len() as i64
    }
}

struct SourceGlobal(Arc<dyn ExplorerSource>);
impl Global for SourceGlobal {}

/// Hook for the telemetry and history stores: the Data Explorer reads from
/// `source` from now on.
#[allow(dead_code)]
pub fn set_source(source: Arc<dyn ExplorerSource>, cx: &mut App) {
    cx.set_global(SourceGlobal(source));
}

fn source(cx: &App) -> Arc<dyn ExplorerSource> {
    match cx.try_global::<SourceGlobal>() {
        Some(global) => global.0.clone(),
        None => Arc::new(HistoryFileSource {
            entries: crate::history::shell_file::entries(cx),
        }),
    }
}

#[derive(Default)]
struct WindowHandle(Option<(AnyWindowHandle, gpui::WeakEntity<DataExplorerView>)>);
impl Global for WindowHandle {}

/// `DataExplorerWindow.show()`.
pub fn open(cx: &mut App) {
    if let Some((handle, view)) = cx.try_global::<WindowHandle>().and_then(|h| h.0.clone())
        && let Some(view) = view.upgrade()
        && handle
            .update(cx, |_, window, cx| {
                window.activate_window();
                view.update(cx, |v, cx| v.reload(cx));
            })
            .is_ok()
    {
        return;
    }
    let bounds = gpui::Bounds::centered(None, size(px(900.0), px(600.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(600.0), px(400.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(&crate::l10n::tr("Data Explorer"));
        cx.new(|cx| DataExplorerView::new(window, cx))
    }) {
        Ok((handle, view)) => cx.set_global(WindowHandle(Some((handle, view.downgrade())))),
        Err(err) => log::error!("data explorer window: {err}"),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Repos,
    Runs,
    History,
}

impl Tab {
    const ALL: [Tab; 3] = [Tab::Repos, Tab::Runs, Tab::History];

    fn label(self) -> &'static str {
        match self {
            Tab::Repos => "By Repo",
            Tab::Runs => "All Runs",
            Tab::History => "Commands",
        }
    }
}

pub struct DataExplorerView {
    tab: Tab,
    groups: Vec<RepoRunGroup>,
    runs: Vec<TelemetryRun>,
    selected_run: Option<String>,
    tool_summary: Vec<(String, i64)>,
    records: Vec<HistoryRecord>,
    total_count: i64,
    search: Entity<InputState>,
    home: String,
    _subscriptions: Vec<Subscription>,
}

impl DataExplorerView {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Search commands..."))
        });
        // Search on Return (`onSubmit`).
        let subscriptions = vec![cx.subscribe(&search, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.reload_history(cx);
            }
        })];
        let home = cx
            .global::<AppData>()
            .root
            .home()
            .to_string_lossy()
            .into_owned();
        let mut this = Self {
            tab: Tab::Repos,
            groups: Vec::new(),
            runs: Vec::new(),
            selected_run: None,
            tool_summary: Vec::new(),
            records: Vec::new(),
            total_count: 0,
            search,
            home,
            _subscriptions: subscriptions,
        };
        this.reload(cx);
        this
    }

    /// Each tab loads its data when it appears (and on reopen).
    fn reload(&mut self, cx: &mut Context<Self>) {
        match self.tab {
            Tab::Repos => self.reload_repos(cx),
            Tab::Runs => self.reload_runs(cx),
            Tab::History => self.reload_history(cx),
        }
        cx.notify();
    }

    fn reload_repos(&mut self, cx: &mut Context<Self>) {
        let source = source(cx);
        let runs = source.runs(REPO_RUN_LIMIT);
        self.groups = dex::group_runs_by_repo(
            &runs,
            |repo| source.command_totals(repo),
            |repo| source.repo_cost(repo),
        );
    }

    fn reload_runs(&mut self, cx: &mut Context<Self>) {
        self.runs = source(cx).runs(RUN_LIST_LIMIT);
    }

    fn reload_history(&mut self, cx: &mut Context<Self>) {
        let source = source(cx);
        let query = self.search.read(cx).value().trim().to_string();
        self.total_count = source.command_count();
        self.records = if query.is_empty() {
            source.recent_commands(HISTORY_LIMIT)
        } else {
            source.search_commands(&query, HISTORY_LIMIT)
        };
        cx.notify();
    }

    fn select_tab(&mut self, tab: Tab, cx: &mut Context<Self>) {
        if self.tab != tab {
            self.tab = tab;
            self.reload(cx);
        }
    }

    fn select_run(&mut self, id: String, cx: &mut Context<Self>) {
        self.tool_summary = source(cx).tool_calls(&id);
        self.selected_run = Some(id);
        cx.notify();
    }
}

fn provider_hsla(color: ProviderColor, chrome: Chrome) -> Hsla {
    match color {
        ProviderColor::Purple => gpui::rgb(0xaf52de).into(),
        ProviderColor::Green => gpui::rgb(0x28cd41).into(),
        ProviderColor::Orange => gpui::rgb(0xff9500).into(),
        ProviderColor::Teal => gpui::rgb(0x30b0c7).into(),
        ProviderColor::Secondary => chrome.text_muted,
    }
}

fn badge(provider: &str, chrome: Chrome, bold: bool) -> gpui::Div {
    let color = provider_hsla(dex::provider_color(provider), chrome);
    div()
        .px(px(5.0))
        .py(px(1.0))
        .rounded(px(3.0))
        .bg(color.opacity(if bold { 0.2 } else { 0.15 }))
        .text_color(color)
        .text_size(px(if bold { 11.0 } else { 10.0 }))
        .font_weight(if bold {
            gpui::FontWeight::BOLD
        } else {
            gpui::FontWeight::MEDIUM
        })
        .child(dex::capitalized(provider))
}

fn empty(text: &'static str, detail: Option<&'static str>, chrome: Chrome) -> gpui::Div {
    div()
        .size_full()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap_1()
        .child(div().text_color(chrome.text_muted).child(text))
        .children(detail.map(|d| {
            div()
                .text_size(px(12.0))
                .text_color(chrome.text_muted.opacity(0.7))
                .child(d)
        }))
}

impl DataExplorerView {
    fn render_repos(&self, chrome: Chrome) -> gpui::AnyElement {
        if self.groups.is_empty() {
            return empty("No AI sessions recorded yet", None, chrome).into_any_element();
        }
        let now = Utc::now();
        let mut list = div().id("dex-repos").size_full().overflow_y_scroll();
        for group in &self.groups {
            let rate = group.success_rate;
            let rate_color: Hsla = match dex::rate_level(rate) {
                RateLevel::Good => gpui::rgb(0x28cd41).into(),
                RateLevel::Fair => gpui::rgb(0xffcc00).into(),
                RateLevel::Poor => gpui::rgb(0xff3b30).into(),
            };
            let mut stats = div().flex().items_center().gap_3().text_size(px(10.0));
            for provider in &group.providers {
                stats = stats.child(badge(provider, chrome, false));
            }
            stats = stats
                .child(div().flex_1())
                .when(group.total_commands > 0, |d| {
                    d.child(
                        div()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::count(
                                "explorer.sessions.cmds",
                                "%d cmds",
                                group.total_commands,
                            )),
                    )
                    .child(
                        div()
                            .text_size(px(9.0))
                            .font_family("monospace")
                            .text_color(rate_color)
                            .child(dex::format_rate(rate)),
                    )
                })
                .child(
                    div()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::count(
                            "explorer.sessions.runs",
                            "%d runs",
                            group.run_count,
                        )),
                )
                .when(group.total_tokens > 0, |d| {
                    d.child(
                        div()
                            .font_family("monospace")
                            .text_color(gpui::rgb(0x007aff))
                            .child(chau7_next_core::l10n::numbers::abbreviated(
                                group.total_tokens,
                            )),
                    )
                })
                .when(group.total_cost > 0.0, |d| {
                    d.child(
                        div()
                            .font_family("monospace")
                            .text_color(gpui::rgb(0xff9500))
                            .child(chau7_next_core::l10n::numbers::currency(group.total_cost)),
                    )
                });
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.0))
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(chrome.border)
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                Icon::new(IconName::Folder)
                                    .size(px(12.0))
                                    .text_color(gpui::rgb(0x007aff)),
                            )
                            .child(
                                div()
                                    .text_size(px(13.0))
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(group.repo_name.clone()),
                            )
                            .child(div().flex_1())
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(chrome.text_muted.opacity(0.7))
                                    .child(dex::relative_time(group.last_active, now)),
                            ),
                    )
                    .child(stats),
            );
        }
        list.into_any_element()
    }

    fn render_runs(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::AnyElement {
        let left = if self.runs.is_empty() {
            empty("No AI runs recorded yet", None, chrome).into_any_element()
        } else {
            let now = Utc::now();
            let with_tokens = self
                .runs
                .iter()
                .filter(|r| r.token_usage().has_any_tokens())
                .count();
            let mut list = div().id("dex-runs").flex_1().overflow_y_scroll();
            for run in &self.runs {
                let id = run.id.clone();
                let selected = self.selected_run.as_deref() == Some(run.id.as_str());
                let tokens = run.token_usage().total_billable_tokens();
                list = list.child(
                    div()
                        .id(SharedString::from(format!("dex-run-{}", run.id)))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .px_3()
                        .py(px(5.0))
                        .cursor_pointer()
                        .when(selected, |d| d.bg(chrome.accent.opacity(0.25)))
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .on_click(
                            cx.listener(move |this, _, _, cx| this.select_run(id.clone(), cx)),
                        )
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(badge(&run.provider, chrome, true))
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .font_weight(gpui::FontWeight::MEDIUM)
                                        .truncate()
                                        .child(dex::run_repo_name(run)),
                                )
                                .child(div().flex_1())
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(chrome.text_muted.opacity(0.7))
                                        .child(dex::relative_time(run.started_at, now)),
                                ),
                        )
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .text_size(px(10.0))
                                .child(
                                    div()
                                        .font_family("monospace")
                                        .text_color(chrome.text_muted)
                                        .child(dex::short_session_id(run)),
                                )
                                .when(run.turn_count > 0, |d| {
                                    d.child(div().text_color(chrome.text_muted).child(
                                        crate::l10n::count(
                                            "hovercard.turns",
                                            "%d turns",
                                            run.turn_count,
                                        ),
                                    ))
                                })
                                .when(tokens > 0, |d| {
                                    d.child(
                                        div()
                                            .font_family("monospace")
                                            .text_color(gpui::rgb(0x007aff))
                                            .child(chau7_next_core::l10n::numbers::abbreviated(
                                                tokens,
                                            )),
                                    )
                                })
                                .children(run.model.clone().filter(|m| !m.is_empty()).map(|m| {
                                    div()
                                        .text_size(px(9.0))
                                        .font_family("monospace")
                                        .text_color(chrome.text_muted.opacity(0.7))
                                        .truncate()
                                        .child(m)
                                })),
                        ),
                );
            }
            div()
                .flex()
                .flex_col()
                .size_full()
                .child(
                    div()
                        .flex()
                        .px_3()
                        .py(px(6.0))
                        .text_size(px(11.0))
                        .text_color(chrome.text_muted)
                        .border_b_1()
                        .border_color(chrome.border)
                        .child(div().font_weight(gpui::FontWeight::MEDIUM).child(
                            crate::l10n::count("explorer.runs.count", "%d runs", self.runs.len()),
                        ))
                        .child(div().flex_1())
                        .when(with_tokens > 0, |d| {
                            d.child(div().opacity(0.7).child(crate::l10n::count(
                                "explorer.runs.withTokens",
                                "%d with token data",
                                with_tokens,
                            )))
                        }),
                )
                .child(list)
                .into_any_element()
        };
        let detail = match &self.selected_run {
            None => empty("Select a run to view details", None, chrome).into_any_element(),
            Some(_) if self.tool_summary.is_empty() => {
                empty("No tool calls recorded for this run", None, chrome).into_any_element()
            }
            Some(_) => {
                let max = self.tool_summary.first().map(|t| t.1).unwrap_or(1).max(1);
                let mut bars = div().flex().flex_col().gap(px(6.0)).p_4().child(
                    div()
                        .text_size(px(13.0))
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .child(crate::l10n::tr("Tool Calls")),
                );
                for (tool, count) in &self.tool_summary {
                    bars = bars.child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .w(px(100.0))
                                    .flex()
                                    .justify_end()
                                    .font_family("monospace")
                                    .text_size(px(12.0))
                                    .truncate()
                                    .child(tool.clone()),
                            )
                            .child(
                                div().flex_1().h(px(14.0)).child(
                                    div()
                                        .h_full()
                                        .w(relative(*count as f32 / max as f32))
                                        .rounded(px(2.0))
                                        .bg(gpui::rgb(0x007aff).opacity(0.6)),
                                ),
                            )
                            .child(
                                div()
                                    .w(px(40.0))
                                    .flex()
                                    .justify_end()
                                    .font_family("monospace")
                                    .text_size(px(11.0))
                                    .text_color(chrome.text_muted)
                                    .child(count.to_string()),
                            ),
                    );
                }
                div()
                    .id("dex-detail")
                    .size_full()
                    .overflow_y_scroll()
                    .child(bars)
                    .into_any_element()
            }
        };
        div()
            .size_full()
            .flex()
            .child(div().flex_1().min_w(px(420.0)).h_full().child(left))
            .child(div().w(px(1.0)).h_full().bg(chrome.border))
            .child(div().w(px(300.0)).flex_none().h_full().child(detail))
            .into_any_element()
    }

    fn render_history(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let header = div()
            .flex()
            .items_center()
            .gap_2()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(chrome.border)
            .child(
                Icon::new(IconName::Search)
                    .size(px(12.0))
                    .text_color(chrome.text_muted),
            )
            .child(
                div()
                    .flex_1()
                    .child(Input::new(&self.search).appearance(false)),
            )
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::count(
                        "explorer.history.totalRecords",
                        "%d total records",
                        self.total_count,
                    )),
            );
        let body = if self.records.is_empty() {
            empty(
                if searching {
                    "No matching commands"
                } else {
                    "No command history yet"
                },
                Some("Commands will appear here as you use the terminal"),
                chrome,
            )
            .into_any_element()
        } else {
            let mut list = div().id("dex-history").flex_1().overflow_y_scroll();
            for record in &self.records {
                let (symbol, color): (&str, Hsla) = match record.exit_code {
                    Some(0) => ("✓", gpui::rgb(0x28cd41).into()),
                    Some(_) => ("✕", gpui::rgb(0xff3b30).into()),
                    None => ("○", chrome.text_muted),
                };
                list = list.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_3()
                        .px_3()
                        .py(px(2.0))
                        .child(div().w(px(16.0)).text_color(color).child(symbol))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .font_family("monospace")
                                .text_size(px(12.0))
                                .child(record.command.clone()),
                        )
                        .children(record.directory.as_deref().map(|dir| {
                            div()
                                .w(px(150.0))
                                .flex()
                                .justify_end()
                                .truncate()
                                .text_size(px(11.0))
                                .text_color(chrome.text_muted)
                                .child(dex::shorten_path(dir, &self.home))
                        }))
                        .children(record.duration.filter(|d| *d > 0.0).map(|d| {
                            div()
                                .w(px(60.0))
                                .flex()
                                .justify_end()
                                .font_family("monospace")
                                .text_size(px(11.0))
                                .text_color(chrome.text_muted)
                                .child(dex::format_duration(d))
                        }))
                        .child(
                            div()
                                .w(px(70.0))
                                .flex()
                                .justify_end()
                                .text_size(px(11.0))
                                .text_color(chrome.text_muted)
                                .child(dex::format_clock(record.timestamp)),
                        ),
                );
            }
            list.into_any_element()
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(body)
            .into_any_element()
    }
}

impl Render for DataExplorerView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let mut picker = div()
            .flex()
            .p(px(2.0))
            .rounded_md()
            .bg(chrome.tab_bg)
            .text_size(px(12.0));
        for tab in Tab::ALL {
            let selected = self.tab == tab;
            picker = picker.child(
                div()
                    .id(tab.label())
                    .px_4()
                    .py(px(3.0))
                    .rounded_md()
                    .cursor_pointer()
                    .when(selected, |d| d.bg(chrome.tab_selected_bg))
                    .text_color(if selected {
                        chrome.text
                    } else {
                        chrome.text_muted
                    })
                    .child(tab.label())
                    .on_click(cx.listener(move |this, _, _, cx| this.select_tab(tab, cx))),
            );
        }
        let content = match self.tab {
            Tab::Repos => self.render_repos(chrome),
            Tab::Runs => self.render_runs(chrome, cx),
            Tab::History => self.render_history(chrome, cx),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .text_size(px(13.0))
            .child(crate::theme::panel_titlebar(chrome))
            .child(div().flex().justify_center().p_3().child(picker))
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(div().flex_1().min_h_0().child(content))
    }
}

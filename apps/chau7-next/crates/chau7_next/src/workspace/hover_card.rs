//! Tab hover card (`TabHoverCard.swift`): appears after 0.4 s on a tab,
//! switches instantly to another tab while shown, stays while the pointer
//! moves onto it (0.15 s grace), and lists what the tab is doing. Each row
//! has a `[next] hover_card_show_*` toggle (`hoverCard.*` in Swift).

use std::time::Duration;

use chau7_next_core::repository::format_tokens;
use chau7_next_core::tab_bar_text::{format_cpu, format_rss, relative_age, truncate_middle};
use chau7_next_core::tabs_state::{next_token_opt_override, token_opt_override_state};
use chau7_next_core::token_optimization::{TokenOptimizationMode, should_be_active};
use gpui::{
    App, Context, Hsla, MouseButton, Pixels, SharedString, Task, anchored, deferred, div, img,
    point, prelude::*, px,
};

use super::tab_bar_view::ai_logo;
use super::{AppData, Workspace};
use chau7_next_core::shell_session::CommandStatus;

use crate::monitoring::processes::{self, CpuSamples, PollSchedule, ProcessSnapshot};
use crate::platform::process as procinfo;
use crate::settings::Settings;
use crate::tab_bar::{StyleColor, TabId, style_color};
use crate::theme::{Chrome, tab_color};

/// Card width (`TabHoverCard`: 280 pt, 12 pt from the window edges).
const CARD_WIDTH: f32 = 280.0;

/// Whether the hover card should report this tab's background rendering state.
/// The prewarm snapshot records suspension before previewing resumes the session;
/// it is a UI status flag and does not claim the session remains CPU-idle.
fn should_show_render_suspension_row(
    suspend_background_enabled: bool,
    tab_selected: bool,
    surface_visible: bool,
    suspended_before_hover_prewarm: bool,
    session_render_suspended: bool,
) -> bool {
    suspend_background_enabled
        && !tab_selected
        && !surface_visible
        && (suspended_before_hover_prewarm || session_render_suspended)
}

pub(super) struct HoverState {
    pub(super) tab: TabId,
    pub(super) shown: bool,
    anchor_x: Pixels,
    /// The pointer is over the card itself.
    over_card: bool,
    /// Show delay or dismiss grace timer.
    _timer: Option<Task<()>>,
    /// Process sampling, only while the card is shown.
    _monitor: Option<Task<()>>,
    processes: Option<ProcessSnapshot>,
    /// Captured before hover prewarming resumes a hidden surface.
    was_render_suspended_before_prewarm: bool,
}

/// Global token optimization mode (`tokenOptimizationMode`); off hides the
/// hover card row.
pub(crate) fn token_optimization_mode(cx: &App) -> TokenOptimizationMode {
    crate::settings::Settings::get(cx).cto.mode
}

impl Workspace {
    /// `tabHoverBegan` / `tabHoverEnded`. `anchor` overrides the card's
    /// horizontal center (idle popover rows).
    pub(super) fn hover_tab(
        &mut self,
        id: TabId,
        hovered: bool,
        anchor: Option<Pixels>,
        cx: &mut Context<Self>,
    ) {
        if self.drag.as_ref().is_some_and(|d| d.active) {
            return;
        }
        // Hover prewarming resumes the hidden session; preserve its actual state
        // first so the card can still report that the tab was suspended.
        let was_render_suspended_before_prewarm = hovered
            && self
                .entries
                .get(&id)
                .and_then(|entry| entry.panes.read(cx).focused_session(cx))
                .is_some_and(|session| session.read(cx).is_render_suspended());
        if self.state.selected() != Some(id)
            && let Some(panes) = self.entries.get(&id).map(|entry| entry.panes.clone())
        {
            panes.update(cx, |panes, cx| panes.prewarm_surface(hovered, cx));
        }
        if hovered {
            let anchor_x = anchor.unwrap_or_else(|| {
                self.frames
                    .borrow()
                    .tabs
                    .get(&id)
                    .map(|b| b.center().x)
                    .unwrap_or_default()
            });
            if let Some(hover) = self.hover.as_mut()
                && hover.shown
            {
                // Card already visible: switch instantly.
                if hover.tab != id {
                    hover.tab = id;
                    hover.anchor_x = anchor_x;
                    hover.processes = None;
                    hover.was_render_suspended_before_prewarm = was_render_suspended_before_prewarm;
                    self.start_process_monitor(cx);
                }
                if let Some(hover) = self.hover.as_mut() {
                    hover._timer = None;
                }
                cx.notify();
                return;
            }
            log::info!("TABBAR prewarm tab={id}");
            let timer = cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(400))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    if let Some(hover) = this.hover.as_mut()
                        && hover.tab == id
                    {
                        hover.shown = true;
                        hover._timer = None;
                        log::info!("TABBAR hover_card tab={id}");
                        this.start_process_monitor(cx);
                        cx.notify();
                    }
                });
            });
            self.hover = Some(HoverState {
                tab: id,
                shown: false,
                anchor_x,
                over_card: false,
                _timer: Some(timer),
                _monitor: None,
                processes: None,
                was_render_suspended_before_prewarm,
            });
        } else if self.hover.as_ref().is_some_and(|h| h.tab == id) {
            log::info!("TABBAR cancel_prewarm tab={id}");
            if self.hover.as_ref().is_some_and(|h| h.shown) {
                self.start_dismiss_timer(cx);
            } else {
                self.hover = None;
                cx.notify();
            }
        }
    }

    /// `startHoverCardDismissTimer`: hide after 0.15 s unless the pointer
    /// reaches the card or another tab.
    fn start_dismiss_timer(&mut self, cx: &mut Context<Self>) {
        let timer = cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.hover.as_ref().is_some_and(|h| !h.over_card) {
                    this.hover = None;
                    cx.notify();
                }
            });
        });
        if let Some(hover) = self.hover.as_mut() {
            hover._timer = Some(timer);
        }
    }

    /// `dismissHoverCard`: on select, close, rename and drag.
    pub(super) fn dismiss_hover_card(&mut self, cx: &mut Context<Self>) {
        if self.hover.take().is_some() {
            cx.notify();
        }
    }

    fn hover_card_hovered(&mut self, hovered: bool, cx: &mut Context<Self>) {
        let Some(hover) = self.hover.as_mut() else {
            return;
        };
        hover.over_card = hovered;
        if hovered {
            hover._timer = None;
        } else {
            self.start_dismiss_timer(cx);
        }
    }

    /// Poll the hovered tab's processes while the card is shown
    /// (`startProcessMonitoring`): 0.75 s, backing off to 3 s when idle.
    fn start_process_monitor(&mut self, cx: &mut Context<Self>) {
        if !Settings::get(cx).hover_card.show_processes {
            return;
        }
        let Some(tab) = self.hover.as_ref().map(|h| h.tab) else {
            return;
        };
        let Some(shell_pid) = self
            .entries
            .get(&tab)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
            .map(|s| s.read(cx).shell_pid() as u32)
        else {
            return;
        };
        let monitor = cx.spawn(async move |this, cx| {
            let mut samples = CpuSamples::new();
            let mut schedule = PollSchedule::default();
            loop {
                let snapshot = cx
                    .background_executor()
                    .spawn({
                        let mut previous = std::mem::take(&mut samples);
                        async move {
                            let snapshot = processes::sample(shell_pid, &mut previous);
                            (snapshot, previous)
                        }
                    })
                    .await;
                samples = snapshot.1;
                let delay = schedule.after_poll(&snapshot.0);
                let alive = this
                    .update(cx, |this, cx| {
                        let Some(hover) = this.hover.as_mut().filter(|h| h.tab == tab) else {
                            return false;
                        };
                        hover.processes = Some(snapshot.0);
                        cx.notify();
                        true
                    })
                    .unwrap_or(false);
                if !alive {
                    break;
                }
                cx.background_executor().timer(delay).await;
            }
        });
        if let Some(hover) = self.hover.as_mut() {
            hover._monitor = Some(monitor);
        }
    }

    /// `toggleTokenOpt(for:)`.
    fn toggle_token_opt(&mut self, id: TabId, cx: &mut Context<Self>) {
        let mode = token_optimization_mode(cx);
        if let Some(meta) = self.state.get(id)
            && let Some(next) = next_token_opt_override(mode, meta.token_opt_override)
        {
            self.apply_token_opt_override(id, next, true, cx);
            cx.notify();
        }
    }

    pub(super) fn render_hover_card(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let hover = self.hover.as_ref().filter(|h| h.shown)?;
        let id = hover.tab;
        let entry = self.entries.get(&id)?;
        let meta = self.state.get(id)?;
        let session = entry.panes.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        let settings = Settings::get(cx).clone();
        let show = &settings.hover_card;
        let home = cx.global::<AppData>().root.home().to_path_buf();
        // The card is always dark (Swift: 0.10 gray), whatever the theme.
        let primary = gpui::hsla(0.0, 0.0, 0.92, 1.0);
        let muted = primary.opacity(0.6);
        let color = |c: StyleColor| style_color(c, primary);
        let mono = "Menlo";
        let is_render_suspended = should_show_render_suspension_row(
            settings.appearance.rendering.suspend_background,
            self.state.selected() == Some(id),
            session.restore_surface_visible(),
            hover.was_render_suspended_before_prewarm,
            session.is_render_suspended(),
        );

        // Header: AI logo (dim when not running) or color dot, title, status.
        let ai_app = session.ai_display_app_name();
        let ai_running = session.is_ai_running();
        // `statusLabel`.
        let (status, status_color) = if session.exited.is_some() {
            ("Exited", muted)
        } else {
            match session.status() {
                CommandStatus::Running => ("Running", color(StyleColor::Green)),
                CommandStatus::WaitingForInput => ("Waiting", color(StyleColor::Orange)),
                CommandStatus::Stuck => ("Stuck", color(StyleColor::Red)),
                CommandStatus::Exited => ("Exited", muted),
                CommandStatus::Idle => ("Idle", muted),
                CommandStatus::Done => ("Done", muted),
                CommandStatus::ApprovalRequired => ("Approval required", color(StyleColor::Orange)),
            }
        };
        let leading = match ai_app.as_deref().and_then(ai_logo) {
            Some(logo) => img(logo)
                .size(px(16.0))
                .opacity(if ai_running { 1.0 } else { 0.35 })
                .into_any_element(),
            None => div()
                .size(px(10.0))
                .rounded_full()
                .bg(tab_color(self.effective_color(id, cx)))
                .into_any_element(),
        };
        let header = div()
            .flex()
            .items_center()
            .gap_2()
            .px_3()
            .py_2()
            .child(leading)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis()
                    .text_sm()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(self.tab_title(id, cx)),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .child(div().size(px(6.0)).rounded_full().bg(status_color))
                    .child(div().text_xs().text_color(status_color).child(status)),
            );

        let row = |icon: &'static str, icon_color: Hsla| {
            div().flex().items_center().gap_2().text_xs().child(
                div()
                    .w(px(16.0))
                    .flex_shrink_0()
                    .text_color(icon_color)
                    .child(icon),
            )
        };
        let label = |text: SharedString| {
            div()
                .flex_1()
                .min_w_0()
                .overflow_hidden()
                .whitespace_nowrap()
                .text_ellipsis()
                .child(text)
        };
        let value = |text: SharedString, c: Hsla| div().font_family(mono).text_color(c).child(text);

        let mut rows: Vec<gpui::AnyElement> = Vec::new();
        if show.show_directory
            && let Some(cwd) = &session.cwd
        {
            let path = truncate_middle(&procinfo::display_path(cwd, &home), 36);
            rows.push(
                row("🗀", muted)
                    .child(label(path.into()).font_family(mono))
                    .into_any_element(),
            );
        }
        if show.show_git_branch
            && session.git_root.is_some()
            && let Some(branch) = session.git_branch.clone().filter(|b| !b.is_empty())
        {
            rows.push(
                row("⑂", muted)
                    .child(label(branch.into()).font_family(mono))
                    .into_any_element(),
            );
        }
        if show.show_shell_integration {
            // `hasShellIntegration`: the shell has sent an OSC 133 mark.
            let active = session.shell().has_shell_integration();
            rows.push(
                row(
                    if active { "✓" } else { "⚠" },
                    if active {
                        color(StyleColor::Green)
                    } else {
                        color(StyleColor::Orange)
                    },
                )
                .child(
                    label(
                        if active {
                            "Shell integration active"
                        } else {
                            "Heuristic detection"
                        }
                        .into(),
                    )
                    .text_color(muted),
                )
                .into_any_element(),
            );
        }
        if show.show_dev_server
            && let Some(server) = session.dev_server().cloned()
        {
            // `devServerRow`: bolt for Vite, server icon otherwise, open button.
            let vite = server.name.eq_ignore_ascii_case("Vite");
            let url = server.open_url();
            rows.push(
                row(
                    if vite { "⚡" } else { "▦" },
                    if vite {
                        color(StyleColor::Yellow)
                    } else {
                        muted
                    },
                )
                .child(
                    div()
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(server.name.clone()),
                )
                .when_some(server.port, |d, port| {
                    d.child(value(format!(":{port}").into(), muted))
                })
                .child(div().flex_1())
                .when_some(url, |d, url| {
                    d.child(
                        div()
                            .id("hover-dev-server-open")
                            .px_1()
                            .rounded_sm()
                            .text_color(color(StyleColor::Blue))
                            .hover(|d| d.bg(chrome.tab_hover_bg))
                            .child("↗")
                            .on_click(move |_, _, cx| cx.open_url(&url)),
                    )
                })
                .into_any_element(),
            );
        }
        if show.show_processes
            && let Some(snapshot) = hover.processes.as_ref().filter(|s| !s.children.is_empty())
        {
            let total_cpu = snapshot.total_cpu();
            rows.push(
                row("▤", muted)
                    .child(label("Processes".into()).font_weight(gpui::FontWeight::MEDIUM))
                    .child(value(
                        format_cpu(total_cpu).into(),
                        if total_cpu > 50.0 {
                            color(StyleColor::Orange)
                        } else {
                            muted
                        },
                    ))
                    .child(value(format_rss(snapshot.total_rss()).into(), muted))
                    .into_any_element(),
            );
            for child in snapshot.children.iter().take(5) {
                rows.push(
                    row("", muted)
                        .child(label(truncate_middle(&child.name, 20).into()).font_family(mono))
                        .child(value(format!("({})", child.pid).into(), muted))
                        .child(value(
                            format_cpu(child.cpu_percent).into(),
                            if child.cpu_percent > 25.0 {
                                color(StyleColor::Orange)
                            } else {
                                muted
                            },
                        ))
                        .child(value(format_rss(child.rss_bytes).into(), muted))
                        .into_any_element(),
                );
            }
            if snapshot.children.len() > 5 {
                rows.push(
                    row("", muted)
                        .child(
                            label(format!("+{} more", snapshot.children.len() - 5).into())
                                .text_color(muted),
                        )
                        .into_any_element(),
                );
            }
        }
        if show.show_last_command
            && let Some(cmd) = session.last_command
        {
            let ok = cmd.exit_code == 0;
            // The command text, one line (`TabHoverCard.lastCommandRow`).
            let text = session
                .last_command_text()
                .map(|t| t.lines().next().unwrap_or_default().to_string())
                .unwrap_or_else(|| "Last command".to_string());
            rows.push(
                row(">_", muted)
                    .child(
                        label(text.into())
                            .font_family(mono)
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis(),
                    )
                    .child(
                        div()
                            .text_color(if ok {
                                color(StyleColor::Green)
                            } else {
                                color(StyleColor::Red)
                            })
                            .child(if ok { "✓" } else { "✗" }),
                    )
                    .child(div().text_color(muted).child(
                        chau7_next_core::tab_bar_text::command_duration(cmd.duration.as_secs_f64()),
                    ))
                    .when(!ok, |d| {
                        d.child(
                            div()
                                .text_color(muted)
                                .child(format!("exit {}", cmd.exit_code)),
                        )
                    })
                    .into_any_element(),
            );
        }
        if show.show_ai_session {
            // `aiSessionRow` (OVL-060, TEL-011): the run in progress in one
            // of the tab's terminals, else the latest run when it belongs to
            // the tab. Runs are keyed by each terminal's `tab_identifier`
            // (Swift asks with the tab UUID, which never matches a run).
            let mut ids: Vec<String> = entry
                .panes
                .read(cx)
                .views()
                .iter()
                .map(|v| v.read(cx).session.read(cx).tab_identifier.clone())
                .collect();
            ids.push(crate::workspace::mcp::uuid_string(meta.uuid));
            if let Some((run, tools)) = crate::telemetry::hover_summary(&ids, cx) {
                let mut provider = run.provider.clone();
                if let Some(first) = provider.get_mut(0..1) {
                    first.make_ascii_uppercase();
                }
                let mut block = div().flex().flex_col().gap_1().child(
                    row("◉", color(StyleColor::Purple))
                        .child(label(provider.into()).font_weight(gpui::FontWeight::SEMIBOLD))
                        .when_some(run.model.clone(), |d, model| {
                            d.child(
                                div()
                                    .font_family(mono)
                                    .text_size(px(10.0))
                                    .text_color(muted)
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .text_ellipsis()
                                    .child(model),
                            )
                        }),
                );
                let (tokens_in, tokens_out) = (
                    run.total_input_tokens.unwrap_or(0),
                    run.total_output_tokens.unwrap_or(0),
                );
                let mut numbers = div().pl(px(24.0)).flex().gap_3().text_size(px(10.0));
                if tokens_in + tokens_out > 0 {
                    numbers =
                        numbers.child(div().font_family(mono).text_color(muted).child(format!(
                            "{} in / {} out",
                            format_tokens(tokens_in),
                            format_tokens(tokens_out)
                        )));
                }
                if let Some(cost) = run.cost_usd.filter(|c| *c > 0.0) {
                    numbers = numbers.child(
                        div()
                            .font_family(mono)
                            .text_color(color(StyleColor::Orange))
                            .child(format!("${cost:.2}")),
                    );
                }
                if run.turn_count > 0 {
                    numbers = numbers.child(
                        div()
                            .text_color(muted)
                            .child(format!("{} turns", run.turn_count)),
                    );
                }
                block = block.child(numbers);
                if !tools.is_empty() {
                    block = block.child(
                        div()
                            .pl(px(24.0))
                            .flex()
                            .gap_2()
                            .font_family(mono)
                            .text_size(px(10.0))
                            .text_color(muted)
                            .children(
                                tools
                                    .iter()
                                    .take(3)
                                    .map(|(tool, count)| format!("{tool} \u{00d7}{count}")),
                            ),
                    );
                }
                rows.push(block.into_any_element());
            } else if let Some(app) = &ai_app {
                // No telemetry for this tab (yet): the AI tool running in it.
                rows.push(
                    row("◉", color(StyleColor::Purple))
                        .child(label(app.clone().into()).font_weight(gpui::FontWeight::SEMIBOLD))
                        .into_any_element(),
                );
            }
        }
        // Repo stats (OVL-061): runs, tokens, cost and commands of the
        // repository (or folder) the tab is in.
        if show.show_repo_stats {
            let root = session
                .git_root
                .as_ref()
                .or(session.cwd.as_ref())
                .map(|p| p.to_string_lossy().to_string());
            if let Some(stats) = root.and_then(|r| crate::repository::stats(&r, cx))
                && (stats.total_runs > 0 || stats.total_commands > 0)
            {
                rows.push(
                    row("\u{25a4}", color(StyleColor::Blue))
                        .child(
                            label(stats.hover_line().into())
                                .font_family(mono)
                                .text_color(muted)
                                .text_size(px(10.0)),
                        )
                        .into_any_element(),
                );
            }
        }
        // File conflicts (OVL-062): files this tab and another tab changed.
        if show.show_conflicts {
            let conflicts = crate::ai::hub::conflicts_for_tab(id, cx);
            if !conflicts.is_empty() {
                let orange = color(StyleColor::Orange);
                let mut block = div().flex().flex_col().gap_1().child(
                    row("\u{26a0}", orange).child(
                        label(format!("File Conflicts ({})", conflicts.len()).into())
                            .text_color(orange)
                            .font_weight(gpui::FontWeight::SEMIBOLD),
                    ),
                );
                for conflict in conflicts.iter().take(3) {
                    block = block.child(
                        div()
                            .pl(px(24.0))
                            .font_family(mono)
                            .text_size(px(10.0))
                            .text_color(muted)
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .child(conflict.clone()),
                    );
                }
                if conflicts.len() > 3 {
                    block = block.child(
                        div()
                            .pl(px(24.0))
                            .text_size(px(10.0))
                            .text_color(muted)
                            .child(format!("+{} more", conflicts.len() - 3)),
                    );
                }
                rows.push(block.into_any_element());
            }
        }
        let mode = token_optimization_mode(cx);
        if show.show_token_optimization && mode != TokenOptimizationMode::Off {
            let is_ai = ai_app.is_some();
            let active = should_be_active(mode, meta.token_opt_override, is_ai);
            let (text, c) = match token_opt_override_state(mode, meta.token_opt_override) {
                Some(_) if active => ("Forced On", color(StyleColor::Yellow)),
                Some(_) => ("Forced Off", color(StyleColor::Red)),
                None if active => ("Active", color(StyleColor::Green)),
                None => ("Off", muted),
            };
            rows.push(
                row(
                    "✦",
                    if active {
                        color(StyleColor::Yellow)
                    } else {
                        muted
                    },
                )
                .child(label("Token Optimization".into()))
                .child(value(text.into(), c))
                .when(settings.tabs.allow_cto_toggle, |d| {
                    d.child(
                        div()
                            .id("hover-cto-toggle")
                            .px_1()
                            .rounded_sm()
                            .text_color(muted)
                            .hover(|d| d.bg(chrome.tab_hover_bg))
                            .child("⇄")
                            .on_click(
                                cx.listener(move |this, _, _, cx| this.toggle_token_opt(id, cx)),
                            ),
                    )
                })
                .into_any_element(),
            );
        }
        if show.show_broadcast && self.broadcast && !self.broadcast_excluded.contains(&id) {
            rows.push(
                row("⦿", color(StyleColor::Orange))
                    .child(label("Broadcast".into()))
                    .child(value("Included".into(), color(StyleColor::Orange)))
                    .into_any_element(),
            );
        }
        if is_render_suspended {
            rows.push(
                row("⏸︎", muted)
                    .child(label(
                        crate::l10n::l("hovercard.rendering", "Rendering").into(),
                    ))
                    .child(value(
                        crate::l10n::l("hovercard.suspended", "Suspended").into(),
                        muted,
                    ))
                    .into_any_element(),
            );
        }
        if show.show_notification_state
            && let Some(style) = entry.notification.as_ref()
        {
            let (summary, summary_color) = style.summary();
            let icon_color = style
                .icon_color
                .or(style.title_color)
                .map(|c| style_color(c, muted))
                .unwrap_or(muted);
            rows.push(
                row(style.icon.unwrap_or("🔔︎"), icon_color)
                    .child(label("Notification".into()))
                    .child(value(
                        summary.into(),
                        summary_color.map(color).unwrap_or(muted),
                    ))
                    .into_any_element(),
            );
        }

        let footer = show.show_footer.then(|| {
            let age = relative_age(AppData::now(cx) - meta.created_at);
            let bookmarks = entry.bookmarks.len();
            // `footerSessionId`: the AI session id when it is valid.
            let session_id = session
                .shell()
                .ai_session_id()
                .map(str::trim)
                .filter(|s| chau7_next_core::ai::resume::is_valid_session_id(s))
                .map(str::to_string);
            div()
                .flex()
                .items_center()
                .gap_1()
                .px_3()
                .py(px(6.0))
                .border_t_1()
                .border_color(gpui::white().opacity(0.1))
                .text_xs()
                .text_color(muted)
                .child("◷")
                .child(age)
                .when_some(session_id, |d, id| {
                    d.child("•").child(
                        div()
                            .min_w_0()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .font_family(mono)
                            .child(id),
                    )
                })
                .child(div().flex_1())
                .when(bookmarks > 0, |d| {
                    d.child("🔖︎").child(bookmarks.to_string())
                })
        });

        // Center on the tab, kept 12 pt inside the window.
        let window_width = self.screen_bounds.size.width;
        let ideal = hover.anchor_x - px(CARD_WIDTH / 2.0);
        let max_x = (window_width - px(CARD_WIDTH + 12.0)).max(px(12.0));
        let x = ideal.clamp(px(12.0), max_x);
        let bar_bottom = self
            .frames
            .borrow()
            .bar
            .map(|b| b.bottom())
            .unwrap_or(px(38.0));
        let anchor = point(x, bar_bottom + px(8.0));
        Some(
            deferred(
                anchored().position(anchor).snap_to_window().child(
                    div()
                        .id("hover-card")
                        .occlude()
                        .w(px(CARD_WIDTH))
                        .rounded(px(10.0))
                        .bg(gpui::Rgba {
                            r: 0.10,
                            g: 0.10,
                            b: 0.10,
                            a: 1.0,
                        })
                        .shadow_lg()
                        .text_color(gpui::hsla(0.0, 0.0, 0.92, 1.0))
                        .flex()
                        .flex_col()
                        .child(header)
                        .child(div().h(px(1.0)).bg(gpui::white().opacity(0.1)))
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .gap_2()
                                .px_3()
                                .py(px(10.0))
                                .children(rows),
                        )
                        .children(footer)
                        .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                            this.hover_card_hovered(*hovered, cx)
                        }))
                        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation()),
                ),
            )
            .with_priority(3)
            .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::should_show_render_suspension_row;

    #[test]
    fn suspension_row_shows_live_or_pre_prewarm_state() {
        assert!(should_show_render_suspension_row(
            true, false, false, false, true
        ));
        assert!(should_show_render_suspension_row(
            true, false, false, true, false
        ));
    }

    #[test]
    fn suspension_row_hides_when_setting_is_disabled() {
        assert!(!should_show_render_suspension_row(
            false, false, false, true, true
        ));
    }

    #[test]
    fn suspension_row_hides_for_selected_tab() {
        assert!(!should_show_render_suspension_row(
            true, true, false, true, true
        ));
    }

    #[test]
    fn suspension_row_hides_for_visible_surface() {
        assert!(!should_show_render_suspension_row(
            true, false, true, true, true
        ));
    }

    #[test]
    fn suspension_row_hides_when_neither_state_is_suspended() {
        assert!(!should_show_render_suspension_row(
            true, false, false, false, false
        ));
    }
}

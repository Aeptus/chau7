//! Tab bar rendering (`ToolbarTabBarView`, `UnifiedTabButton`,
//! `TabSessionContent`, `RepoGroupBracket`, `IdleTabsChip` in Swift): tabs,
//! repo groups, the idle chip and its popover, the git branch capsule, and
//! scrolling the selected tab into view. The hover card is in `hover_card.rs`.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use chau7_next_core::tab_bar_layout::TabBarLayoutItem;
use chau7_next_core::tab_bar_text::{command_badge, idle_duration, truncate_middle};
use chau7_next_core::tabs_state::{TabColor, repo_group_color, repo_group_name};
use gpui::{
    Animation, AnimationExt, App, Bounds, Context, Hsla, Image, ImageFormat, MouseButton,
    MouseDownEvent, PathBuilder, Pixels, Role, ScrollHandle, SharedString, Window, anchored,
    bounce, canvas, deferred, div, ease_in_out, img, point, prelude::*, px,
};

use super::{AppData, Workspace};
use crate::platform::process as procinfo;
use crate::settings::Settings;
use crate::tab_bar::{BorderStyle, DragSubject, TAB_SPACING, TabId, style_color};
use crate::theme::{Chrome, tab_color};

/// Height of a tab chip (`OverlayLayout.tabChipHeight`).
pub(super) const TAB_CHIP_HEIGHT: f32 = 24.0;

/// Scroll animation of the tab row (selected tab centered, 0.25 s ease).
pub(super) struct TabScroll {
    pub(super) handle: ScrollHandle,
    /// Tab to bring into view once its frame is known.
    pending: Option<TabId>,
    anim: Option<(f32, f32, Instant)>,
}

impl Default for TabScroll {
    fn default() -> Self {
        Self {
            handle: ScrollHandle::new(),
            pending: None,
            anim: None,
        }
    }
}

/// What a tab shows of its focused session.
#[derive(Default)]
pub(super) struct TabSessionInfo {
    pub(super) ai_app: Option<String>,
    pub(super) ai_running: bool,
    pub(super) in_git_repo: bool,
    pub(super) git_branch: Option<String>,
    /// The tab runs a Vite dev server (yellow bolt icon).
    pub(super) vite: bool,
}

/// AI product logos (`AIAgentLogo`, `Resources/*-logo.png`), by agent name.
pub(super) fn ai_logo(app_name: &str) -> Option<Arc<Image>> {
    static LOGOS: OnceLock<HashMap<&'static str, Arc<Image>>> = OnceLock::new();
    let logos = LOGOS.get_or_init(|| {
        let png = |bytes: &[u8]| Arc::new(Image::from_bytes(ImageFormat::Png, bytes.to_vec()));
        HashMap::from([
            (
                "claude",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/claude-logo.png"
                )),
            ),
            (
                "gemini",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/gemini-logo.png"
                )),
            ),
            (
                "codex",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/codex-logo.png"
                )),
            ),
            (
                "chatgpt",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/chatgpt-logo.png"
                )),
            ),
            (
                "copilot",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/copilot-logo.png"
                )),
            ),
            (
                "aider",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/aider-logo.png"
                )),
            ),
            (
                "cursor",
                png(include_bytes!(
                    "../../../../../chau7-macos/Sources/Chau7/Resources/cursor-logo.png"
                )),
            ),
        ])
    });
    logos.get(app_name.to_lowercase().as_str()).cloned()
}

/// Rounded rectangle outline, solid or dashed (`notificationBorderOverlay`).
pub(super) fn paint_border(
    bounds: Bounds<Pixels>,
    radius: f32,
    width: f32,
    style: BorderStyle,
    color: Hsla,
    window: &mut Window,
) {
    let inset = width / 2.0;
    let x0 = f32::from(bounds.left()) + inset;
    let y0 = f32::from(bounds.top()) + inset;
    let x1 = f32::from(bounds.right()) - inset;
    let y1 = f32::from(bounds.bottom()) - inset;
    let r = radius.min((x1 - x0) / 2.0).min((y1 - y0) / 2.0).max(0.0);
    let p = |x: f32, y: f32| point(px(x), px(y));
    let mut builder = PathBuilder::stroke(px(width));
    if !style.dash().is_empty() {
        let dash: Vec<Pixels> = style.dash().iter().map(|d| px(*d)).collect();
        builder = builder.dash_array(&dash);
    }
    let radii = p(r, r);
    builder.move_to(p(x0 + r, y0));
    builder.line_to(p(x1 - r, y0));
    builder.arc_to(radii, px(0.0), false, true, p(x1, y0 + r));
    builder.line_to(p(x1, y1 - r));
    builder.arc_to(radii, px(0.0), false, true, p(x1 - r, y1));
    builder.line_to(p(x0 + r, y1));
    builder.arc_to(radii, px(0.0), false, true, p(x0, y1 - r));
    builder.line_to(p(x0, y0 + r));
    builder.arc_to(radii, px(0.0), false, true, p(x0 + r, y0));
    builder.close();
    if let Ok(path) = builder.build() {
        window.paint_path(path, color);
    }
}

impl Workspace {
    pub(super) fn session_info(&self, id: TabId, cx: &App) -> Option<TabSessionInfo> {
        let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        Some(TabSessionInfo {
            ai_app: session.ai_display_app_name(),
            // Live process observation is separate from persisted resume identity.
            ai_running: session.is_ai_running(),
            in_git_repo: session.git_root.is_some(),
            git_branch: session.git_branch.clone(),
            vite: session
                .dev_server()
                .is_some_and(|d| d.name.eq_ignore_ascii_case("Vite")),
        })
    }

    /// Secondary label as `tabPathDisplayName`: the git root's name, else the
    /// `~`-abbreviated directory.
    pub(super) fn tab_path(&self, id: TabId, cx: &App) -> Option<String> {
        let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        if let Some(root) = &session.git_root {
            return root.file_name().map(|n| n.to_string_lossy().to_string());
        }
        let home = cx.global::<AppData>().root.home().to_path_buf();
        session
            .cwd
            .as_ref()
            .map(|cwd| procinfo::display_path(cwd, &home))
    }

    /// `OverlayTab.commandBadge`: "✓ 1.2s", "✗ 340ms", "..." while running;
    /// `None` when the badge setting is off.
    pub(super) fn command_badge(&self, id: TabId, cx: &App) -> Option<(String, bool)> {
        if !Settings::get(cx).tabs.last_command_badge {
            return None;
        }
        let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
        let session = session.read(cx);
        let last = session.last_command?;
        let running = session.command_running;
        let text = command_badge(
            (!running).then_some(last.exit_code),
            last.duration.as_secs_f64(),
        );
        Some((text, running || last.exit_code == 0))
    }

    /// The tab's color as shown (`effectiveColor`).
    pub(super) fn effective_color(&self, id: TabId, cx: &App) -> TabColor {
        let auto = Settings::get(cx).tabs.auto_tab_theme;
        self.state
            .get(id)
            .map(|t| t.effective_color(auto))
            .unwrap_or(TabColor::Blue)
    }

    /// Width of the tab row inside the title bar: the window minus the
    /// title bar's left padding (traffic lights on macOS) and, elsewhere, the
    /// three window buttons.
    fn tab_bar_width(&self) -> Pixels {
        let reserved = if cfg!(target_os = "macos") {
            80.0
        } else {
            12.0 + 3.0 * 34.0
        };
        (self.screen_bounds.size.width - px(reserved)).max(px(120.0))
    }

    /// The tabs show unless the window has a single tab and either "Always
    /// Show Tab Bar" is off or minimal mode hides the tab bar.
    pub(super) fn tab_bar_visible(&self, cx: &App) -> bool {
        if self.state.len() > 1 {
            return true;
        }
        let settings = Settings::get(cx);
        let minimal = &settings.minimal_mode;
        settings.tabs.always_show_tab_bar && !(minimal.enabled && minimal.hide_tab_bar)
    }

    /// Minimal mode with "Hide Title Bar" removes the title bar row while
    /// the tabs are hidden.
    pub(super) fn title_bar_visible(&self, cx: &App) -> bool {
        let minimal = &Settings::get(cx).minimal_mode;
        self.tab_bar_visible(cx) || !(minimal.enabled && minimal.hide_title_bar)
    }

    // ----- scrolling ----------------------------------------------------

    /// Center the selected tab in the bar (`proxy.scrollTo(.center)`), on the
    /// next frame once its frame is known.
    pub(super) fn scroll_to_selected(&mut self) {
        self.scroll.pending = self.state.selected();
    }

    /// Advance the scroll animation; true while it runs.
    pub(super) fn tick_scroll(&mut self) -> bool {
        if let Some(id) = self.scroll.pending.take() {
            let frames = self.frames.borrow();
            match (frames.tabs.get(&id), frames.bar) {
                (Some(tab), Some(bar)) => {
                    let current = f32::from(self.scroll.handle.offset().x);
                    let max = f32::from(self.scroll.handle.max_offset().x);
                    let delta = f32::from(tab.center().x - bar.center().x);
                    let target = (current - delta).clamp(-max, 0.0);
                    if (target - current).abs() > 0.5 {
                        self.scroll.anim = Some((current, target, Instant::now()));
                    }
                }
                _ => {
                    // Not laid out yet (new tab): try again next frame.
                    drop(frames);
                    self.scroll.pending = Some(id);
                    return true;
                }
            }
        }
        let Some((from, to, start)) = self.scroll.anim else {
            return false;
        };
        let reduce_motion = crate::platform::system::reduce_motion();
        let t = if reduce_motion {
            1.0
        } else {
            (start.elapsed().as_secs_f32() / 0.25).min(1.0)
        };
        let x = from + (to - from) * ease_in_out(t);
        let y = self.scroll.handle.offset().y;
        self.scroll.handle.set_offset(point(px(x), y));
        if t >= 1.0 {
            self.scroll.anim = None;
            return false;
        }
        true
    }

    // ----- tab chip -----------------------------------------------------

    pub(super) fn render_tab(
        &self,
        id: TabId,
        in_group: bool,
        group_color: Option<Hsla>,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let Some(meta) = self.state.get(id) else {
            return div().into_any_element();
        };
        let tabs = &Settings::get(cx).tabs;
        let selected = self.state.selected() == Some(id);
        let title: SharedString = self.tab_title(id, cx).into();
        let info = self.session_info(id, cx).unwrap_or_default();
        // `isMinimalDisplay`: custom title only.
        let minimal = tabs.custom_title_only
            && meta
                .custom_title
                .as_ref()
                .is_some_and(|t| !t.trim().is_empty());
        let raw_path = self.tab_path(id, cx).filter(|p| !p.is_empty());
        let path = (!minimal && !in_group && tabs.show_path)
            .then(|| raw_path.clone())
            .flatten();
        let badge = (!minimal).then(|| self.command_badge(id, cx)).flatten();
        let token_rate = (!minimal && info.ai_running)
            .then(|| {
                let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
                let reading = crate::telemetry::token_rate(&session.read(cx).tab_identifier, cx)?;
                // A finished response's old speed must not look like current output.
                ((0..=15).contains(
                    &chrono::Utc::now()
                        .signed_duration_since(reading.updated_at)
                        .num_seconds(),
                ))
                .then_some(reading)
            })
            .flatten();
        let broadcast_included = self.broadcast && !self.broadcast_excluded.contains(&id);
        let show_broadcast = !minimal && tabs.show_broadcast_indicator && broadcast_included;
        let branch = (!minimal && tabs.show_git_indicator && info.in_git_repo).then_some(matches!(
            info.git_branch.as_deref(),
            None | Some("main") | Some("master")
        ));
        // `mcpShowTabIndicator`: the purple look of MCP-controlled tabs.
        let mcp_look = meta.mcp_controlled && Settings::get(cx).mcp.show_tab_indicator;
        let mcp = !minimal && mcp_look;
        let notification = self
            .entries
            .get(&id)
            .and_then(|e| e.notification.clone())
            .unwrap_or_default();
        let color = tab_color(self.effective_color(id, cx));
        let dragging_this = self
            .drag
            .as_ref()
            .is_some_and(|d| d.active && d.subject == DragSubject::Tab(id));
        let offset = if dragging_this {
            self.drag.as_ref().map(|d| d.translation()).unwrap_or(0.0)
        } else {
            self.anims.offset(id)
        };
        let frames = self.frames.clone();
        let text_primary = chrome.text;
        let title_color = notification
            .title_color
            .map(|c| style_color(c, text_primary))
            .unwrap_or(text_primary);

        // Leading icon: notification icon, else the AI logo (dim when the
        // tool is not running) when tab icons are on.
        let icon: Option<gpui::AnyElement> = if minimal {
            None
        } else if let Some(glyph) = notification.icon {
            let icon_color = notification
                .icon_color
                .or(notification.title_color)
                .map(|c| style_color(c, text_primary))
                .unwrap_or(text_primary);
            Some(
                div()
                    .flex_shrink_0()
                    .text_color(icon_color)
                    .child(glyph)
                    .into_any_element(),
            )
        } else if tabs.show_icons {
            info.ai_app
                .as_deref()
                .and_then(ai_logo)
                .map(|logo| {
                    img(logo)
                        .flex_shrink_0()
                        .size(px(14.0))
                        .opacity(if info.ai_running { 1.0 } else { 0.35 })
                        .into_any_element()
                })
                .or_else(|| {
                    // A Vite dev server shows a yellow bolt (`TabSessionContent`).
                    info.vite.then(|| {
                        div()
                            .flex_shrink_0()
                            .text_color(style_color(
                                crate::tab_bar::StyleColor::Yellow,
                                text_primary,
                            ))
                            .child("⚡")
                            .into_any_element()
                    })
                })
        } else {
            None
        };

        // The title keeps its room; the path shrinks first.
        let title_el = div()
            .flex_shrink(0.2)
            .min_w(px(24.0))
            .overflow_hidden()
            .whitespace_nowrap()
            .text_ellipsis()
            .text_color(title_color)
            .font_weight(if notification.bold {
                gpui::FontWeight::BOLD
            } else {
                gpui::FontWeight::SEMIBOLD
            })
            .when(notification.italic, |d| d.italic())
            .child(title.clone());

        // UnifiedTabButton: tab color at 25% when selected, purple for MCP
        // tabs, dark 18% otherwise.
        let background = if selected {
            color.opacity(0.25)
        } else if mcp_look {
            style_color(crate::tab_bar::StyleColor::Purple, text_primary).opacity(0.15)
        } else if chrome.is_dark {
            gpui::hsla(0.0, 0.0, 0.0, 0.18)
        } else {
            gpui::hsla(0.0, 0.0, 0.0, 0.06)
        };
        let border = (notification.border_width > 0.0).then(|| {
            (
                notification.border_width,
                notification.border_style,
                notification
                    .border_color
                    .map(|c| style_color(c, text_primary))
                    .unwrap_or(chrome.border),
            )
        });
        let accessibility_label = match &raw_path {
            Some(path) => format!("{title} tab, {path}"),
            None => format!("{title} tab"),
        };

        let chip = div()
            .id(("tab", id as usize))
            .role(Role::Tab)
            .aria_label(accessibility_label)
            .aria_description(if selected {
                "Selected. Double-tap to rename"
            } else {
                "Double-tap to select, then double-tap to rename"
            })
            .aria_selected(selected)
            .relative()
            .left(px(offset))
            .when(dragging_this, |d| d.opacity(0.92).shadow_md())
            .flex_shrink_0()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .h(px(TAB_CHIP_HEIGHT))
            .max_w(px(280.0))
            .px(px(10.0))
            .rounded(px(8.0))
            .text_xs()
            .bg(background)
            .when_some(icon, |d, icon| d.child(icon))
            .child(title_el)
            .when_some(path, |d, path| {
                d.child(
                    div()
                        .flex_shrink(1.0)
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .text_color(chrome.text_muted)
                        .child(format!("- {}", truncate_middle(&path, 28))),
                )
            })
            .when(mcp, |d| {
                d.child(
                    div()
                        .id(("mcp", id as usize))
                        .flex_shrink_0()
                        .text_color(style_color(
                            crate::tab_bar::StyleColor::Purple,
                            text_primary,
                        ))
                        .child("◌")
                        .tooltip(|window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(crate::l10n::tr(
                                "MCP-controlled tab",
                            ))
                            .build(window, cx)
                        }),
                )
            })
            .when_some(badge, |d, (badge, ok)| {
                d.child(
                    div()
                        .flex_shrink_0()
                        .px_1()
                        .rounded_full()
                        .bg(gpui::hsla(0.0, 0.0, 0.0, 0.2))
                        .text_color(if ok {
                            style_color(crate::tab_bar::StyleColor::Green, text_primary)
                        } else {
                            chrome.danger
                        })
                        .child(badge),
                )
            })
            .when_some(token_rate, |d, reading| {
                let detail = reading.detail();
                d.child(
                    div()
                        .id(("token-rate", id as usize))
                        .flex_shrink_0()
                        .px_1()
                        .rounded_full()
                        .text_color(chrome.accent)
                        .child(reading.formatted())
                        .tooltip(move |window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(detail.clone())
                                .build(window, cx)
                        }),
                )
            })
            .when(show_broadcast, |d| {
                d.child(
                    div()
                        .flex_shrink_0()
                        .text_color(style_color(
                            crate::tab_bar::StyleColor::Orange,
                            text_primary,
                        ))
                        .child("⦿"),
                )
            })
            .when_some(branch, |d, on_main| {
                // BranchIndicator: dim on main/master, bright on a branch.
                d.child(
                    div()
                        .flex_shrink_0()
                        .text_color(text_primary.opacity(if on_main { 0.25 } else { 0.9 }))
                        .child("⑂"),
                )
            })
            .child(
                div()
                    .id(("close", id as usize))
                    .role(Role::Button)
                    .aria_label("Close tab")
                    .flex_shrink_0()
                    .size(px(14.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_sm()
                    .text_color(chrome.text_muted)
                    .hover(|d| d.bg(chrome.tab_hover_bg).text_color(chrome.text))
                    .child("×")
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.request_close_tab(id, window, cx);
                    })),
            )
            // Record layout for drag slot math and cross-window drops, and
            // draw the notification border and the repo group top line.
            .child(
                canvas(
                    move |bounds, _, _| {
                        frames.borrow_mut().tabs.insert(id, bounds);
                        bounds
                    },
                    move |_, bounds, window, _| {
                        if let Some((width, style, color)) = border {
                            paint_border(bounds, 8.0, width, style, color, window);
                        }
                        if let Some(group_color) = group_color {
                            let top = Bounds::new(
                                bounds.origin - point(px(TAB_SPACING / 2.0), px(3.0)),
                                gpui::size(bounds.size.width + px(TAB_SPACING), px(1.0)),
                            );
                            window.paint_quad(gpui::fill(top, group_color.opacity(0.5)));
                        }
                    },
                )
                .absolute()
                .size_full(),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    // Keep the title bar from starting a window move.
                    cx.stop_propagation();
                    if event.modifiers.control && cfg!(target_os = "macos") {
                        this.show_tab_menu(id, event.position, window, cx);
                        return;
                    }
                    if event.click_count == 2 {
                        this.begin_rename(id, window, cx);
                        return;
                    }
                    log::info!("TABBAR select tab={id}");
                    this.select_tab(id, window, cx);
                    this.begin_press(DragSubject::Tab(id), event.position, cx);
                }),
            )
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.show_tab_menu(id, event.position, window, cx);
                }),
            )
            .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                this.hover_tab(id, *hovered, None, cx)
            }));

        if notification.pulse {
            // Whole chip fades 1.0 to 0.6, 0.8 s ease-in-out, back and forth.
            chip.with_animation(
                ("pulse", id as usize),
                Animation::new(Duration::from_millis(1600))
                    .repeat()
                    .with_easing(bounce(ease_in_out)),
                |el, t| el.opacity(1.0 - 0.4 * t),
            )
            .into_any_element()
        } else {
            chip.into_any_element()
        }
    }

    // ----- bar ----------------------------------------------------------

    pub(super) fn render_tab_bar(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let now = AppData::now(cx);
        let items = self.state.display_items(now);
        let idle_count = self.state.idle_ids(now).len();
        let mut row = div()
            .id("tab-bar")
            .flex()
            .flex_row()
            .items_center()
            .gap(px(TAB_SPACING))
            .h_full()
            .flex_1()
            .min_w_0()
            .overflow_x_scroll()
            .track_scroll(&self.scroll.handle)
            .pr_2();
        let mut index = 0;
        while index < items.len() {
            match &items[index] {
                TabBarLayoutItem::IdleTabs => {
                    row = row.child(self.render_idle_chip(idle_count, chrome, cx));
                    index += 1;
                }
                TabBarLayoutItem::RepoGroupTag { repo_group_id, .. } => {
                    let group = repo_group_id.clone();
                    let mut members = Vec::new();
                    index += 1;
                    while let Some(TabBarLayoutItem::Tab(id)) = items.get(index) {
                        if self.state.get(*id).and_then(|t| t.repo_group_id.as_deref())
                            != Some(group.as_str())
                        {
                            break;
                        }
                        members.push(*id);
                        index += 1;
                    }
                    row = row.child(self.render_group(group, members, chrome, cx));
                }
                TabBarLayoutItem::Tab(id) => {
                    row = row.child(self.render_tab(*id, false, None, chrome, cx));
                    index += 1;
                }
                TabBarLayoutItem::NewTabButton => {
                    row = row.child(
                        div()
                            .id("new-tab")
                            .role(Role::Button)
                            .aria_label("New tab")
                            .aria_description("Opens a new terminal tab")
                            .flex_shrink_0()
                            .h(px(TAB_CHIP_HEIGHT))
                            .px(px(10.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(8.0))
                            .bg(if chrome.is_dark {
                                gpui::hsla(0.0, 0.0, 0.0, 0.18)
                            } else {
                                gpui::hsla(0.0, 0.0, 0.0, 0.06)
                            })
                            .text_color(chrome.text_muted)
                            .hover(|d| d.bg(chrome.tab_hover_bg).text_color(chrome.text))
                            .child("+")
                            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.add_default_tab(window, cx);
                                this.focus_selected(window, cx);
                            })),
                    );
                    index += 1;
                }
            }
        }
        let frames = self.frames.clone();
        let row = row.child(
            canvas(
                move |bounds, _, _| {
                    frames.borrow_mut().bar = Some(bounds);
                },
                |_, _, _, _| {},
            )
            .absolute()
            .size_full(),
        );
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .h_full()
            // The title bar lets its content grow past the window; give the
            // row the room left by the traffic lights or window controls so
            // tabs scroll and the git capsule stays at the right end.
            .w(self.tab_bar_width())
            .child(row)
            .children(self.render_dev_server_capsule(chrome, cx))
            .children(self.render_git_capsule(chrome, cx))
            .children(crate::remote::viewer_ui::title_bar_button(chrome, cx))
            .into_any_element()
    }

    /// `GitBranchBadge`: branch of the selected tab at the right end of the
    /// bar ("Git" when the branch name is empty, "unknown" when not known).
    fn render_git_capsule(&self, chrome: Chrome, cx: &App) -> Option<gpui::AnyElement> {
        let id = self.state.selected()?;
        let info = self.session_info(id, cx)?;
        if !info.in_git_repo {
            return None;
        }
        let name = match info.git_branch.as_deref() {
            None => "unknown".to_string(),
            Some("") => "Git".to_string(),
            Some(branch) => branch.to_string(),
        };
        Some(
            div()
                .id("git-capsule")
                .role(Role::Label)
                .aria_label(format!("Git branch: {name}"))
                .flex_shrink_0()
                .flex()
                .items_center()
                .gap(px(6.0))
                .px(px(10.0))
                .py(px(4.0))
                .mr_2()
                .rounded_full()
                .bg(gpui::hsla(0.0, 0.0, 0.0, 0.20))
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(chrome.text)
                .child("⑂")
                .child(name)
                .into_any_element(),
        )
    }

    /// Repo group: the repo tag in the group's hashed color with a bracket on
    /// its left, then the group's tabs with a continuous top line.
    pub(super) fn render_group(
        &self,
        group: String,
        members: Vec<TabId>,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let name: SharedString = repo_group_name(&group).to_string().into();
        let group_color = tab_color(repo_group_color(&group));
        let dragging = self
            .drag
            .as_ref()
            .is_some_and(|d| d.active && d.subject == DragSubject::Group(group.clone()));
        let offset = if dragging {
            self.drag.as_ref().map(|d| d.translation()).unwrap_or(0.0)
        } else {
            members
                .first()
                .map(|id| self.anims.offset(*id))
                .unwrap_or(0.0)
        };
        let frames = self.frames.clone();
        let group_for_frames = group.clone();
        let group_for_press = group.clone();
        let group_for_menu = group.clone();
        let tabs: Vec<_> = members
            .iter()
            .map(|id| self.render_tab(*id, true, Some(group_color), chrome, cx))
            .collect();
        div()
            .id(SharedString::from(format!("group-{group}")))
            .relative()
            .left(px(offset))
            .when(dragging, |d| d.opacity(0.5))
            .flex_shrink_0()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(TAB_SPACING))
            // RepoGroupBracket: the tag, with a bracket on its left.
            .child(
                div()
                    .id(SharedString::from(format!("group-tag-{group}")))
                    .role(Role::Label)
                    .aria_label(format!("Repository group {name}"))
                    .flex_shrink_0()
                    .px(px(4.0))
                    .h(px(TAB_CHIP_HEIGHT))
                    .flex()
                    .items_center()
                    .text_xs()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(group_color)
                    .cursor_grab()
                    .child(name)
                    .child(
                        canvas(
                            |_, _, _| {},
                            move |bounds, _, window, _| {
                                paint_bracket(bounds, group_color.opacity(0.5), window)
                            },
                        )
                        .absolute()
                        .size_full(),
                    )
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                            cx.stop_propagation();
                            this.begin_press(
                                DragSubject::Group(group_for_press.clone()),
                                event.position,
                                cx,
                            );
                        }),
                    )
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                            cx.stop_propagation();
                            this.show_group_menu(
                                group_for_menu.clone(),
                                event.position,
                                window,
                                cx,
                            );
                        }),
                    ),
            )
            .children(tabs)
            .child(
                canvas(
                    move |bounds, _, _| {
                        frames.borrow_mut().groups.insert(group_for_frames, bounds);
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size_full(),
            )
            .into_any_element()
    }

    // ----- idle tabs ----------------------------------------------------

    /// `IdleTabsChip`: tray icon and count, brighter while open.
    pub(super) fn render_idle_chip(
        &self,
        count: usize,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let open = self.idle_open;
        let frames = self.frames.clone();
        let tooltip: SharedString = format!("Idle tabs ({count})").into();
        div()
            .id("idle-chip")
            .role(Role::Button)
            .aria_label(tooltip.clone())
            .aria_expanded(open)
            .flex_shrink_0()
            .px(px(10.0))
            .h(px(TAB_CHIP_HEIGHT))
            .flex()
            .items_center()
            .gap_1()
            .rounded(px(8.0))
            .text_xs()
            .text_color(chrome.text)
            .bg(gpui::white().opacity(if open { 0.15 } else { 0.08 }))
            .child("📥︎")
            .child(count.to_string())
            .tooltip(move |window, cx| {
                gpui_kit::component::tooltip::Tooltip::new(tooltip.clone()).build(window, cx)
            })
            .child(
                canvas(
                    move |bounds, _, _| {
                        frames.borrow_mut().idle_chip = Some(bounds);
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size_full(),
            )
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(cx.listener(|this, _, _, cx| {
                this.idle_open = !this.idle_open;
                cx.notify();
            }))
            .into_any_element()
    }

    /// Idle tabs popover: moon, title, idle duration; hover shows the tab's
    /// hover card; click selects; "Close All Idle" at the bottom.
    pub(super) fn render_idle_popover(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        if !self.idle_open {
            return None;
        }
        let now = AppData::now(cx);
        let idle = self.state.idle_ids(now);
        let ids: Vec<TabId> = self
            .state
            .tabs()
            .iter()
            .map(|t| t.id)
            .filter(|id| idle.contains(id))
            .collect();
        let anchor = {
            let frames = self.frames.borrow();
            frames
                .idle_chip
                .or(frames.bar)
                .map(|b| point(b.left(), b.bottom() + px(4.0)))
                .unwrap_or_default()
        };
        let card_anchor = anchor.x + px(40.0);
        let mut rows: Vec<gpui::AnyElement> = Vec::new();
        for (index, id) in ids.iter().copied().enumerate() {
            if index > 0 {
                rows.push(div().h(px(1.0)).bg(chrome.border).into_any_element());
            }
            // Swift: custom title, else the running app, else "Tab".
            let title = self
                .state
                .get(id)
                .and_then(|t| t.custom_title.clone())
                .or_else(|| self.session_info(id, cx).and_then(|i| i.ai_app))
                .unwrap_or_else(|| "Tab".into());
            let idle_for = self
                .state
                .get(id)
                .map(|t| idle_duration(now - t.last_activity))
                .unwrap_or_default();
            rows.push(
                div()
                    .id(("idle-row", id as usize))
                    .role(Role::Button)
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .px(px(10.0))
                    .py(px(6.0))
                    .rounded_md()
                    .hover(|d| d.bg(chrome.tab_hover_bg))
                    .child(div().text_xs().text_color(chrome.text_muted).child("☾"))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .text_sm()
                            .child(title),
                    )
                    .child(
                        div()
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .child(idle_for),
                    )
                    .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                        this.hover_tab(id, *hovered, Some(card_anchor), cx)
                    }))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.dismiss_hover_card(cx);
                        this.idle_open = false;
                        this.select_tab(id, window, cx);
                    }))
                    .into_any_element(),
            );
        }
        rows.push(div().h(px(1.0)).bg(chrome.border).into_any_element());
        rows.push(
            div()
                .id("idle-close-all")
                .role(Role::Button)
                .flex()
                .items_center()
                .gap(px(6.0))
                .px(px(10.0))
                .py(px(6.0))
                .rounded_md()
                .text_xs()
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child("⊗")
                .child(crate::l10n::tr("Close All Idle"))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.dismiss_hover_card(cx);
                    this.idle_open = false;
                    let ids = ids.clone();
                    this.close_tabs_confirming(ids, window, cx);
                    cx.notify();
                }))
                .into_any_element(),
        );
        Some(
            deferred(
                anchored().position(anchor).snap_to_window().child(
                    div()
                        .id("idle-popover")
                        .occlude()
                        .w(px(240.0))
                        .p_1()
                        .rounded_lg()
                        .border_1()
                        .border_color(chrome.border)
                        .bg(chrome.panel_bg)
                        .text_color(chrome.text)
                        .shadow_lg()
                        .children(rows)
                        .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                            this.idle_open = false;
                            cx.notify();
                        })),
                ),
            )
            .with_priority(2)
            .into_any_element(),
        )
    }
}

/// `RepoGroupBracket`: top, left (rounded corners) and bottom edges.
fn paint_bracket(bounds: Bounds<Pixels>, color: Hsla, window: &mut Window) {
    let r = 4.0;
    let inset = 0.5;
    let x0 = f32::from(bounds.left()) + inset;
    let x1 = f32::from(bounds.right());
    let y0 = f32::from(bounds.top()) + inset;
    let y1 = f32::from(bounds.bottom()) - inset;
    let p = |x: f32, y: f32| point(px(x), px(y));
    let radii = p(r - inset, r - inset);
    let mut builder = PathBuilder::stroke(px(1.0));
    builder.move_to(p(x1, y0));
    builder.line_to(p(x0 + r, y0));
    builder.arc_to(radii, px(0.0), false, false, p(x0, y0 + r));
    builder.line_to(p(x0, y1 - r));
    builder.arc_to(radii, px(0.0), false, false, p(x0 + r, y1));
    builder.line_to(p(x1, y1));
    if let Ok(path) = builder.build() {
        window.paint_path(path, color);
    }
}

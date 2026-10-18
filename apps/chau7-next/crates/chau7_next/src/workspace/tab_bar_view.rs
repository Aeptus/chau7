//! Tab bar rendering (`ToolbarTabBarView`, `UnifiedTabButton`,
//! `TabSessionContent`, `RepoGroupBracket`, `IdleTabsChip` in Swift): tabs,
//! repo groups, the idle chip and its popover, the git branch capsule, and
//! scrolling the selected tab into view. The hover card is in `hover_card.rs`.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use chau7_next_core::l10n::{self, Lang};
use chau7_next_core::tab_bar_layout::TabBarLayoutItem;
use chau7_next_core::tab_bar_text::{command_badge, idle_duration, truncate_middle};
use chau7_next_core::tabs_state::{TabColor, repo_group_color, repo_group_name};
use gpui::{
    AccessibleAction, Animation, AnimationExt, App, Bounds, Context, Hsla, Image, ImageFormat,
    MouseButton, MouseDownEvent, PathBuilder, Pixels, Role, ScrollHandle, SharedString, Window,
    anchored, bounce, canvas, deferred, div, ease_in_out, img, point, prelude::*, px,
};

use super::{AppData, Workspace};
use crate::platform::process as procinfo;
use crate::settings::Settings;
use crate::tab_bar::{BorderStyle, DragSubject, TAB_SPACING, TabId, style_color};
use crate::theme::{Chrome, tab_color};

pub(super) fn tab_accessibility_label(lang: Lang, title: &str, path: Option<&str>) -> String {
    let path_suffix = path
        .filter(|path| !path.is_empty())
        .map(|path| format!(", {path}"))
        .unwrap_or_default();
    l10n::localized_format(
        lang,
        "accessibility.tabWithPath",
        "%@ tab%@",
        &[title.into(), path_suffix.into()],
    )
}

pub(super) fn tab_accessibility_description(lang: Lang, selected: bool) -> String {
    if selected {
        l10n::localized(
            lang,
            "accessibility.tabRenameSelected",
            "Selected. Double-tap to rename",
        )
    } else {
        l10n::localized(
            lang,
            "accessibility.tabRename",
            "Double-tap to select, then double-tap to rename",
        )
    }
}

/// Height of a tab chip (`OverlayLayout.tabChipHeight`).
pub(super) const TAB_CHIP_HEIGHT: f32 = 24.0;

#[derive(Clone, Copy)]
pub(super) struct GroupTabLineEdges {
    is_first: bool,
    is_last: bool,
}

impl GroupTabLineEdges {
    fn bounds(self, tab: Bounds<Pixels>) -> Bounds<Pixels> {
        // The first tab reaches back across the full tag gap. Neighboring tabs
        // meet halfway across each gap, while the last tab ends at its edge.
        let leading = if self.is_first {
            TAB_SPACING
        } else {
            TAB_SPACING / 2.0
        };
        let trailing = if self.is_last { 0.0 } else { TAB_SPACING / 2.0 };
        Bounds::new(
            point(tab.origin.x - px(leading), tab.origin.y),
            gpui::size(tab.size.width + px(leading + trailing), px(1.0)),
        )
    }
}

/// Anchor frame measurements and decoration to the parent's border box. An
/// absolute child with automatic insets still uses flex alignment and padding
/// for its static position, even when its size is 100% of the parent.
fn tab_frame_overlay<T: gpui::Styled>(element: T) -> T {
    element.absolute().top_0().left_0().size_full()
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct BorderPathGeometry {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    radius: f32,
}

fn border_path_geometry(bounds: Bounds<Pixels>, radius: f32) -> BorderPathGeometry {
    let x0 = f32::from(bounds.left());
    let y0 = f32::from(bounds.top());
    let x1 = f32::from(bounds.right());
    let y1 = f32::from(bounds.bottom());
    BorderPathGeometry {
        x0,
        y0,
        x1,
        y1,
        radius: radius.min((x1 - x0) / 2.0).min((y1 - y0) / 2.0).max(0.0),
    }
}

fn tab_background_color(
    selected: bool,
    group_color: Option<Hsla>,
    effective_color: Hsla,
    mcp_look: bool,
    is_dark: bool,
    text_primary: Hsla,
) -> Hsla {
    if let Some(group_color) = group_color {
        // Match Swift's selected grouped-tab fill, and keep every grouped tab
        // visibly tied to its repository when it is not selected.
        group_color.opacity(if selected { 0.32 } else { 0.12 })
    } else if selected {
        // Preserve custom tab colors for selected tabs outside a repo group.
        effective_color.opacity(0.25)
    } else if mcp_look {
        style_color(crate::tab_bar::StyleColor::Purple, text_primary).opacity(0.15)
    } else if is_dark {
        gpui::hsla(0.0, 0.0, 0.0, 0.18)
    } else {
        gpui::hsla(0.0, 0.0, 0.0, 0.06)
    }
}

#[cfg(test)]
mod group_tab_line_tests {
    use super::*;

    fn tab_bounds(left: f32, top: f32, width: f32) -> Bounds<Pixels> {
        Bounds::new(
            point(px(left), px(top)),
            gpui::size(px(width), px(TAB_CHIP_HEIGHT)),
        )
    }

    #[test]
    fn group_line_starts_at_bracket_and_connects_across_tab_gaps() {
        let first = tab_bounds(100.0, 30.0, 60.0);
        let middle = tab_bounds(164.0, 30.0, 60.0);
        let last = tab_bounds(228.0, 30.0, 60.0);

        let first_line = GroupTabLineEdges {
            is_first: true,
            is_last: false,
        }
        .bounds(first);
        let middle_line = GroupTabLineEdges {
            is_first: false,
            is_last: false,
        }
        .bounds(middle);
        let last_line = GroupTabLineEdges {
            is_first: false,
            is_last: true,
        }
        .bounds(last);

        assert_eq!(first_line.origin.x, first.origin.x - px(TAB_SPACING));
        assert_eq!(first_line.origin.y, first.origin.y);
        assert_eq!(first_line.size.height, px(1.0));
        assert_eq!(
            first_line.origin.x + first_line.size.width,
            middle_line.origin.x
        );
        assert_eq!(
            middle_line.origin.x + middle_line.size.width,
            last_line.origin.x
        );
        assert_eq!(
            last_line.origin.x + last_line.size.width,
            last.origin.x + last.size.width
        );
    }

    #[test]
    fn single_tab_group_line_runs_from_bracket_to_tab_edge() {
        let tab = tab_bounds(100.0, 30.0, 60.0);
        let line = GroupTabLineEdges {
            is_first: true,
            is_last: true,
        }
        .bounds(tab);

        assert_eq!(line.origin.x, tab.origin.x - px(TAB_SPACING));
        assert_eq!(line.origin.y, tab.origin.y);
        assert_eq!(
            line.origin.x + line.size.width,
            tab.origin.x + tab.size.width
        );
    }

    #[gpui::test]
    fn frame_overlay_matches_padded_chip_layout(harness: &mut gpui::TestAppContext) {
        use gpui_kit::test::{TestSupportExt, TestWindowExt};
        use std::cell::Cell;
        use std::rc::Rc;

        const CASES: [(f32, f32, f32); 4] = [
            (10.0, 180.0, 0.0),
            (10.0, 103.5, -37.5),
            (4.0, 80.0, 29.0),
            (0.0, 280.0, 0.0),
        ];

        struct FrameOverlayFixture {
            captures: Vec<Rc<Cell<Option<Bounds<Pixels>>>>>,
            cases: [(f32, f32, f32); 4],
        }

        impl gpui::Render for FrameOverlayFixture {
            fn render(
                &mut self,
                _window: &mut Window,
                _cx: &mut Context<Self>,
            ) -> impl gpui::IntoElement {
                let rows = self
                    .cases
                    .into_iter()
                    .enumerate()
                    .map(|(index, (padding, width, offset))| {
                        let corrected_capture = self.captures[index * 2].clone();
                        let legacy_capture = self.captures[index * 2 + 1].clone();
                        let chip = |id: String, overlay: gpui::AnyElement| {
                            div()
                                .id(SharedString::from(id))
                                .relative()
                                .left(px(offset))
                                .flex()
                                .flex_row()
                                .items_center()
                                .w(px(width))
                                .h(px(TAB_CHIP_HEIGHT))
                                .px(px(padding))
                                .rounded(px(8.0))
                                .bg(gpui::black())
                                .child(div().size(px(14.0)))
                                .child(div().w(px(17.5)).h(px(14.0)))
                                .child(div().size(px(12.0)))
                                .child(overlay)
                                .test_support()
                        };
                        let corrected = canvas(
                            move |bounds, _, _| corrected_capture.set(Some(bounds)),
                            |_, _, _, _| {},
                        )
                        .map(tab_frame_overlay)
                        .into_any_element();
                        let legacy = canvas(
                            move |bounds, _, _| legacy_capture.set(Some(bounds)),
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full()
                        .into_any_element();

                        div()
                            .flex()
                            .flex_row()
                            .gap(px(12.0))
                            .child(chip(format!("fixed-chip-{index}"), corrected))
                            .child(chip(format!("legacy-chip-{index}"), legacy))
                    })
                    .collect::<Vec<_>>();

                div()
                    .size_full()
                    .flex()
                    .flex_col()
                    .items_start()
                    .gap(px(8.0))
                    .pl(px(13.5))
                    .pt(px(7.5))
                    .children(rows)
            }
        }

        harness.update(gpui_kit::init);
        let captures: Vec<_> = (0..CASES.len() * 2)
            .map(|_| Rc::new(Cell::new(None)))
            .collect();
        let handle: gpui::AnyWindowHandle = harness
            .add_window(|_, _| FrameOverlayFixture {
                captures: captures.clone(),
                cases: CASES,
            })
            .into();
        handle
            .update(harness, |_, window, cx| {
                for scale in [1.0, 2.0] {
                    window.set_scale_factor(scale);
                    window.render_frame(cx);
                    for (index, (padding, width, offset)) in CASES.iter().copied().enumerate() {
                        let context = format!(
                            "scale={scale}, padding={padding}, width={width}, offset={offset}"
                        );
                        let expected = window
                            .find(SharedString::from(format!("fixed-chip-{index}")))
                            .bounds();
                        let observed = captures[index * 2]
                            .get()
                            .expect("corrected canvas was prepainted");
                        assert_eq!(observed, expected, "corrected overlay: {context}");

                        let legacy_parent = window
                            .find(SharedString::from(format!("legacy-chip-{index}")))
                            .bounds();
                        let legacy = captures[index * 2 + 1]
                            .get()
                            .expect("legacy canvas was prepainted");
                        assert_eq!(legacy.size, legacy_parent.size, "legacy size: {context}");
                        assert_eq!(
                            legacy.origin.x,
                            legacy_parent.origin.x + px(padding),
                            "legacy x offset: {context}"
                        );
                        assert_eq!(
                            legacy.origin.y, legacy_parent.origin.y,
                            "legacy y: {context}"
                        );
                    }
                }
                window.remove_window();
            })
            .unwrap();
    }

    #[test]
    fn notification_border_centerline_matches_chip_bounds_and_corner_radius() {
        let bounds = tab_bounds(10.0, 20.0, 100.0);
        let geometry = border_path_geometry(bounds, 8.0);

        assert_eq!(geometry.x0, 10.0);
        assert_eq!(geometry.y0, 20.0);
        assert_eq!(geometry.x1, 110.0);
        assert_eq!(geometry.y1, 44.0);
        assert_eq!(geometry.radius, 8.0);
    }

    #[test]
    fn notification_border_corner_radius_stays_inside_small_chip_bounds() {
        let bounds = Bounds::new(point(px(10.0), px(20.0)), gpui::size(px(10.0), px(8.0)));
        let geometry = border_path_geometry(bounds, 8.0);

        assert_eq!(geometry.radius, 4.0);
    }

    #[test]
    fn grouped_tab_background_uses_repo_tint_for_selected_and_unselected_tabs() {
        let repo = gpui::hsla(0.61, 0.72, 0.48, 1.0);
        let custom = gpui::hsla(0.04, 0.86, 0.53, 1.0);
        let text = gpui::hsla(0.0, 0.0, 0.9, 1.0);

        let selected = tab_background_color(true, Some(repo), custom, false, true, text);
        let unselected = tab_background_color(false, Some(repo), custom, true, false, text);

        assert_eq!(selected.h, repo.h);
        assert_eq!(selected.a, 0.32);
        assert_eq!(unselected.h, repo.h);
        assert_eq!(unselected.a, 0.12);
    }

    #[test]
    fn ungrouped_selected_and_mcp_backgrounds_keep_their_existing_colors() {
        let custom = gpui::hsla(0.04, 0.86, 0.53, 1.0);
        let text = gpui::hsla(0.0, 0.0, 0.9, 1.0);

        let selected = tab_background_color(true, None, custom, false, true, text);
        let mcp = tab_background_color(false, None, custom, true, true, text);

        assert_eq!(selected.h, custom.h);
        assert_eq!(selected.a, 0.25);
        assert_eq!(
            mcp.h,
            style_color(crate::tab_bar::StyleColor::Purple, text).h
        );
        assert_eq!(mcp.a, 0.15);
    }

    #[test]
    fn idle_sections_group_by_full_repo_path_keep_tab_order_and_put_ungrouped_last() {
        let sections = group_idle_tabs_by_repo([
            (7, Some("/work/first/project".to_string())),
            (3, None),
            (9, Some("/archive/second/project".to_string())),
            (6, Some("/work/first/project".to_string())),
            (4, None),
        ]);

        assert_eq!(
            sections,
            vec![
                IdleTabSection {
                    repo_group_id: Some("/work/first/project".to_string()),
                    tab_ids: vec![7, 6],
                },
                IdleTabSection {
                    repo_group_id: Some("/archive/second/project".to_string()),
                    tab_ids: vec![9],
                },
                IdleTabSection {
                    repo_group_id: None,
                    tab_ids: vec![3, 4],
                },
            ]
        );
    }

    #[test]
    fn idle_repo_identity_prefers_group_then_falls_back_to_nonempty_git_root() {
        assert_eq!(
            idle_repo_identity(Some("/group/repo"), Some("/git/repo")),
            Some("/group/repo".to_string())
        );
        assert_eq!(
            idle_repo_identity(None, Some("/git/repo")),
            Some("/git/repo".to_string())
        );
        assert_eq!(
            idle_repo_identity(Some(""), Some("/git/repo")),
            Some("/git/repo".to_string())
        );
        assert_eq!(idle_repo_identity(Some(""), Some("")), None);
    }

    #[test]
    fn idle_sections_handle_empty_and_all_ungrouped_tabs() {
        assert!(group_idle_tabs_by_repo(std::iter::empty::<(TabId, Option<String>)>()).is_empty());
        assert_eq!(
            group_idle_tabs_by_repo([(5, None), (2, None)]),
            vec![IdleTabSection {
                repo_group_id: None,
                tab_ids: vec![5, 2],
            }]
        );
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IdleTabSection {
    repo_group_id: Option<String>,
    tab_ids: Vec<TabId>,
}

/// Bucket idle tabs by their full repository identity, preserving the order
/// of first-seen repositories and the original order of tabs in each bucket.
/// Tabs without a repository remain visible in a final section.
fn group_idle_tabs_by_repo(
    tabs: impl IntoIterator<Item = (TabId, Option<String>)>,
) -> Vec<IdleTabSection> {
    let mut sections: Vec<IdleTabSection> = Vec::new();
    let mut section_by_repo: HashMap<String, usize> = HashMap::new();
    let mut ungrouped = Vec::new();

    for (tab_id, repo_group_id) in tabs {
        let Some(repo_group_id) = repo_group_id else {
            ungrouped.push(tab_id);
            continue;
        };

        let section_index = match section_by_repo.get(&repo_group_id).copied() {
            Some(index) => index,
            None => {
                let index = sections.len();
                section_by_repo.insert(repo_group_id.clone(), index);
                sections.push(IdleTabSection {
                    repo_group_id: Some(repo_group_id),
                    tab_ids: Vec::new(),
                });
                index
            }
        };
        sections[section_index].tab_ids.push(tab_id);
    }

    if !ungrouped.is_empty() {
        sections.push(IdleTabSection {
            repo_group_id: None,
            tab_ids: ungrouped,
        });
    }

    sections
}

fn idle_repo_identity(repo_group_id: Option<&str>, git_root: Option<&str>) -> Option<String> {
    repo_group_id
        .filter(|path| !path.is_empty())
        .or_else(|| git_root.filter(|path| !path.is_empty()))
        .map(str::to_string)
}

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
    /// A live SSH destination below the tab's shell.
    pub(super) ssh_host: Option<String>,
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
            // Official OpenCode Mark, rasterized from its UI logo component.
            (
                "opencode",
                png(include_bytes!("../../assets/opencode-logo.png")),
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
    // Match Swift's RoundedRectangle(...).stroke(...): the path centerline is
    // on the chip edge. The chip keeps visible overflow so the outside half
    // of the stroke is not clipped.
    let geometry = border_path_geometry(bounds, radius);
    let BorderPathGeometry {
        x0,
        y0,
        x1,
        y1,
        radius: r,
    } = geometry;
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
        let tree = self.entries.get(&id)?.panes.read(cx);
        if let Some(saved) = tree.deferred_saved() {
            let pane = saved.focused_terminal();
            return Some(TabSessionInfo {
                ai_app: pane.and_then(|pane| {
                    chau7_next_core::shell_session::display_name_from_provider(
                        pane.ai_provider.as_deref(),
                    )
                }),
                ai_running: false,
                ssh_host: None,
                in_git_repo: self
                    .state
                    .get(id)
                    .is_some_and(|meta| meta.git_root.is_some())
                    || pane.is_some_and(|pane| pane.known_repo_root.is_some()),
                git_branch: pane.and_then(|pane| pane.known_git_branch.clone()),
                vite: false,
            });
        }
        let session = tree.focused_session(cx)?;
        let session = session.read(cx);
        Some(TabSessionInfo {
            ai_app: session.ai_display_app_name(),
            // Live process observation is separate from persisted resume identity.
            ai_running: session.is_ai_running(),
            ssh_host: session.ssh_host().map(str::to_owned),
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
        let tree = self.entries.get(&id)?.panes.read(cx);
        if let Some(saved) = tree.deferred_saved() {
            let pane = saved.focused_terminal();
            let root = self
                .state
                .get(id)
                .and_then(|meta| meta.git_root.as_deref())
                .or_else(|| pane.and_then(|pane| pane.known_repo_root.as_deref()));
            if let Some(root) = root {
                return std::path::Path::new(root)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned());
            }
            return tree
                .cwd(cx)
                .map(|cwd| procinfo::display_path(&cwd, cx.global::<AppData>().root.home()));
        }
        let session = tree.focused_session(cx)?;
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
        let token_rate = (!minimal)
            .then(|| {
                let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
                let session = session.read(cx);
                let reading = crate::telemetry::token_rate(&session.tab_identifier, cx)?;
                let current = session.is_ai_running()
                    && reading.is_current_for(
                        session.status(),
                        session.shell().agent_turn_started_at(),
                        &chrono::Utc::now(),
                    );
                let label = if current {
                    reading.formatted()
                } else {
                    format!("last {}", reading.formatted())
                };
                let detail = format!(
                    "{} {}. {}",
                    if current {
                        "Recent measurement."
                    } else {
                        "Last measured rate."
                    },
                    session.status().label(),
                    reading.detail()
                );
                Some((reading, label, detail))
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

        // Repo color remains visible on every grouped tab. Selected ungrouped
        // tabs continue to use their effective (including custom) color.
        let background = tab_background_color(
            selected,
            group_color,
            color,
            mcp_look,
            chrome.is_dark,
            text_primary,
        );
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
        let accessibility_language = l10n::current();
        let accessibility_label =
            tab_accessibility_label(accessibility_language, title.as_ref(), raw_path.as_deref());
        let accessibility_label = if let Some(host) = info.ssh_host.as_deref() {
            let host = truncate_middle(host, 128);
            format!("{accessibility_label}, SSH connection to {host}")
        } else {
            accessibility_label
        };
        let accessibility_description =
            tab_accessibility_description(accessibility_language, selected);

        let chip = div()
            .id(("tab", id as usize))
            .role(Role::Tab)
            .aria_label(accessibility_label)
            .aria_description(accessibility_description)
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
            .when_some(info.ssh_host.clone(), |d, host| {
                let accessible_host = truncate_middle(&host, 128);
                let tooltip = format!("SSH connection to {accessible_host}");
                d.child(
                    div()
                        .id(("ssh-host", id as usize))
                        .role(Role::Label)
                        .aria_label(format!("SSH host {accessible_host}"))
                        .flex_shrink(1.0)
                        .min_w(px(42.0))
                        .overflow_hidden()
                        .flex()
                        .items_center()
                        .gap(px(3.0))
                        .px_1()
                        .rounded_full()
                        .bg(chrome.accent.opacity(0.16))
                        .text_color(chrome.accent)
                        .child(
                            gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Server)
                                .size(px(12.0))
                                .flex_shrink_0(),
                        )
                        .child(
                            div()
                                .min_w_0()
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .text_ellipsis()
                                .child(format!("SSH {}", truncate_middle(&host, 18))),
                        )
                        .tooltip(move |window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(tooltip.clone())
                                .build(window, cx)
                        }),
                )
            })
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
                        .flex_shrink(1.0)
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
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
            .when_some(token_rate, |d, (reading, label, detail)| {
                d.child(
                    div()
                        .id(("token-rate", id as usize))
                        .role(Role::Label)
                        .aria_label(detail.clone())
                        .flex_shrink(1.0)
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .px_1()
                        .rounded_full()
                        .text_color(style_color(
                            if reading.source.estimated() {
                                crate::tab_bar::StyleColor::Orange
                            } else {
                                crate::tab_bar::StyleColor::Green
                            },
                            text_primary,
                        ))
                        .child(label)
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
            // draw the notification border. The group line is painted by the
            // group-level overlay so the gap segments stay outside tab clips.
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
                    },
                )
                .map(tab_frame_overlay),
            )
            .on_a11y_action(AccessibleAction::Click, {
                let workspace = cx.entity().downgrade();
                move |_, window, cx| {
                    workspace
                        .update(cx, |this, cx| this.select_tab(id, window, cx))
                        .ok();
                }
            })
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
            .map(tab_frame_overlay),
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
        let group_for_accessibility = group.clone();
        let tabs: Vec<_> = members
            .iter()
            .map(|id| self.render_tab(*id, true, Some(group_color), chrome, cx))
            .collect();
        let frames_for_paint = frames.clone();
        let member_ids_for_paint = members;
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
                    .role(Role::Button)
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
                        .map(tab_frame_overlay),
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
                    )
                    .on_a11y_action(AccessibleAction::Click, {
                        let workspace = cx.entity().downgrade();
                        move |_, window, cx| {
                            workspace
                                .update(cx, |this, cx| {
                                    this.toggle_dashboard(
                                        group_for_accessibility.clone(),
                                        window,
                                        cx,
                                    )
                                })
                                .ok();
                        }
                    }),
            )
            .children(tabs)
            .child(
                canvas(
                    move |bounds, _, _| {
                        frames.borrow_mut().groups.insert(group_for_frames, bounds);
                        bounds
                    },
                    move |_, _, window, _| {
                        let frames = frames_for_paint.borrow();
                        let member_count = member_ids_for_paint.len();
                        for (index, id) in member_ids_for_paint.iter().enumerate() {
                            let Some(tab_bounds) = frames.tabs.get(id).copied() else {
                                continue;
                            };
                            let line = GroupTabLineEdges {
                                is_first: index == 0,
                                is_last: index + 1 == member_count,
                            }
                            .bounds(tab_bounds);
                            window.paint_quad(gpui::fill(line, group_color.opacity(0.5)));
                        }
                    },
                )
                .map(tab_frame_overlay),
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
                .map(tab_frame_overlay),
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
        let sections = group_idle_tabs_by_repo(ids.iter().copied().map(|id| {
            (
                id,
                self.state.get(id).and_then(|tab| {
                    idle_repo_identity(tab.repo_group_id.as_deref(), tab.git_root.as_deref())
                }),
            )
        }));
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
        for (section_index, section) in sections.iter().enumerate() {
            if section_index > 0 {
                rows.push(
                    div()
                        .flex_shrink_0()
                        .mx(px(8.0))
                        .my(px(3.0))
                        .h(px(1.0))
                        .bg(chrome.border)
                        .into_any_element(),
                );
            }

            let tab_count = section.tab_ids.len();
            let (label, label_color, repository_tooltip, accessibility_label) =
                if let Some(repo_group_id) = section.repo_group_id.as_deref() {
                    let name = repo_group_name(repo_group_id);
                    (
                        name.to_string(),
                        tab_color(repo_group_color(repo_group_id)),
                        Some(SharedString::from(repo_group_id.to_string())),
                        format!("{name}, {repo_group_id}, {tab_count}"),
                    )
                } else {
                    let label = crate::l10n::tr("No repository");
                    (
                        label.clone(),
                        chrome.text_muted,
                        None,
                        format!("{label}, {tab_count}"),
                    )
                };
            let header = div()
                .id(("idle-repo-header", section_index))
                .role(Role::Heading)
                .aria_label(accessibility_label)
                .flex()
                .flex_shrink_0()
                .items_center()
                .gap(px(6.0))
                .px(px(10.0))
                .py(px(4.0))
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .text_color(label_color)
                        .child(label),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .text_color(chrome.text_muted)
                        .child(tab_count.to_string()),
                )
                .when_some(repository_tooltip, |d, tooltip| {
                    d.tooltip(move |window, cx| {
                        gpui_kit::component::tooltip::Tooltip::new(tooltip.clone())
                            .build(window, cx)
                    })
                });
            rows.push(header.into_any_element());

            for id in section.tab_ids.iter().copied() {
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
                        .flex_shrink_0()
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
        }
        let close_all = div()
            .id("idle-close-all")
            .role(Role::Button)
            .flex()
            .flex_shrink_0()
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
            }));
        Some(
            deferred(
                anchored().position(anchor).snap_to_window().child(
                    div()
                        .id("idle-popover")
                        .flex()
                        .flex_col()
                        .occlude()
                        .w(px(240.0))
                        .max_h(px(360.0))
                        .p_1()
                        .rounded_lg()
                        .border_1()
                        .border_color(chrome.border)
                        .bg(chrome.panel_bg)
                        .text_color(chrome.text)
                        .shadow_lg()
                        .child(
                            div()
                                .id("idle-list")
                                .flex()
                                .flex_col()
                                .min_h_0()
                                .max_h(px(300.0))
                                .overflow_y_scroll()
                                .children(rows),
                        )
                        .child(
                            div()
                                .flex_shrink_0()
                                .mx(px(8.0))
                                .my(px(3.0))
                                .h(px(1.0))
                                .bg(chrome.border),
                        )
                        .child(close_all)
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
#[cfg(test)]
mod accessibility_tests {
    use super::*;

    #[test]
    fn tab_accessibility_text_matches_swift_resources_in_all_locales() {
        let cases = [
            (
                Lang::En,
                "Shell tab, /tmp/project",
                "Shell tab",
                "Selected. Double-tap to rename",
                "Double-tap to select, then double-tap to rename",
            ),
            (
                Lang::Fr,
                "Onglet Shell, /tmp/project",
                "Onglet Shell",
                "Sélectionné. Appuyez deux fois pour renommer",
                "Appuyez deux fois pour sélectionner, puis pour renommer",
            ),
            (
                Lang::Es,
                "Pestaña Shell, /tmp/project",
                "Pestaña Shell",
                "Seleccionado. Toca dos veces para renombrar",
                "Toca dos veces para seleccionar, luego toca dos veces para renombrar",
            ),
            (
                Lang::Ar,
                "علامة تبويب Shell, /tmp/project",
                "علامة تبويب Shell",
                "محدد. انقر مرتين لإعادة التسمية",
                "انقر مرتين للتحديد، ثم انقر مرتين لإعادة التسمية",
            ),
            (
                Lang::He,
                "כרטיסייה Shell, /tmp/project",
                "כרטיסייה Shell",
                "נבחר. הקישו פעמיים לשינוי שם",
                "הקישו פעמיים לבחירה, ואז פעמיים לשינוי שם",
            ),
        ];

        for (lang, with_path, without_path, selected, not_selected) in cases {
            assert_eq!(
                tab_accessibility_label(lang, "Shell", Some("/tmp/project")),
                with_path,
                "tab label for {}",
                lang.code(),
            );
            assert_eq!(
                tab_accessibility_label(lang, "Shell", None),
                without_path,
                "tab label without a path for {}",
                lang.code(),
            );
            assert_eq!(
                tab_accessibility_label(lang, "Shell", Some("")),
                without_path,
                "tab label with an empty path for {}",
                lang.code(),
            );
            assert_eq!(
                tab_accessibility_description(lang, true),
                selected,
                "selected tab hint for {}",
                lang.code(),
            );
            assert_eq!(
                tab_accessibility_description(lang, false),
                not_selected,
                "unselected tab hint for {}",
                lang.code(),
            );
        }
    }
}

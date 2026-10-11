//! Floating panels (`DraggableOverlay` in Swift): find, rename and
//! bookmarks open as a panel at the top of the terminal with a grab handle.
//! A dragged panel keeps its position per panel and per workspace (the
//! selected tab's repo, else its directory), saved across launches
//! (`DataRoot::panel_positions_file`, `{workspace: {panel: {x, y}}}` like
//! Swift's `overlay.positions.map`); Reset Window Positions forgets them.
//! Panels slide in from the top with a fade (0.2 s), without animation when
//! Reduce Motion is on. One panel at a time.

use std::collections::BTreeMap;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use gpui::{
    Animation, AnimationExt, AnyElement, App, Context, Global, MouseButton, MouseDownEvent, Pixels,
    Point, div, ease_in_out, prelude::*, px,
};

use super::{AppData, Workspace};
use crate::theme::Chrome;

/// Panel offsets by workspace, then panel (`overlayOffset(for:workspace:)`).
#[derive(Default)]
struct PanelOffsets {
    loaded: bool,
    by_workspace: BTreeMap<String, BTreeMap<String, Offset>>,
}
impl Global for PanelOffsets {}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
struct Offset {
    x: f32,
    y: f32,
}

fn offsets(cx: &mut App) -> &mut PanelOffsets {
    if !cx.default_global::<PanelOffsets>().loaded {
        let file = cx.global::<AppData>().root.panel_positions_file();
        let by_workspace = std::fs::read_to_string(&file)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let store = cx.global_mut::<PanelOffsets>();
        store.by_workspace = by_workspace;
        store.loaded = true;
    }
    cx.global_mut::<PanelOffsets>()
}

fn save_offsets(cx: &App) {
    let Some(store) = cx.try_global::<PanelOffsets>() else {
        return;
    };
    let file = cx.global::<AppData>().root.panel_positions_file();
    let result = serde_json::to_string_pretty(&store.by_workspace)
        .map_err(std::io::Error::other)
        .and_then(|text| std::fs::write(&file, text));
    if let Err(err) = result {
        log::warn!("panel positions: {err}");
    }
}

/// Reset Window Positions (`resetOverlayOffsets`): every panel goes back to
/// its default place.
pub fn reset_panel_positions(cx: &mut App) {
    let store = offsets(cx);
    store.by_workspace.clear();
    save_offsets(cx);
}

/// A panel being moved by its grab handle.
pub(super) struct PanelDrag {
    key: (String, String),
    start: Point<Pixels>,
    origin: Point<Pixels>,
}

/// Which panel is open (only one at a time).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PanelKind {
    Search,
    Rename,
    Bookmarks,
    Timeline,
}

impl PanelKind {
    fn id(self) -> &'static str {
        match self {
            PanelKind::Search => "search",
            PanelKind::Rename => "rename",
            PanelKind::Bookmarks => "bookmarks",
            PanelKind::Timeline => "timeline",
        }
    }
}

impl Workspace {
    /// `overlayWorkspaceIdentifier`: the selected tab's git root, else its
    /// directory.
    fn panel_workspace(&self, cx: &App) -> String {
        let Some(session) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
        else {
            return "global".into();
        };
        let session = session.read(cx);
        session
            .git_root
            .as_ref()
            .or(session.cwd.as_ref())
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "global".into())
    }

    fn panel_key(&self, kind: PanelKind, cx: &App) -> (String, String) {
        (self.panel_workspace(cx), kind.id().to_string())
    }

    /// Close every panel except `keep` (`dismissOverlays`, one panel at a time).
    pub(super) fn close_other_panels(&mut self, keep: Option<PanelKind>, cx: &mut Context<Self>) {
        if keep != Some(PanelKind::Search) && self.search.take().is_some() {
            self.clear_highlights(cx);
        }
        if keep != Some(PanelKind::Rename) {
            self.rename = None;
        }
        if keep != Some(PanelKind::Bookmarks) {
            self.bookmarks_panel = None;
        }
        if keep != Some(PanelKind::Timeline) {
            self.timeline_panel = None;
        }
        self.picker = None;
        cx.notify();
    }

    pub(super) fn panel_drag_move(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) {
        let Some(drag) = self.panel_drag.as_ref() else {
            return;
        };
        let offset = drag.origin + (position - drag.start);
        let (workspace, panel) = drag.key.clone();
        offsets(cx)
            .by_workspace
            .entry(workspace)
            .or_default()
            .insert(
                panel,
                Offset {
                    x: f32::from(offset.x),
                    y: f32::from(offset.y),
                },
            );
        cx.notify();
    }

    pub(super) fn panel_drag_end(&mut self, cx: &mut Context<Self>) {
        if self.panel_drag.take().is_some() {
            save_offsets(cx);
            cx.notify();
        }
    }

    /// A floating panel: grab handle, then `content`. `width` in points.
    pub(super) fn floating_panel(
        &self,
        kind: PanelKind,
        width: f32,
        chrome: Chrome,
        content: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let key = self.panel_key(kind, cx);
        let offset = offsets(cx)
            .by_workspace
            .get(&key.0)
            .and_then(|panels| panels.get(&key.1))
            .map(|o| Point::new(px(o.x), px(o.y)))
            .unwrap_or_default();
        let handle_key = key.clone();
        let handle = div()
            .id(("panel-handle", kind as usize))
            .w_full()
            .h(px(20.0))
            .flex()
            .items_center()
            .justify_center()
            .cursor_grab()
            .child(
                div()
                    .w(px(36.0))
                    .h(px(4.0))
                    .rounded_full()
                    .bg(chrome.text_muted.opacity(0.25)),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                    cx.stop_propagation();
                    this.panel_drag = Some(PanelDrag {
                        key: handle_key.clone(),
                        start: event.position,
                        origin: offset,
                    });
                }),
            );
        let panel = div()
            .id(("panel", kind as usize))
            .occlude()
            .w(px(width))
            .max_w_full()
            .rounded(px(10.0))
            .border_1()
            .border_color(chrome.border)
            .bg(chrome.panel_bg)
            .shadow_lg()
            .text_color(chrome.text)
            .child(handle)
            .child(content)
            // Clicking outside the open panel closes it.
            .on_mouse_down_out(cx.listener(|this, _, window, cx| {
                if this.panel_drag.is_none() {
                    this.close_other_panels(None, cx);
                    this.focus_selected(window, cx);
                }
            }));
        let reduce_motion = crate::platform::system::reduce_motion();
        let positioned = div()
            .absolute()
            .top(px(8.0) + offset.y)
            .left_0()
            .right_0()
            .flex()
            .justify_center()
            .px_4()
            .child(div().relative().left(offset.x).child(panel));
        if reduce_motion {
            positioned.into_any_element()
        } else {
            positioned
                .with_animation(
                    ("panel-in", self.panel_generation),
                    Animation::new(Duration::from_millis(200)).with_easing(ease_in_out),
                    |el, t| el.opacity(t).mt(px(-12.0 * (1.0 - t))),
                )
                .into_any_element()
        }
    }
}

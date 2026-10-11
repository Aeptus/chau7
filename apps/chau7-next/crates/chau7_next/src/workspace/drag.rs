//! Tab and group drag and drop: reorder in the tab bar, or drop on another
//! window (`handleTabDragEnd` and `OverlayWindowDropResolver` in Swift), and
//! moving tabs between windows.

use chau7_next_core::tab_bar_layout::{
    OverlayWindowDropCandidate, Point as LayoutPoint, Rect as LayoutRect, TabBarLayoutItem,
    drop_target_index,
};
use gpui::{
    App, Bounds, Context, DispatchPhase, Entity, MouseButton, MouseMoveEvent, MouseUpEvent, Pixels,
    Point, Window, canvas, prelude::*,
};

use super::{AppData, Workspace};
use crate::tab_bar::{DRAG_THRESHOLD, DragSubject, TAB_SPACING, TabDrag, TabId};

impl Workspace {
    fn visible_order(&self, cx: &App) -> Vec<TabId> {
        self.state
            .display_items(AppData::now(cx))
            .into_iter()
            .filter_map(|item| match item {
                TabBarLayoutItem::Tab(id) => Some(id),
                _ => None,
            })
            .collect()
    }

    pub(super) fn begin_press(
        &mut self,
        subject: DragSubject,
        position: Point<Pixels>,
        cx: &mut Context<Self>,
    ) {
        let ids = self.visible_order(cx);
        let frames = self.frames.borrow();
        let widths: Vec<f32> = ids
            .iter()
            .map(|id| {
                frames
                    .tabs
                    .get(id)
                    .map(|b| f32::from(b.size.width))
                    .unwrap_or(120.0)
            })
            .collect();
        drop(frames);
        let (home_index, ids, widths) = match &subject {
            DragSubject::Tab(id) => (ids.iter().position(|t| t == id).unwrap_or(0), ids, widths),
            DragSubject::Group(group) => {
                // A group moves as one block: collapse its members into one slot.
                let members = self.state.group_members(group);
                let mut block_ids = Vec::new();
                let mut block_widths = Vec::new();
                let mut home = 0;
                let mut seen = false;
                for (id, width) in ids.iter().zip(&widths) {
                    if members.contains(id) {
                        if !seen {
                            home = block_ids.len();
                            block_ids.push(*id);
                            let group_width: f32 = ids
                                .iter()
                                .zip(&widths)
                                .filter(|(i, _)| members.contains(i))
                                .map(|(_, w)| *w + TAB_SPACING)
                                .sum();
                            block_widths.push(group_width);
                            seen = true;
                        }
                    } else {
                        block_ids.push(*id);
                        block_widths.push(*width);
                    }
                }
                (home, block_ids, block_widths)
            }
        };
        self.drag = Some(TabDrag {
            subject,
            start: position,
            current: position,
            home_index,
            widths,
            ids,
            active: false,
        });
    }

    pub(super) fn drag_move(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) {
        let Some(drag) = self.drag.as_mut() else {
            return;
        };
        drag.current = position;
        if !drag.active && (position.x - drag.start.x).abs() > DRAG_THRESHOLD {
            drag.active = true;
            self.hover = None;
        }
        if !drag.active {
            return;
        }
        let offsets = drag.neighbor_offsets();
        for (id, offset) in offsets {
            self.anims.set_target(id, offset);
        }
        // Rendering advances the springs and requests frames while they move.
        cx.notify();
    }

    pub(super) fn drag_end(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(drag) = self.drag.take() else {
            return;
        };
        self.anims.reset();
        if !drag.active {
            cx.notify();
            return;
        }
        // Like `handleTabDragEnd` in Swift: try a cross-window drop first
        // (other windows' tab bars, then their frames); otherwise reorder here.
        let screen = self.screen_bounds.origin + position;
        let me = cx.entity();
        let _ = window;
        // Resolve after this update: the resolver reads every workspace, this one included.
        cx.defer(move |cx| {
            if let Some(target) = drop_target_for(&me, screen, cx) {
                move_subject_to(me, drag.subject.clone(), target, cx);
            } else {
                me.update(cx, |ws, cx| ws.finish_reorder(drag, cx));
            }
        });
    }

    pub(super) fn finish_reorder(&mut self, drag: TabDrag, cx: &mut Context<Self>) {
        let dest_slot = drag.destination();
        let dest_id = drag.ids.get(dest_slot).copied();
        match &drag.subject {
            DragSubject::Tab(id) => {
                if let Some(dest_id) = dest_id
                    && let Some(index) = self.state.index_of(dest_id)
                {
                    log::info!("TABBAR reorder tab={id} to={index}");
                    self.state.move_tab(*id, index);
                }
            }
            DragSubject::Group(group) => {
                let members = self.state.group_members(group);
                let rest: Vec<TabId> = self
                    .state
                    .tabs()
                    .iter()
                    .map(|t| t.id)
                    .filter(|id| !members.contains(id))
                    .collect();
                let index = dest_id
                    .and_then(|d| rest.iter().position(|r| *r == d))
                    .map(|i| {
                        if dest_slot > drag.home_index {
                            i + 1
                        } else {
                            i
                        }
                    })
                    .unwrap_or(rest.len());
                log::info!("TABBAR reorder group={group} to={index}");
                self.state.move_group(group, index);
            }
        }
        cx.notify();
    }

    pub(super) fn drag_listener(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let me = cx.entity().downgrade();
        canvas(
            |_, _, _| {},
            move |_, _, window, _| {
                let me_move = me.clone();
                window.on_mouse_event(move |event: &MouseMoveEvent, phase, window, cx| {
                    if phase != DispatchPhase::Capture {
                        return;
                    }
                    if let Some(me) = me_move.upgrade() {
                        if me.read(cx).panel_drag.is_some() {
                            if event.pressed_button == Some(MouseButton::Left) {
                                me.update(cx, |ws, cx| ws.panel_drag_move(event.position, cx));
                            } else {
                                me.update(cx, |ws, cx| ws.panel_drag_end(cx));
                            }
                            return;
                        }
                        let has_drag = me.read(cx).drag.is_some();
                        if has_drag {
                            if event.pressed_button != Some(MouseButton::Left) {
                                me.update(cx, |ws, cx| ws.drag_end(event.position, window, cx));
                            } else {
                                me.update(cx, |ws, cx| ws.drag_move(event.position, cx));
                            }
                        }
                    }
                });
                let me_up = me.clone();
                window.on_mouse_event(move |event: &MouseUpEvent, phase, window, cx| {
                    if phase != DispatchPhase::Capture || event.button != MouseButton::Left {
                        return;
                    }
                    if let Some(me) = me_up.upgrade()
                        && me.read(cx).panel_drag.is_some()
                    {
                        me.update(cx, |ws, cx| ws.panel_drag_end(cx));
                        return;
                    }
                    if let Some(me) = me_up.upgrade()
                        && me.read(cx).drag.is_some()
                    {
                        me.update(cx, |ws, cx| ws.drag_end(event.position, window, cx));
                    }
                });
            },
        )
        .absolute()
        .size_0()
        .into_any_element()
    }
}

/// Move tabs to another window (`None` = a new one), appended and selected
/// there, like `AppDelegate.moveTab`.
pub fn move_tabs_to(
    source: Entity<Workspace>,
    ids: Vec<TabId>,
    target: Option<usize>,
    cx: &mut App,
) {
    let target_ws = target.and_then(|index| {
        // Indexes come from the menu, which lists every window except the source.
        let all = AppData::live(cx);
        all.get(index).map(|(_, ws)| ws.clone())
    });
    let target_ws = target_ws.filter(|ws| ws.entity_id() != source.entity_id());
    let Some(source_window) = source.read(cx).window_handle else {
        return;
    };
    let mut moved = Vec::new();
    let _ = source_window.update(cx, |_, window, cx| {
        source.update(cx, |ws, cx| {
            for id in &ids {
                if let Some(tab) = ws.take_tab(*id, window, cx) {
                    moved.push(tab);
                }
            }
            cx.notify();
        });
    });
    if moved.is_empty() {
        return;
    }
    match target_ws {
        Some(target) => {
            let Some(handle) = target.read(cx).window_handle else {
                return;
            };
            let count = moved.len();
            let _ = handle.update(cx, |_, window, cx| {
                target.update(cx, |ws, cx| {
                    for (i, (meta, panes)) in moved.into_iter().enumerate() {
                        log::info!(
                            "TABBAR move_window tab={} target={:?}",
                            meta.id,
                            handle.window_id()
                        );
                        ws.adopt_tab(meta, panes, i + 1 == count, cx);
                    }
                    log::info!("TABBAR move_window done target_tabs={}", ws.state.len());
                    ws.focus_selected(window, cx);
                });
                window.activate_window();
            });
        }
        None => {
            crate::open_window_with_tabs(moved, cx);
        }
    }
}

/// Window index (in `AppData::live` order) under a screen point, excluding
/// the source: tab bar frame first, then window frame
/// (`OverlayWindowDropResolver`).
pub(super) fn drop_target_for(
    source: &Entity<Workspace>,
    screen: Point<Pixels>,
    cx: &App,
) -> Option<usize> {
    let all = AppData::live(cx);
    let source_index = all
        .iter()
        .position(|(_, ws)| ws.entity_id() == source.entity_id());
    let candidates: Vec<OverlayWindowDropCandidate> = all
        .iter()
        .enumerate()
        .map(|(index, (_, ws))| {
            let ws = ws.read(cx);
            let origin = ws.screen_bounds.origin;
            let bar = ws
                .frames
                .borrow()
                .bar
                .map(|b| Bounds::new(origin + b.origin, b.size))
                .unwrap_or_default();
            OverlayWindowDropCandidate::new(index, layout_rect(bar), layout_rect(ws.screen_bounds))
        })
        .collect();
    let point = LayoutPoint {
        x: f32::from(screen.x),
        y: f32::from(screen.y),
    };
    let target = drop_target_index(point, &candidates, source_index);
    log::info!(
        "TABBAR drop_target screen=({:.0},{:.0}) target={target:?}",
        point.x,
        point.y
    );
    target
}

pub(super) fn move_subject_to(
    source: Entity<Workspace>,
    subject: DragSubject,
    target: usize,
    cx: &mut App,
) {
    let ids = match subject {
        DragSubject::Tab(id) => vec![id],
        DragSubject::Group(group) => source.read(cx).state.group_members(&group),
    };
    move_tabs_to(source, ids, Some(target), cx);
}

pub(super) fn layout_rect(b: Bounds<Pixels>) -> LayoutRect {
    LayoutRect {
        x: f32::from(b.origin.x),
        y: f32::from(b.origin.y),
        width: f32::from(b.size.width),
        height: f32::from(b.size.height),
    }
}

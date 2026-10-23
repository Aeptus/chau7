//! Tab and group drag and drop: reorder in the tab bar, or drop on another
//! window (`handleTabDragEnd` and `OverlayWindowDropResolver` in Swift), and
//! moving tabs between windows.

use chau7_next_core::tab_bar_layout::{
    OverlayWindowDropCandidate, Point as LayoutPoint, Rect as LayoutRect, TabBarLayoutItem,
    fallback_drop_target_index,
};
use gpui::{
    App, Bounds, Context, DispatchPhase, Entity, EntityId, MouseButton, MouseMoveEvent,
    MouseUpEvent, Pixels, Point, Window, canvas, prelude::*,
};

use super::{AppData, Workspace};
use crate::platform::window_drop::{
    NativeDropHit, eligible_window_number, native_drop_hit_for_position,
};
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
        let drag_distance = f32::from(position.x - drag.start.x)
            .abs()
            .max(f32::from(position.y - drag.start.y).abs());
        if !drag.active && drag_distance > f32::from(DRAG_THRESHOLD) {
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
            if let DragSubject::Group(group) = drag.subject {
                self.toggle_dashboard(group, window, cx);
            }
            cx.notify();
            return;
        }
        // Resolve the actual frontmost window for cross-window drops; if none
        // is eligible, finish the drag as a local reorder.
        let screen = self.screen_bounds.origin + position;
        let native_hit = native_drop_hit_for_position(window, position);
        let me = cx.entity();
        // Resolve after this update: the resolver reads every workspace, this one included.
        cx.defer(move |cx| {
            let target = drop_target_for(&me, screen, native_hit, cx).and_then(|index| {
                AppData::live(cx)
                    .get(index)
                    .map(|(_, workspace)| workspace.entity_id())
            });
            if let Some(target) = target {
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
    mut ids: Vec<TabId>,
    target: Option<EntityId>,
    cx: &mut App,
) {
    let Some(source_window) = source.read(cx).window_handle else {
        return;
    };
    ids.retain(|id| {
        let workspace = source.read(cx);
        workspace.state.get(*id).is_some() && workspace.entries.contains_key(id)
    });
    if ids.is_empty() {
        return;
    }
    let created_window = target.is_none();
    let (target_window, target_ws) = match target {
        Some(target_id) => {
            let Some((handle, workspace)) = AppData::live(cx)
                .into_iter()
                .find(|(_, workspace)| workspace.entity_id() == target_id)
            else {
                log::warn!("TABBAR move_window cancelled: destination no longer exists");
                return;
            };
            if workspace.entity_id() == source.entity_id() {
                return;
            }
            (handle, workspace)
        }
        None => {
            // Create a usable destination before extracting any source tab.
            // Window creation can fail, especially while displays reconnect.
            let Some(destination) = crate::open_window_for_transfer(cx) else {
                return;
            };
            destination
        }
    };
    let mut moved_count = 0;
    // Enter the destination window first. A stale/closed handle must leave
    // the source tabs and their live sessions completely untouched.
    let result = target_window.update(cx, |_, target_window, cx| {
        let moved = source_window.update(cx, |_, source_window, cx| {
            source.update(cx, |workspace, cx| {
                let moved: Vec<_> = ids
                    .iter()
                    .filter_map(|id| workspace.take_tab(*id, source_window, cx))
                    .collect();
                cx.notify();
                moved
            })
        });
        let moved = match moved {
            Ok(moved) => moved,
            Err(error) => {
                log::warn!("TABBAR move_window cancelled: source unavailable: {error}");
                return;
            }
        };
        moved_count = moved.len();
        if moved_count == 0 {
            return;
        }
        target_ws.update(cx, |workspace, cx| {
            for (index, tab) in moved.into_iter().enumerate() {
                log::info!(
                    "TABBAR move_window tab={} target={:?}",
                    tab.meta.id,
                    target_window.window_handle().window_id()
                );
                workspace.adopt_moved_tab(tab, index + 1 == moved_count, cx);
            }
            log::info!(
                "TABBAR move_window done target_tabs={}",
                workspace.state.len()
            );
            workspace.focus_selected(target_window, cx);
        });
        target_window.activate_window();
    });
    if let Err(error) = result {
        log::warn!("TABBAR move_window cancelled: destination unavailable: {error}");
    }
    if created_window && moved_count == 0 {
        // Only retire the empty window this operation just created.
        let _ = target_window.update(cx, |_, window, _| window.remove_window());
    }
}

/// Window index (in `AppData::live` order) under a drag point.
///
/// macOS uses AppKit's actual frontmost window hit. If AppKit reports no
/// target or a window outside the live workspaces, that blocks geometric
/// fallback so drops cannot pass through another app or Space. When native
/// z-order is unavailable, cached geometry transfers only to a unique target
/// that does not overlap the source.
pub(super) fn drop_target_for(
    source: &Entity<Workspace>,
    screen: Point<Pixels>,
    native_hit: NativeDropHit,
    cx: &mut App,
) -> Option<usize> {
    let all = AppData::live(cx);
    let source_index = all
        .iter()
        .position(|(_, ws)| ws.entity_id() == source.entity_id());
    let point = LayoutPoint {
        x: f32::from(screen.x),
        y: f32::from(screen.y),
    };
    match native_hit {
        NativeDropHit::Window(native_number) => {
            let target = all.iter().enumerate().find_map(|(index, (_, workspace))| {
                let (workspace_id, handle) = {
                    let workspace_id = workspace.entity_id();
                    let state = workspace.read(cx);
                    (workspace_id, state.window_handle)
                };
                if workspace_id == source.entity_id() {
                    return None;
                }
                let handle = handle?;
                let candidate_number = handle
                    .update(cx, |_, window, _| eligible_window_number(window))
                    .ok()
                    .flatten()?;
                (candidate_number == native_number).then_some(index)
            });
            log::info!("TABBAR drop_target native_hit={native_number} target={target:?}");
            target
        }
        NativeDropHit::Blocked => {
            log::info!("TABBAR drop_target native_hit=blocked target=None");
            None
        }
        NativeDropHit::Unavailable => {
            let candidates: Vec<OverlayWindowDropCandidate> = all
                .iter()
                .enumerate()
                .map(|(index, (_, workspace))| {
                    let workspace = workspace.read(cx);
                    let origin = workspace.screen_bounds.origin;
                    let bar = workspace
                        .frames
                        .borrow()
                        .bar
                        .map(|bounds| Bounds::new(origin + bounds.origin, bounds.size))
                        .unwrap_or_default();
                    OverlayWindowDropCandidate::new(
                        index,
                        layout_rect(bar),
                        layout_rect(workspace.screen_bounds),
                    )
                })
                .collect();
            let target = fallback_drop_target_index(point, &candidates, source_index);
            log::info!(
                "TABBAR drop_target fallback screen=({:.0},{:.0}) target={target:?}",
                point.x,
                point.y
            );
            target
        }
    }
}

pub(super) fn move_subject_to(
    source: Entity<Workspace>,
    subject: DragSubject,
    target: EntityId,
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

#[cfg(test)]
#[path = "drag_tests.rs"]
mod drag_tests;

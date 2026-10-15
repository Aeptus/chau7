//! Mouse input of the terminal view: selection (drag, double and triple
//! click, auto-scroll past the edges), copy on select, click to position the
//! cursor, Option-click, mouse reporting to programs, the context menu, the
//! scroll wheel and drag and drop.
//!
//! Mirrors the event monitors of `RustTerminalView.swift`
//! (`setupEventMonitors`, `performAutoScroll`, `handleClickToPosition`,
//! `handleOptionClick`, `sendMouseEvent`, `menu(for:)`,
//! `performDragOperation`). A child module of `view.rs`.

use std::time::Duration;

use chau7_next_core::input::{cursor_moves, drop};
use chau7_next_core::key_encoding::{self, KeyMods, MouseAction, MouseButtonCode};
use gpui::{
    ClipboardItem, Context, ExternalPaths, MouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, Pixels, Point, ScrollDelta, ScrollWheelEvent, Task, TouchPhase, Window, px,
};

use super::TerminalView;
use crate::settings::Settings;
use crate::terminal::session::SelectionKind;

/// Movement before a press becomes a drag selection (Swift `dragThreshold`).
const DRAG_THRESHOLD: f32 = 1.5;
/// Auto-scroll starts this close to the top or bottom edge.
const EDGE_INSET: f32 = 10.0;
/// Copy on select waits this long (debounce, Swift `scheduleCopyOnSelect`).
const COPY_ON_SELECT_DELAY: Duration = Duration::from_millis(50);

#[derive(Default)]
pub(super) struct MouseState {
    /// Where the left button went down (window position), for click to
    /// position and the drag threshold.
    down: Option<Point<Pixels>>,
    /// Option was held on mouse down: a click moves the cursor (when
    /// `option_click_cursor` is on), a drag selects a block.
    down_alt: bool,
    dragged: bool,
    /// Auto-scroll direction (-1 up into history, 1 down) and distance past the edge.
    scroll_dir: i32,
    scroll_distance: f32,
    wheel_scroll: ScrollLineAccumulator,
    auto_scroll: Option<Task<()>>,
    copy_task: Option<Task<()>>,
    last_copied: Option<String>,
}

#[derive(Default)]
struct ScrollLineAccumulator {
    fractional_lines: f32,
    reporting_mode: Option<bool>,
}

impl ScrollLineAccumulator {
    fn set_reporting_mode(&mut self, reporting: bool) {
        if self
            .reporting_mode
            .is_some_and(|previous| previous != reporting)
        {
            self.fractional_lines = 0.0;
        }
        self.reporting_mode = Some(reporting);
    }

    fn accumulate(&mut self, delta_lines: f32, phase: TouchPhase) -> i32 {
        if phase == TouchPhase::Started {
            self.fractional_lines = 0.0;
        }
        if phase == TouchPhase::Cancelled {
            self.fractional_lines = 0.0;
            return 0;
        }
        if !delta_lines.is_finite() {
            self.fractional_lines = 0.0;
            return 0;
        }

        let accumulated = self.fractional_lines + delta_lines;
        let lines = accumulated.trunc() as i32;
        self.fractional_lines = if phase == TouchPhase::Ended {
            0.0
        } else {
            accumulated - lines as f32
        };
        lines
    }
}

impl TerminalView {
    /// Mouse listeners of the terminal element.
    pub(super) fn mouse_listeners(
        div: gpui::Stateful<gpui::Div>,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        use gpui::prelude::*;
        div.on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_down(MouseButton::Middle, cx.listener(Self::on_other_mouse_down))
            .on_mouse_down(MouseButton::Right, cx.listener(Self::on_right_mouse_down))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up(MouseButton::Middle, cx.listener(Self::on_other_mouse_up))
            .on_mouse_up_out(MouseButton::Middle, cx.listener(Self::on_other_mouse_up))
            .on_scroll_wheel(cx.listener(Self::on_scroll))
            .on_drop(cx.listener(Self::on_drop_paths))
    }

    /// Mouse events go to the program when it asked for them and the "Mouse
    /// Reporting" setting is on (`feature.mouseReporting`, off by default).
    /// Shift and Ctrl force local selection and menus.
    fn reports_mouse(&self, modifiers: gpui::Modifiers, cx: &gpui::App) -> bool {
        Settings::get(cx).input.mouse_reporting
            && !modifiers.shift
            && !modifiers.control
            && self.session.read(cx).mouse_mode() & 0b111 != 0
    }

    /// Send one mouse report. Returns false when the mode does not report it.
    fn report_mouse(
        &mut self,
        button: MouseButtonCode,
        action: MouseAction,
        position: Point<Pixels>,
        modifiers: gpui::Modifiers,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some((col, row)) = self.cell_at(position, cx) else {
            return false;
        };
        let mods = KeyMods {
            shift: modifiers.shift,
            alt: modifiers.alt,
            control: modifiers.control,
            platform: false,
        };
        let mode = self.session.read(cx).mouse_mode();
        match key_encoding::encode_mouse(button, action, col as u16, row as u16, mods, mode) {
            Some(bytes) => {
                self.session.read(cx).write(&bytes);
                true
            }
            None => false,
        }
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        self.stop_auto_scroll();
        self.input.mouse.copy_task = None;
        // A fresh press also terminates a reported drag whose release was
        // lost, including when Shift now requests local selection.
        if let Some(button) = self.reporting_button.take() {
            self.report_mouse(
                button,
                MouseAction::Release,
                event.position,
                event.modifiers,
                cx,
            );
        }
        self.input.mouse.down = None;
        self.input.mouse.down_alt = false;
        self.input.mouse.dragged = false;
        self.selecting = false;
        if self.reports_mouse(event.modifiers, cx) {
            self.reporting_button = Some(MouseButtonCode::Left);
            self.report_mouse(
                MouseButtonCode::Left,
                MouseAction::Press,
                event.position,
                event.modifiers,
                cx,
            );
            return;
        }
        let Some((col, row)) = self.cell_at(event.position, cx) else {
            return;
        };
        let state = &mut self.input.mouse;
        state.down = Some(event.position);
        state.down_alt = event.modifiers.alt;
        state.dragged = false;
        self.selecting = false;

        // Cmd-click (Ctrl-click off macOS) opens hyperlinks, URLs and file
        // paths (`terminal/links.rs`).
        if super::links::is_link_modifier(&event.modifiers)
            && let Some(target) = super::links::target_at(&self.session, col, row, cx)
        {
            if let Some((path, line)) =
                super::links::internal_editor_target(&self.session, &target, cx)
            {
                log::info!("Cmd+click - opening in internal editor: {}", path.display());
                cx.emit(crate::terminal::view::TerminalViewEvent::OpenInEditor { path, line });
                self.input.mouse.down = None;
                return;
            }
            if super::links::activate(&self.session, target, cx) {
                self.input.mouse.down = None;
                return;
            }
        }

        let line = self.grid_line(row, cx);
        let session = self.session.read(cx);
        match event.click_count {
            2 | 3.. => {
                let kind = if event.click_count == 2 {
                    SelectionKind::Word
                } else {
                    SelectionKind::Line
                };
                session.selection_start(col, line, kind);
                session.selection_update(col, line);
                self.input.mouse.down = None;
                self.selecting = true;
            }
            _ if event.modifiers.shift && session.selection_text().is_some() => {
                // Preserve the existing anchor when Shift-click continues
                // into a drag, just as for word/line selection above.
                session.selection_update(col, line);
                self.input.mouse.down = None;
                self.selecting = true;
            }
            _ => session.selection_clear(),
        }
        self.session.update(cx, |s, cx| s.refresh(cx));
        self.publish_selection(window, cx);
    }

    fn on_other_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        if self.reports_mouse(event.modifiers, cx) {
            self.reporting_button = Some(MouseButtonCode::Middle);
            self.report_mouse(
                MouseButtonCode::Middle,
                MouseAction::Press,
                event.position,
                event.modifiers,
                cx,
            );
        }
    }

    fn on_other_mouse_up(&mut self, event: &MouseUpEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.reporting_button == Some(MouseButtonCode::Middle) {
            self.reporting_button = None;
            self.report_mouse(
                MouseButtonCode::Middle,
                MouseAction::Release,
                event.position,
                event.modifiers,
                cx,
            );
        }
    }

    /// Right click: reported to the program as press and release when it
    /// tracks the mouse (Shift forces the menu), otherwise the context menu.
    fn on_right_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        cx.stop_propagation();
        if self.reports_mouse(event.modifiers, cx) {
            for action in [MouseAction::Press, MouseAction::Release] {
                self.report_mouse(
                    MouseButtonCode::Right,
                    action,
                    event.position,
                    event.modifiers,
                    cx,
                );
            }
            return;
        }
        // An inline image has its own menu (Copy Image, Save Image...).
        let on_image = self.bounds.is_some_and(|b| {
            self.overlays
                .images
                .hit(event.position - b.origin)
                .is_some()
        });
        if on_image {
            self.show_image_menu(event.position, window, cx);
            return;
        }
        self.show_context_menu(event.position, window, cx);
    }

    pub(super) fn has_active_mouse_gesture(&self) -> bool {
        self.input.mouse.down.is_some() || self.selecting || self.reporting_button.is_some()
    }

    pub(super) fn on_mouse_move(
        &mut self,
        event: &MouseMoveEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A release can be missed when the pointer leaves the window or the
        // app loses the drag. End the gesture and cancel its timer while
        // keeping the selection already written to the terminal session.
        if event.pressed_button.is_none() {
            let had_reporting_button = self.reporting_button.is_some();
            if let Some(button) = self.reporting_button.take() {
                self.report_mouse(
                    button,
                    MouseAction::Release,
                    event.position,
                    event.modifiers,
                    cx,
                );
            }
            let had_mouse_down = self.input.mouse.down.take().is_some();
            let down_alt = std::mem::take(&mut self.input.mouse.down_alt);
            let was_selecting = std::mem::take(&mut self.selecting);
            if had_mouse_down || was_selecting || had_reporting_button {
                self.input.mouse.dragged = false;
                self.stop_auto_scroll();
                if was_selecting {
                    self.publish_selection(window, cx);
                    self.schedule_copy_on_select(down_alt || event.modifiers.alt, cx);
                }
                if self.link_hover {
                    self.link_hover = false;
                    cx.notify();
                }
                return;
            }
        }

        // Holding Cmd over a link shows the pointing hand.
        let hover = self
            .bounds
            .is_some_and(|bounds| bounds.contains(&event.position))
            && super::links::is_link_modifier(&event.modifiers)
            && self
                .cell_at(event.position, cx)
                .is_some_and(|(c, r)| super::links::target_at(&self.session, c, r, cx).is_some());
        if hover != self.link_hover {
            self.link_hover = hover;
            cx.notify();
        }
        // Motion reports: with the reported button held (drag), or none
        // (any-motion mode).
        if let Some(button) = self.reporting_button {
            self.report_mouse(
                button,
                MouseAction::Motion,
                event.position,
                event.modifiers,
                cx,
            );
            return;
        }
        if event.pressed_button.is_none() {
            if self.bounds.is_some_and(|b| b.contains(&event.position))
                && self.reports_mouse(event.modifiers, cx)
            {
                self.report_mouse(
                    MouseButtonCode::None,
                    MouseAction::Motion,
                    event.position,
                    event.modifiers,
                    cx,
                );
            }
            return;
        }
        if event.pressed_button != Some(MouseButton::Left) {
            return;
        }
        let Some(down) = self.input.mouse.down else {
            if self.selecting {
                self.extend_selection_to(event.position, cx);
                self.update_auto_scroll(event.position, cx);
            }
            return;
        };
        let moved = (event.position.x - down.x).abs() > px(DRAG_THRESHOLD)
            || (event.position.y - down.y).abs() > px(DRAG_THRESHOLD);
        if !moved {
            return;
        }
        if !self.input.mouse.dragged {
            self.input.mouse.dragged = true;
            if let Some((col, row)) = self.cell_at(down, cx) {
                // Option-drag selects a rectangular block.
                let kind = if self.input.mouse.down_alt {
                    SelectionKind::Block
                } else {
                    SelectionKind::Simple
                };
                let line = self.grid_line(row, cx);
                self.session.read(cx).selection_start(col, line, kind);
                self.selecting = true;
            }
        }
        if self.selecting {
            self.extend_selection_to(event.position, cx);
            self.update_auto_scroll(event.position, cx);
        }
    }

    fn extend_selection_to(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) -> bool {
        if let Some((col, row)) = self.cell_at(position, cx) {
            let line = self.grid_line(row, cx);
            self.session.read(cx).selection_update(col, line);
            self.session.update(cx, |s, cx| s.refresh(cx));
            true
        } else {
            false
        }
    }

    /// Dragging near or past the top or bottom edge scrolls on a timer,
    /// faster the further out the mouse is (Swift `performAutoScroll`).
    fn update_auto_scroll(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) {
        let Some(bounds) = self.bounds else {
            return;
        };
        let state = &mut self.input.mouse;
        let top = bounds.top() + px(EDGE_INSET);
        let bottom = bounds.bottom() - px(EDGE_INSET);
        if position.y < top {
            state.scroll_dir = -1;
            state.scroll_distance = f32::from(top - position.y);
        } else if position.y > bottom {
            state.scroll_dir = 1;
            state.scroll_distance = f32::from(position.y - bottom);
        } else {
            self.stop_auto_scroll();
            return;
        }
        if state.auto_scroll.is_some() {
            return;
        }
        state.auto_scroll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(50))
                    .await;
                let keep = this
                    .update(cx, |this, cx| this.auto_scroll_step(cx))
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        }));
    }

    fn auto_scroll_step(&mut self, cx: &mut Context<Self>) -> bool {
        let dir = self.input.mouse.scroll_dir;
        if dir == 0 || !self.selecting {
            self.input.mouse.auto_scroll = None;
            return false;
        }
        let speed = ((self.input.mouse.scroll_distance / 20.0) as i32 + 1).clamp(1, 10);
        let session = self.session.read(cx);
        // Positive lines scroll up into the history.
        session.scroll_lines(-dir * speed);
        // Extend to the edge row, even when the scroll was a no-op.
        let offset = session.display_offset() as i32;
        let (cols, rows) = (session.grid.cols as i32, session.grid.rows as i32);
        let (col, row) = if dir < 0 {
            (0, 0)
        } else {
            (cols - 1, rows - 1)
        };
        session.selection_update(col, row - offset);
        self.session.update(cx, |s, cx| s.refresh(cx));
        true
    }

    fn stop_auto_scroll(&mut self) {
        let state = &mut self.input.mouse;
        state.scroll_dir = 0;
        state.scroll_distance = 0.0;
        state.auto_scroll = None;
    }

    fn on_mouse_up(&mut self, event: &MouseUpEvent, window: &mut Window, cx: &mut Context<Self>) {
        let down = self.input.mouse.down.take();
        let down_alt = std::mem::take(&mut self.input.mouse.down_alt);
        let dragged = std::mem::take(&mut self.input.mouse.dragged);
        let was_selecting = std::mem::take(&mut self.selecting);
        self.stop_auto_scroll();
        self.publish_selection(window, cx);
        if let Some(button) = self.reporting_button.take() {
            self.report_mouse(
                button,
                MouseAction::Release,
                event.position,
                event.modifiers,
                cx,
            );
            return;
        }
        let inside = self.bounds.is_some_and(|b| b.contains(&event.position));
        if let Some(down) = down
            && !dragged
            && inside
        {
            let input = &Settings::get(cx).input;
            let mods = event.modifiers;
            if down_alt && input.option_click_cursor {
                // Option-click moves the cursor to the clicked cell.
                if let Some(target) = self.screen_cell(down, cx) {
                    let cursor = self.cursor_cell(cx);
                    let bytes = cursor_moves::arrow_sequence(cursor, target);
                    if !bytes.is_empty() {
                        self.write(&bytes, cx);
                    }
                }
                return;
            }
            // Click to position: a plain single click near the cursor.
            if event.click_count == 1
                && !mods.shift
                && !mods.platform
                && !mods.alt
                && input.click_to_position
                && self.session.read(cx).selection_text().is_none()
                && let Some(target) = self.screen_cell(down, cx)
                && let Some(bytes) = cursor_moves::click_to_position(self.cursor_cell(cx), target)
            {
                self.write(&bytes, cx);
                return;
            }
        }
        if was_selecting {
            self.schedule_copy_on_select(down_alt || event.modifiers.alt, cx);
        }
    }

    /// The live-screen cell under a window position (rows above the screen
    /// are negative when scrolled back).
    fn screen_cell(&self, position: Point<Pixels>, cx: &gpui::App) -> Option<(i32, i32)> {
        let (col, row) = self.cell_at(position, cx)?;
        Some((col, self.grid_line(row, cx)))
    }

    fn cursor_cell(&self, cx: &gpui::App) -> (i32, i32) {
        let (col, row) = self.session.read(cx).cursor;
        (col as i32, row as i32)
    }

    /// Copy on select (`feature.copyOnSelect`, default on): after a drag,
    /// double or triple click, debounced, skipped while Option is held and
    /// when the text did not change.
    fn schedule_copy_on_select(&mut self, alt_held: bool, cx: &mut Context<Self>) {
        if alt_held || !Settings::get(cx).input.copy_on_select {
            return;
        }
        self.input.mouse.copy_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(COPY_ON_SELECT_DELAY).await;
            let _ = this.update(cx, |this, cx| {
                let Some(text) = this.session.read(cx).selection_text() else {
                    return;
                };
                if this.input.mouse.last_copied.as_deref() == Some(text.as_str()) {
                    return;
                }
                crate::workspace::record_clipboard(&text, cx);
                cx.write_to_clipboard(ClipboardItem::new_string(text.clone()));
                this.input.mouse.last_copied = Some(text);
            });
        }));
    }

    fn on_scroll(
        &mut self,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let has_vertical_delta = match event.delta {
            ScrollDelta::Lines(delta) => delta.y != 0.0,
            ScrollDelta::Pixels(delta) => delta.y != px(0.0),
        };
        if has_vertical_delta {
            // Fractional trackpad events still belong to the terminal even
            // when they have not accumulated to a whole cell yet.
            cx.stop_propagation();
        }

        let reports_mouse = self.reports_mouse(event.modifiers, cx);
        self.input
            .mouse
            .wheel_scroll
            .set_reporting_mode(reports_mouse);
        let delta_lines = match event.delta {
            ScrollDelta::Lines(delta) => delta.y,
            ScrollDelta::Pixels(delta) => self
                .metrics
                .as_ref()
                .filter(|metrics| metrics.line_height > px(0.0))
                .map(|metrics| delta.y / metrics.line_height)
                .unwrap_or(0.0),
        };
        let lines = self
            .input
            .mouse
            .wheel_scroll
            .accumulate(delta_lines, event.touch_phase);
        if lines == 0 {
            return;
        }
        if reports_mouse {
            let wheel = if lines > 0 {
                MouseButtonCode::WheelUp
            } else {
                MouseButtonCode::WheelDown
            };
            for _ in 0..lines.unsigned_abs().min(10) {
                self.report_mouse(
                    wheel,
                    MouseAction::Press,
                    event.position,
                    event.modifiers,
                    cx,
                );
            }
            cx.stop_propagation();
            return;
        }
        self.session.read(cx).scroll_lines(lines);
        // The wheel extends an active selection. Its coordinate conversion
        // reads the backend's live offset after the scroll.
        let selection_refreshed = self.selecting && self.extend_selection_to(event.position, cx);
        if !selection_refreshed {
            self.session.update(cx, |s, cx| s.refresh(cx));
        }
        cx.stop_propagation();
    }

    /// Image bytes dropped without a file (a PNG or TIFF from a browser):
    /// pasted as a markdown data URI, a beep above 10 MB
    /// (`pasteImageData`, RBK-051; see `platform::drop_image`).
    pub fn paste_image_data(&mut self, data: &[u8], cx: &mut Context<Self>) {
        match drop::image_data_uri(data, None) {
            Some(text) => {
                log::info!("dropped image image.png ({} bytes)", data.len());
                self.paste_text(&text, cx);
            }
            None => {
                log::warn!(
                    "dropped image too large ({} bytes, limit 10000000)",
                    data.len()
                );
                crate::platform::sound::beep();
            }
        }
    }

    /// Dropped files paste their single-quoted paths; Option-drop of one
    /// image pastes a markdown data URI for AI CLIs (10 MB limit, beep above).
    fn on_drop_paths(
        &mut self,
        paths: &ExternalPaths,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        let paths = paths.paths();
        if paths.is_empty() {
            return;
        }
        if window.modifiers().alt
            && paths.len() == 1
            && let Some(name) = paths[0]
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
            && drop::is_image_file(&name)
        {
            match std::fs::read(&paths[0])
                .ok()
                .and_then(|data| drop::image_data_uri(&data, Some(&name)))
            {
                Some(text) => self.paste_text(&text, cx),
                None => {
                    log::warn!(
                        "dropped image too large or unreadable: {}",
                        paths[0].display()
                    );
                    crate::platform::sound::beep();
                }
            }
            return;
        }
        let names: Vec<String> = paths
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();
        self.paste_text(&drop::paths_text(&names), cx);
    }
}
#[cfg(test)]
mod scroll_line_accumulator_tests {
    use super::ScrollLineAccumulator;
    use gpui::TouchPhase;

    #[test]
    fn accumulates_fractional_trackpad_deltas_until_a_line_is_ready() {
        let mut accumulator = ScrollLineAccumulator::default();

        let emitted: Vec<_> = (0..5)
            .map(|_| accumulator.accumulate(0.2, TouchPhase::Moved))
            .collect();

        assert_eq!(emitted, [0, 0, 0, 0, 1]);
        assert!(accumulator.fractional_lines.abs() < f32::EPSILON);
    }

    #[test]
    fn handles_negative_scroll_and_direction_reversals_without_stray_lines() {
        let mut accumulator = ScrollLineAccumulator::default();
        let emitted: Vec<_> = (0..5)
            .map(|_| accumulator.accumulate(-0.2, TouchPhase::Moved))
            .collect();
        assert_eq!(emitted, [0, 0, 0, 0, -1]);
        assert_eq!(accumulator.fractional_lines, 0.0);

        assert_eq!(accumulator.accumulate(0.8, TouchPhase::Moved), 0);
        assert_eq!(accumulator.accumulate(-0.4, TouchPhase::Moved), 0);
        assert_eq!(accumulator.accumulate(-0.4, TouchPhase::Ended), 0);
        assert_eq!(accumulator.fractional_lines, 0.0);

        assert_eq!(accumulator.accumulate(0.5, TouchPhase::Moved), 0);
        assert_eq!(accumulator.accumulate(0.0, TouchPhase::Ended), 0);
        assert_eq!(accumulator.fractional_lines, 0.0);
    }

    #[test]
    fn resets_after_non_finite_deltas_and_reporting_mode_changes() {
        let mut accumulator = ScrollLineAccumulator::default();
        accumulator.set_reporting_mode(false);
        assert_eq!(accumulator.accumulate(0.8, TouchPhase::Moved), 0);
        accumulator.set_reporting_mode(true);
        assert_eq!(accumulator.fractional_lines, 0.0);
        assert_eq!(accumulator.accumulate(f32::NAN, TouchPhase::Moved), 0);
        assert_eq!(accumulator.fractional_lines, 0.0);
        assert_eq!(accumulator.accumulate(-1.0, TouchPhase::Moved), -1);
    }

    #[test]
    fn phases_reset_or_finish_the_fractional_gesture() {
        let mut accumulator = ScrollLineAccumulator::default();
        assert_eq!(accumulator.accumulate(0.4, TouchPhase::Moved), 0);
        assert_eq!(accumulator.accumulate(0.3, TouchPhase::Started), 0);
        assert!((accumulator.fractional_lines - 0.3).abs() < f32::EPSILON);

        assert_eq!(accumulator.accumulate(0.2, TouchPhase::Ended), 0);
        assert_eq!(accumulator.fractional_lines, 0.0);
        assert_eq!(accumulator.accumulate(0.4, TouchPhase::Moved), 0);
        assert_eq!(accumulator.accumulate(1.0, TouchPhase::Cancelled), 0);
        assert_eq!(accumulator.fractional_lines, 0.0);
    }
}

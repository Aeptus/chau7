//! Terminal view: shows a `TerminalSession` grid. Painting lives in
//! `paint.rs`, images in `images.rs`; keyboard and IME input in `input.rs`,
//! mouse input in `mouse.rs` (child modules, so they reach the view's fields).

#[path = "input.rs"]
mod input;
#[path = "mouse.rs"]
mod mouse;

use std::ops::Range;
use std::time::{Duration, Instant};

use chau7_next_core::key_encoding;
use gpui::{
    App, Bounds, ClipboardItem, Context, CursorStyle, ElementInputHandler, Entity, EntityId,
    EventEmitter, FocusHandle, Focusable, Pixels, Point, Render, Task, Window, canvas, div,
    prelude::*, px,
};

use crate::settings::Settings;
use crate::terminal::images::{InlineImageMenu, InlineImageOp};
use crate::terminal::paint::{self, FrameInputs, Overlays};
use crate::terminal::session::{SessionEvent, TerminalSession};

pub use crate::terminal::paint::CellMetrics;

/// Events for the pane/workspace.
#[derive(Debug, Clone)]
pub enum TerminalViewEvent {
    Focused,
    /// Bytes typed or pasted by the user (used by broadcast mode).
    Input(Vec<u8>),
    /// A Cmd-clicked file to open in the tab's editor pane (1-based line).
    OpenInEditor {
        path: std::path::PathBuf,
        line: Option<usize>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct TerminalInsets {
    top: f32,
    left: f32,
    right: f32,
    bottom: f32,
}

fn terminal_content_insets(padding: f32) -> TerminalInsets {
    TerminalInsets {
        top: padding,
        left: padding,
        right: padding,
        bottom: 0.0,
    }
}

#[derive(Clone, PartialEq)]
struct MetricSettings {
    family: String,
    weight: i32,
    ligatures: bool,
    line_height: f32,
}
impl MetricSettings {
    fn new(settings: &Settings) -> Self {
        let a = &settings.appearance;
        Self {
            family: a.font_family.clone(),
            weight: a.font_weight,
            ligatures: a.ligatures && a.rendering.gpu_renderer,
            line_height: a.line_height,
        }
    }
}

pub struct TerminalView {
    pub session: Entity<TerminalSession>,
    focus_handle: FocusHandle,
    metrics: Option<CellMetrics>,
    metrics_settings: Option<MetricSettings>,
    font_size: f32,
    bounds: Option<Bounds<Pixels>>,
    selecting: bool,
    cursor_on: bool,
    cursor_focused: bool,
    marked_text: Option<String>,
    /// Button currently reported to the program (mouse reporting).
    reporting_button: Option<key_encoding::MouseButtonCode>,
    /// Search matches to highlight: (absolute line, column range), where the
    /// absolute line is the scrollback size plus the grid line, so matches
    /// follow scrolling and new output. `active_match` indexes the current one.
    pub search_matches: Vec<(i64, Range<usize>)>,
    pub active_match: Option<usize>,
    /// Images, line timestamps and blink state drawn over the grid.
    pub(crate) overlays: Overlays,
    /// Cmd is held over a link: show the pointing hand.
    pub(super) link_hover: bool,
    /// Dangerous command waiting for a decision, and the dialog's focus.
    guard_prompt: Option<guard::GuardPrompt>,
    guard_focus: FocusHandle,
    /// Dangerous-command tint state (`view/danger.rs`).
    danger: danger::DangerState,
    /// Keyboard and mouse state (`input.rs`, `mouse.rs`).
    input: input::InputState,
    refresh_interactive: bool,
    /// Stable GPUI identity for this view instance in the Services selection cache.
    selection_view_id: EntityId,
    /// NSWindow key for the owner-scoped macOS Services selection cache.
    selection_window: Option<usize>,
    winsize_state: chau7_next_core::session_restore::lifecycle::WinsizeNudgeState,
    /// Dropping/replacing these tasks cancels pending signals on hide/dispose.
    winsize_nudges: Vec<Task<()>>,
    _blink: Task<()>,
    _subscriptions: Vec<gpui::Subscription>,
}

mod danger;
mod guard;
use super::links;

impl EventEmitter<TerminalViewEvent> for TerminalView {}

impl Focusable for TerminalView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl TerminalView {
    pub fn new(
        session: Entity<TerminalSession>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        crate::memory_pressure::register_view(cx.entity().downgrade(), cx);
        let focus_handle = cx.focus_handle();
        let selection_view_id = cx.entity_id();
        let selection_window = crate::platform::drop_image::window_key(window);
        let font_size = Settings::get(cx).appearance.zoomed_font_size();
        let mut subscriptions = vec![cx.observe(&session, |_, _, cx| cx.notify())];
        subscriptions.push(cx.on_release(|this, cx| {
            this.overlays.release_cpu_frame(cx);
            if let Some(window) = this.selection_window {
                crate::platform::services::clear_selection(
                    window,
                    this.session.read(cx).id,
                    this.selection_view_id,
                );
            }
        }));
        subscriptions.push(cx.subscribe(&session, |this, _, event, cx| {
            if matches!(event, SessionEvent::MetadataChanged) {
                this.sync_winsize_nudges(None, cx);
            }
            if let SessionEvent::ClipboardStore(text) = event {
                crate::workspace::record_clipboard(text, cx);
                cx.write_to_clipboard(ClipboardItem::new_string(text.clone()));
            }
            if matches!(event, SessionEvent::Output) {
                this.cursor_on = true;
                this.overlays
                    .on_output(this.session.read(cx), Settings::get(cx));
                this.danger_note_output(cx);
            }
            // OSC 52 read: answer with the clipboard text (RBK-012).
            if matches!(event, SessionEvent::ClipboardLoad)
                && !this.session.read(cx).has_pending_clipboard_response()
            {
                let text = cx
                    .read_from_clipboard()
                    .and_then(|item| item.text())
                    .unwrap_or_default();
                this.session.read(cx).respond_clipboard(&text);
            }
        }));
        let focus_in = cx.on_focus_in(&focus_handle, window, |this, window, cx| {
            this.update_refresh_pacing(window, cx);
            // DECSET 1004: tell the program it gained focus.
            let session = this.session.read(cx);
            if session.mouse_mode() & key_encoding::mouse_mode::FOCUS != 0 {
                session.write(b"\x1b[I");
            }
            cx.emit(TerminalViewEvent::Focused);
            cx.notify();
        });
        subscriptions.push(focus_in);
        subscriptions.push(
            cx.on_focus_out(&focus_handle, window, |this, _, window, cx| {
                this.update_refresh_pacing(window, cx);
                let session = this.session.read(cx);
                if session.mouse_mode() & key_encoding::mouse_mode::FOCUS != 0 {
                    session.write(b"\x1b[O");
                }
                cx.notify()
            }),
        );
        subscriptions.push(cx.observe_window_activation(window, |this, window, cx| {
            this.update_refresh_pacing(window, cx);
            cx.notify();
        }));
        subscriptions.push(cx.observe_window_visibility(window, |this, _, window, cx| {
            this.update_refresh_pacing(window, cx);
            cx.notify();
        }));
        let blink = cx.spawn(async move |this, cx| {
            let mut interval = Duration::from_millis(500);
            loop {
                cx.background_executor().timer(interval).await;
                let next = this.update(cx, |this, cx| this.blink_tick(cx));
                match next {
                    Ok(next) => interval = next,
                    Err(_) => break,
                }
            }
        });
        let scrollback = chau7_next_core::memory_pressure::tracker_cap(
            Settings::get(cx).terminal.scrollback_lines,
        );
        let mut this = Self {
            session,
            focus_handle,
            metrics: None,
            metrics_settings: None,
            font_size,
            bounds: None,
            selecting: false,
            cursor_on: true,
            cursor_focused: false,
            marked_text: None,
            reporting_button: None,
            search_matches: Vec::new(),
            active_match: None,
            overlays: Overlays::default(),
            link_hover: false,
            guard_prompt: None,
            guard_focus: cx.focus_handle(),
            danger: danger::DangerState::new(scrollback),
            input: input::InputState::new(scrollback),
            refresh_interactive: false,
            selection_view_id,
            selection_window,
            winsize_state: Default::default(),
            winsize_nudges: Vec::new(),
            _blink: blink,
            _subscriptions: subscriptions,
        };
        this.update_refresh_pacing(window, cx);
        this.init_input(window, cx);
        this
    }

    /// The selection, for Chau7 Next's macOS Services extension.
    fn publish_selection(&self, window: &Window, cx: &App) {
        if !window.is_visible()
            || !window.is_window_active()
            || !self.focus_handle.is_focused(window)
        {
            return;
        }
        let Some(window_key) = crate::platform::drop_image::window_key(window) else {
            return;
        };
        let session = self.session.read(cx);
        crate::platform::services::set_selection(
            window_key,
            session.id,
            self.selection_view_id,
            session.selection_text(),
        );
    }

    pub(crate) fn memory_session_id(&self, cx: &App) -> u64 {
        self.session.read(cx).id
    }

    pub fn set_font_size(&mut self, size: f32, cx: &mut Context<Self>) {
        self.font_size = size.clamp(8.0, 72.0);
        self.metrics = None;
        cx.notify();
    }

    pub fn font_size(&self) -> f32 {
        self.font_size
    }

    fn update_refresh_pacing(&mut self, window: &Window, cx: &mut Context<Self>) {
        self.session
            .read(cx)
            .mark_restore_surface(window.is_visible());
        let focused = self.focus_handle.is_focused(window);
        self.cursor_on = cursor_on_after_focus_change(self.cursor_on, self.cursor_focused, focused);
        self.cursor_focused = focused;
        self.refresh_interactive = window.is_visible() && window.is_window_active() && focused;
        let window_key = crate::platform::drop_image::window_key(window);
        let (session_id, selection) = {
            let session = self.session.read(cx);
            (
                session.id,
                if self.refresh_interactive {
                    session.selection_text()
                } else {
                    None
                },
            )
        };
        if self.selection_window != window_key {
            if let Some(old_window) = self.selection_window {
                crate::platform::services::clear_selection(
                    old_window,
                    session_id,
                    self.selection_view_id,
                );
            }
            self.selection_window = window_key;
        }
        if let Some(window_key) = window_key {
            crate::platform::services::sync_focused_session(
                window_key,
                session_id,
                self.selection_view_id,
                self.refresh_interactive,
                selection,
            );
        }
        let rendering = &Settings::get(cx).appearance.rendering;
        self.session.read(cx).set_refresh_pacing(
            self.refresh_interactive,
            rendering.active_polling_rate_cap,
            rendering.inactive_view_max_fps,
        );
        self.sync_winsize_nudges(None, cx);
    }

    /// Resize signals are bounded and coalesced. The syscall runs off UI and
    /// targets only this owned view's foreground process group.
    fn sync_winsize_nudges(&mut self, dimensions: Option<(u16, u16)>, cx: &mut Context<Self>) {
        use chau7_next_core::session_restore::lifecycle::{
            WINSIZE_NUDGE_DELAYS, WinsizeNudgeDecision, protects_terminal_ui,
        };
        let session = self.session.read(cx);
        let visible = session.restore_surface_visible();
        // Background blink ticks only revoke pending work. They need neither
        // terminal locks nor repeated provider-name allocations.
        if !visible {
            self.winsize_state.update(false, false, dimensions);
            self.winsize_nudges.clear();
            return;
        }
        let shell = session.shell();
        let display = shell.ai_display_app_name();
        let hosts_tui = session.with_terminal(|term| term.is_alternate_screen_active())
            || protects_terminal_ui(
                &[
                    shell.live_agent_name(),
                    shell.active_app(),
                    display.as_deref(),
                    shell.ai_provider(),
                ],
                session.is_ai_running(),
                session.has_pending_restore_resume(),
                session.status(),
            );
        match self.winsize_state.update(visible, hosts_tui, dimensions) {
            WinsizeNudgeDecision::Keep => {}
            WinsizeNudgeDecision::Cancel => self.winsize_nudges.clear(),
            WinsizeNudgeDecision::Schedule => {
                self.winsize_nudges.clear();
                for delay in WINSIZE_NUDGE_DELAYS {
                    self.winsize_nudges.push(cx.spawn(async move |this, cx| {
                        cx.background_executor().timer(delay).await;
                        let Ok(Some(term)) = this.update(cx, |this, cx| {
                            let session = this.session.read(cx);
                            (session.restore_surface_visible() && session.exited.is_none())
                                .then(|| session.remote_terminal())
                        }) else {
                            return;
                        };
                        cx.background_spawn(async move {
                            term.read().nudge_winsize();
                        })
                        .await;
                    }));
                }
            }
        }
    }

    /// Existing live frames repaint in place. Initial/explicit reveals refresh
    /// the authoritative grid and await the actual next paint for resume input.
    pub(crate) fn reveal_surface(
        &mut self,
        trigger: chau7_next_core::session_restore::lifecycle::RevealTrigger,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        use chau7_next_core::session_restore::lifecycle::{RevealAction, reveal_action};
        self.update_refresh_pacing(window, cx);
        let session = self.session.clone();
        let visible = session.read(cx).restore_surface_visible();
        if !visible {
            return;
        }
        session.read(cx).set_render_suspended(false);
        let action = reveal_action(
            trigger,
            visible,
            true,
            session.read(cx).surface_has_live_frame(),
        );
        if matches!(action, RevealAction::Authoritative { .. }) {
            session.update(cx, |session, cx| {
                session.request_surface_frame();
                session.refresh(cx);
            });
        }
        cx.notify();
    }

    /// Cursor blink (`handleBlinkTick`): toggles every blink interval (500 ms
    /// unless `terminal.cursorBlinkRate` is set), solid for 1 s after output
    /// or typing, paused while the tab is hidden. Also suspends rendering of
    /// hidden tabs when Suspend Background Rendering is on. Returns the next
    /// interval.
    fn blink_tick(&mut self, cx: &mut Context<Self>) -> Duration {
        self.sync_winsize_nudges(None, cx);
        let mut wake =
            chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::wakeup(
                "cursor_blink_timer",
                self.session.read(cx).profiling_phase(),
                chau7_next_core::work_profiler::Queue::Main,
            ));
        let visible = self.session.read(cx).restore_surface_visible();
        wake.idle(!visible || !self.overlays.recently_painted(Duration::from_secs(1)));
        let appearance = &Settings::get(cx).appearance;
        let interval = appearance.blink_interval();
        let rendering = appearance.rendering.clone();
        let delay = if rendering.suspend_delay_secs.is_finite() {
            Duration::from_secs_f32(rendering.suspend_delay_secs.max(0.0))
        } else {
            Duration::from_secs(5)
        };
        let prewarm = self.session.read(cx).surface_prewarm_remaining();
        let suspend = prewarm.is_none()
            && chau7_next_core::session_restore::lifecycle::suspend_hidden_surface(
                visible,
                self.session.read(cx).surface_hidden_for(),
                rendering.suspend_background,
                delay,
            );
        let session = self.session.read(cx);
        session.set_refresh_pacing(
            self.refresh_interactive && visible,
            rendering.active_polling_rate_cap,
            rendering.inactive_view_max_fps,
        );
        if session.is_render_suspended() != suspend {
            session.set_render_suspended(suspend);
        }
        if !visible {
            if let Some(remaining) = prewarm {
                return interval.min(remaining.max(Duration::from_millis(1)));
            }
            // Wake at the configured suspension deadline rather than adding an
            // arbitrary cursor-blink interval to the actual hidden duration.
            if rendering.suspend_background
                && !suspend
                && let Some(age) = session.surface_hidden_for()
            {
                return interval.min(delay.saturating_sub(age).max(Duration::from_millis(1)));
            }
            return interval;
        }
        let blink_hold = if appearance.cursor_blink {
            self.overlays.blink_hold()
        } else {
            false
        };
        let transition = cursor_blink_transition(
            self.cursor_on,
            appearance.cursor_blink,
            self.cursor_focused,
            blink_hold,
        );
        if transition.cursor_on != self.cursor_on {
            self.cursor_on = transition.cursor_on;
            if transition.notify {
                cx.notify();
            }
        }
        interval
    }

    /// Build an immutable, CPU-rendered snapshot for the Print command. The
    /// snapshot uses this view's real overlays and last laid-out viewport but
    /// does not submit a frame to or replace the on-screen CPU cache.
    pub(crate) fn print_snapshot(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<paint::CpuBitmap> {
        let settings = Settings::get(cx).clone();
        let metrics = self.metrics(window, cx);
        let focused = self.focus_handle.is_focused(window);
        let mut inputs = FrameInputs::new(
            &settings,
            metrics.clone(),
            focused,
            self.cursor_on,
            self.search_matches.clone(),
            self.active_match,
            self.marked_text.clone(),
        );
        inputs.local_echo = self.local_echo_cells();

        let snapshot_size = self.bounds.map(|bounds| bounds.size);
        let state = {
            let session_entity = self.session.clone();
            let session = session_entity.read(cx);
            inputs.danger_rows = self.danger_rows_for_snapshot(session, &settings);
            let size = snapshot_size.unwrap_or_else(|| {
                let gutter = if settings.appearance.display.line_timestamps {
                    let chars = chau7_next_core::line_timestamps::gutter_chars(
                        &settings.appearance.display.timestamp_format,
                    );
                    let label_cell =
                        metrics.cell_width * (9.0 / f32::from(metrics.font_size).max(1.0));
                    label_cell * chars as f32 + px(6.0)
                } else {
                    px(0.0)
                };
                gpui::size(
                    metrics.cell_width * f32::from(session.grid.cols) + gutter,
                    metrics.line_height * f32::from(session.grid.rows),
                )
            });
            let state = paint::snapshot_state(session, inputs, &mut self.overlays);
            (state, size)
        };
        paint::render_snapshot(state.0, state.1, window, cx)
    }

    fn metrics(&mut self, window: &mut Window, cx: &App) -> CellMetrics {
        let settings = Settings::get(cx);
        let key = MetricSettings::new(settings);
        if self.metrics.is_none() || self.metrics_settings.as_ref() != Some(&key) {
            self.metrics_settings = Some(key);
            self.metrics = Some(CellMetrics::measure(settings, self.font_size, window));
        }
        self.metrics.clone().unwrap()
    }

    /// Grid cell under a window position (clamped to the grid).
    fn cell_at(&self, position: Point<Pixels>, cx: &App) -> Option<(i32, i32)> {
        let bounds = self.bounds?;
        let metrics = self.metrics.as_ref()?;
        let grid = &self.session.read(cx).grid;
        let local = position - bounds.origin;
        let col = (local.x / metrics.cell_width).floor() as i32;
        let row = (local.y / metrics.line_height).floor() as i32;
        let col = col.clamp(0, grid.cols.saturating_sub(1) as i32);
        let row = row.clamp(0, grid.rows.saturating_sub(1) as i32);
        Some((col, row))
    }

    /// Convert a viewport row into the terminal's grid line (scrollback aware).
    fn grid_line(&self, row: i32, cx: &App) -> i32 {
        row - self.session.read(cx).grid.display_offset as i32
    }

    fn write(&mut self, bytes: &[u8], cx: &mut Context<Self>) {
        self.admit_steps(
            vec![chau7_next_core::remote::key_input::InputStep {
                bytes: bytes.to_vec(),
                delay_ms: 0,
            }],
            true,
            cx,
        );
    }

    /// User/automation input, including broadcasts, uses the same admission.
    pub fn write_without_broadcast(&mut self, bytes: &[u8], cx: &mut Context<Self>) -> bool {
        self.send_guarded_steps(
            vec![chau7_next_core::remote::key_input::InputStep {
                bytes: bytes.to_vec(),
                delay_ms: 0,
            }],
            cx,
        )
    }

    fn write_admitted(&mut self, bytes: &[u8], broadcast: bool, cx: &mut Context<Self>) {
        let dispatch_started = Instant::now();
        let session = self.session.read(cx);
        session.scroll_to_bottom();
        session.selection_clear();
        crate::platform::services::clear_selection_for_session(session.id);
        session.write_input(bytes);
        session.record_input_dispatch(dispatch_started);
        self.cursor_on = true;
        self.note_user_input(bytes, cx);
        if broadcast {
            cx.emit(TerminalViewEvent::Input(bytes.to_vec()));
        }
    }

    /// Cmd+C: copy the selection, or send Ctrl-C (interrupt) when nothing
    /// is selected (`RustTerminalView.copy`).
    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        window.focus(&self.focus_handle, cx);
    }
}

/// Inline image context menu (`InlineImageView`: Copy Image, Save Image...,
/// Open in Preview).
impl TerminalView {
    fn show_image_menu(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(bounds) = self.bounds else {
            return;
        };
        let Some(image) = self.overlays.images.hit(position - bounds.origin) else {
            return;
        };
        cx.stop_propagation();
        let op = |op| Box::new(InlineImageMenu { image, op }) as Box<dyn gpui::Action>;
        gpui_kit::component::native_menu::NativeMenu::new()
            .menu(crate::l10n::tr("Copy Image"), op(InlineImageOp::Copy))
            .menu(crate::l10n::tr("Save Image..."), op(InlineImageOp::Save))
            .separator()
            .menu(
                crate::l10n::tr("Open in Preview"),
                op(InlineImageOp::OpenInPreview),
            )
            .show(position, window, cx);
    }

    fn on_image_menu(
        &mut self,
        action: &InlineImageMenu,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(image) = self.overlays.images.get(action.image) else {
            return;
        };
        let name = image.file_name();
        let Some(png) = image.png() else {
            log::warn!("inline image: could not encode PNG");
            return;
        };
        match action.op {
            InlineImageOp::Copy => {
                let image = gpui::Image::from_bytes(gpui::ImageFormat::Png, png);
                cx.write_to_clipboard(ClipboardItem::new_image(&image));
            }
            InlineImageOp::Save => {
                let home = cx
                    .global::<crate::workspace::AppData>()
                    .root
                    .home()
                    .to_path_buf();
                let answer = cx.prompt_for_new_path(&home, Some(&png_name(&name)));
                cx.spawn(async move |_, _| {
                    if let Ok(Ok(Some(path))) = answer.await
                        && let Err(err) = std::fs::write(&path, &png)
                    {
                        log::error!("save image {}: {err}", path.display());
                    }
                })
                .detach();
            }
            InlineImageOp::OpenInPreview => {
                let path = std::env::temp_dir().join(png_name(&name));
                match std::fs::write(&path, &png) {
                    Ok(()) => cx.open_with_system(&path),
                    Err(err) => log::error!("open image {}: {err}", path.display()),
                }
            }
        }
    }
}

/// Images are saved as PNG: keep the name, with a `.png` extension.
fn png_name(name: &str) -> String {
    let stem = name
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .filter(|s| !s.is_empty())
        .unwrap_or(name);
    format!("{stem}.png")
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.focus_guard(window, cx);
        self.update_refresh_pacing(window, cx);
        if window.is_visible() {
            self.session.read(cx).mark_memory_visible(cx);
        }
        let _build =
            chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
                "view_build",
                "layout",
                self.session.read(cx).profiling_phase(),
                "terminal_view",
                chau7_next_core::work_profiler::Queue::Main,
            ));
        let metrics = self.metrics(window, cx);
        let guard_overlay = self.render_guard(cx);
        let settings = Settings::get(cx);
        let focused = self.focus_handle.is_focused(window);
        let view = cx.entity();
        let session = self.session.clone();
        let focus_handle = self.focus_handle.clone();
        let insets = terminal_content_insets(settings.appearance.padding);
        let inputs = FrameInputs::new(
            settings,
            metrics.clone(),
            focused,
            self.cursor_on,
            self.search_matches.clone(),
            self.active_match,
            self.marked_text.clone(),
        );
        let background = inputs.background;
        // Line timestamps get their own right-hand gutter (9 pt labels), so
        // they never cover text (`TimestampOverlayView`, TRM-058).
        let gutter = if settings.appearance.display.line_timestamps {
            let chars = chau7_next_core::line_timestamps::gutter_chars(
                &settings.appearance.display.timestamp_format,
            );
            let label_cell = metrics.cell_width * (9.0 / f32::from(metrics.font_size).max(1.0));
            label_cell * chars as f32 + px(6.0)
        } else {
            px(0.0)
        };
        let mut inputs = inputs;
        inputs.local_echo = self.local_echo_cells();

        div()
            .id("terminal")
            .relative()
            .key_context("Terminal")
            .track_focus(&self.focus_handle)
            .size_full()
            .bg(background)
            .cursor(if self.link_hover {
                CursorStyle::PointingHand
            } else {
                CursorStyle::IBeam
            })
            .map(|d| Self::input_listeners(d, cx))
            .map(|d| Self::mouse_listeners(d, cx))
            .on_action(cx.listener(Self::on_image_menu))
            .pt(px(insets.top))
            .pl(px(insets.left))
            .pr(px(insets.right))
            .pb(px(insets.bottom))
            .child(
                canvas(
                    {
                        let view = view.clone();
                        move |bounds, _window, cx| {
                            // Resize the PTY to fit, then snapshot.
                            let dimensions =
                                chau7_next_core::session_restore::lifecycle::surface_dimensions(
                                    f32::from(bounds.size.width - gutter),
                                    f32::from(bounds.size.height),
                                    f32::from(metrics.cell_width),
                                    f32::from(metrics.line_height),
                                );
                            if let Some((cols, rows)) = dimensions {
                                session.update(cx, |s, _| s.resize(cols, rows));
                            }
                            // A busy resize may still be pending. Observe applied
                            // grid dimensions so its later successful retry re-arms
                            // the post-resize signals instead of caching a request.
                            let actual_dimensions = dimensions.map(|_| {
                                let session = session.read(cx);
                                (session.grid.cols, session.grid.rows)
                            });
                            // A painted tab is visible: never suspended.
                            session.read(cx).set_render_suspended(false);
                            view.update(cx, |v, cx| {
                                v.sync_winsize_nudges(actual_dimensions, cx);
                                v.bounds = Some(bounds);
                                let mut inputs = inputs;
                                let s = session.read(cx);
                                inputs.danger_rows = v.danger_rows_for_frame(s, Settings::get(cx));
                                paint::prepaint(s, inputs, &mut v.overlays)
                            })
                        }
                    },
                    move |bounds, state, window, cx| {
                        window.handle_input(
                            &focus_handle,
                            ElementInputHandler::new(bounds, view.clone()),
                            cx,
                        );
                        if paint::paint_grid(bounds, state, window, cx) {
                            let session = view.read(cx).session.read(cx);
                            session.mark_frame_paint_completed();
                            session.mark_restore_presented();
                        }
                    },
                )
                .size_full(),
            )
            .children(guard_overlay)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CursorBlinkTransition {
    cursor_on: bool,
    notify: bool,
}

fn cursor_blink_transition(
    cursor_on: bool,
    blink_enabled: bool,
    focused: bool,
    hold: bool,
) -> CursorBlinkTransition {
    if !blink_enabled {
        return CursorBlinkTransition {
            cursor_on,
            notify: false,
        };
    }

    let next = hold || !cursor_on;
    CursorBlinkTransition {
        cursor_on: next,
        notify: focused && next != cursor_on,
    }
}

fn cursor_on_after_focus_change(cursor_on: bool, was_focused: bool, focused: bool) -> bool {
    if focused && !was_focused {
        true
    } else {
        cursor_on
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn terminal_content_insets_remove_bottom_gap_without_clipping_a_grid_row() {
        let insets = super::terminal_content_insets(4.0);
        assert_eq!(
            insets,
            super::TerminalInsets {
                top: 4.0,
                left: 4.0,
                right: 4.0,
                bottom: 0.0,
            }
        );

        let content_height = 500.0 - insets.top - insets.bottom;
        let (_, rows) = chau7_next_core::session_restore::lifecycle::surface_dimensions(
            800.0 - insets.left - insets.right,
            content_height,
            8.0,
            17.0,
        )
        .unwrap();
        let used_height = f32::from(rows) * 17.0;
        assert!(used_height <= content_height);
        assert!(content_height - used_height < 17.0);
    }

    #[test]
    fn focused_cursor_blink_changes_paint_and_requests_redraw() {
        let transition = super::cursor_blink_transition(true, true, true, false);
        assert_eq!(
            transition,
            super::CursorBlinkTransition {
                cursor_on: false,
                notify: true,
            }
        );
    }

    #[test]
    fn unfocused_cursor_blink_advances_without_requesting_redraw() {
        let transition = super::cursor_blink_transition(true, true, false, false);
        assert_eq!(
            transition,
            super::CursorBlinkTransition {
                cursor_on: false,
                notify: false,
            }
        );
    }

    #[test]
    fn disabled_blink_keeps_phase_without_redraw_even_when_held() {
        let transition = super::cursor_blink_transition(false, false, true, true);
        assert_eq!(
            transition,
            super::CursorBlinkTransition {
                cursor_on: false,
                notify: false,
            }
        );
    }

    #[test]
    fn blink_hold_restores_solid_cursor_and_notifies_only_when_focused() {
        assert_eq!(
            super::cursor_blink_transition(false, true, true, true),
            super::CursorBlinkTransition {
                cursor_on: true,
                notify: true,
            }
        );
        assert_eq!(
            super::cursor_blink_transition(false, true, false, true),
            super::CursorBlinkTransition {
                cursor_on: true,
                notify: false,
            }
        );
    }

    #[test]
    fn focus_regain_restores_visible_cursor_phase() {
        assert!(super::cursor_on_after_focus_change(false, false, true));
        assert!(!super::cursor_on_after_focus_change(false, true, false));
        assert!(!super::cursor_on_after_focus_change(false, true, true));
    }

    #[test]
    fn cursor_redraw_gate_is_wired_to_the_paint_focus_predicate() {
        let source = include_str!("view.rs");
        let pacing = source
            .split("    fn update_refresh_pacing(")
            .nth(1)
            .unwrap()
            .split("    /// Resize signals")
            .next()
            .unwrap();
        assert!(pacing.contains("let focused = self.focus_handle.is_focused(window);"));
        assert!(pacing.contains("self.cursor_focused = focused;"));
        assert!(pacing.contains("&& focused;"));

        let blink = source
            .split("    fn blink_tick(")
            .nth(1)
            .unwrap()
            .split("    fn metrics(")
            .next()
            .unwrap();
        assert!(blink.contains("self.cursor_focused"));
        assert!(blink.contains("cursor_blink_transition("));
        assert!(blink.contains("if transition.notify"));

        let paint = include_str!("paint.rs");
        assert!(paint.contains("show_cursor: cursor_on || !focused || !appearance.cursor_blink"));
    }

    #[test]
    fn collapsed_surface_keeps_actual_restored_grid_and_scrollback() {
        let terminal = chau7_terminal::Chau7Terminal::new_headless(80, 24).unwrap();
        for line in 0..60 {
            terminal.inject_output(format!("restore-{line:02}\r\n").as_bytes());
        }
        let before = terminal.full_buffer_ansi_text();
        for (width, height) in [
            (0.0, 0.0),
            (8.0, 384.0),
            (640.0, 16.0),
            (f32::NAN, 384.0),
            (640.0, f32::INFINITY),
        ] {
            if let Some((cols, rows)) =
                chau7_next_core::session_restore::lifecycle::surface_dimensions(
                    width, height, 8.0, 16.0,
                )
            {
                terminal.resize(cols, rows);
            }
            let grid = terminal.grid_copy();
            assert_eq!((grid.cols, grid.rows), (80, 24));
            assert_eq!(terminal.full_buffer_ansi_text(), before);
        }
        let (cols, rows) =
            chau7_next_core::session_restore::lifecycle::surface_dimensions(160.0, 64.0, 8.0, 16.0)
                .unwrap();
        terminal.resize(cols, rows);
        assert_eq!(
            (terminal.grid_copy().cols, terminal.grid_copy().rows),
            (20, 4)
        );
        assert!(terminal.full_buffer_text().contains("restore-59"));
    }
    #[test]
    fn nudge_and_geometry_policies_are_wired_into_actual_view_lifecycle() {
        let source = include_str!("view.rs");
        let resize = source
            .split("// Resize the PTY to fit, then snapshot.")
            .nth(1)
            .unwrap()
            .split("// A painted tab is visible")
            .next()
            .unwrap();
        assert!(resize.contains("surface_dimensions("));
        assert!(resize.contains("if let Some((cols, rows)) = dimensions"));
        assert!(!resize.contains(".max(1.0) as u16"));
        assert!(resize.contains("let actual_dimensions = dimensions.map"));
        assert!(resize.contains("(session.grid.cols, session.grid.rows)"));
        let nudges = source
            .split("    fn sync_winsize_nudges(")
            .nth(1)
            .unwrap()
            .split("    /// Existing live frames")
            .next()
            .unwrap();
        assert!(nudges.contains("session.has_pending_restore_resume()"));
        assert!(nudges.contains("session.restore_surface_visible() && session.exited.is_none()"));
        assert!(nudges.contains("self.winsize_nudges.clear()"));
        assert!(nudges.contains("cx.background_spawn("));
        assert!(nudges.contains("term.read().nudge_winsize()"));
    }
    #[test]
    fn switching_renderer_refreshes_existing_terminal_font_metrics() {
        let mut settings = crate::settings::Settings::default();
        settings.appearance.ligatures = true;
        let before = super::MetricSettings::new(&settings);
        settings.appearance.rendering.gpu_renderer = false;
        assert!(before != super::MetricSettings::new(&settings));
        let cpu = super::MetricSettings::new(&settings);
        settings.appearance.ligatures = false;
        assert!(cpu == super::MetricSettings::new(&settings));
        settings.appearance.line_height += 0.1;
        assert!(cpu != super::MetricSettings::new(&settings));
    }
    #[test]
    fn saved_images_are_png() {
        assert_eq!(super::png_name("cat.jpg"), "cat.png");
        assert_eq!(super::png_name("image.png"), "image.png");
        assert_eq!(super::png_name("noext"), "noext.png");
    }
}

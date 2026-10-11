//! Session timeline (`TimelineScrubberView.swift`): record a tab, then open
//! the recording on a scrubber. The Swift scrubber was never wired into a
//! window; Chau7 Next opens it from View > Session Timeline.
//!
//! The panel records the focused tab (Record / Stop), lists the finished
//! recordings, and shows one on a timeline: the commands as green (exit 0),
//! red (failed) or blue (running) blocks, a density mini-map, a draggable
//! handle with the elapsed time, play and pause with 0.5x to 4x speed, a
//! tooltip for the block under the pointer and the terminal text at the
//! handle. A recording being made cannot be opened until it is stopped.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use chau7_next_core::session_recorder::{Timeline, TimelineBlock, blocks_from_frames, replay_text};
use chau7_next_core::session_recording::{RecordedFrame, SessionRecordingMeta};
use gpui::{
    AccessibleAction, AnimationExt, Bounds, Context, Div, MouseButton, MouseDownEvent,
    MouseMoveEvent, Pixels, Role, SharedString, Stateful, Task, Window, canvas, div, prelude::*,
    px, relative,
};
use uuid::Uuid;

use super::Workspace;
use super::panel::PanelKind;
use crate::actions::ShowSessionTimeline;
use crate::history::recorder;
use crate::theme::Chrome;

/// Replay speeds (`[0.5, 1.0, 2.0, 4.0]`).
const SPEEDS: [f64; 4] = [0.5, 1.0, 2.0, 4.0];
/// Lines of terminal text shown under the scrubber.
const REPLAY_LINES: usize = 12;

/// A recording opened on the scrubber.
struct OpenRecording {
    meta: SessionRecordingMeta,
    frames: Vec<RecordedFrame>,
    blocks: Vec<TimelineBlock>,
    timeline: Timeline,
    /// Handle position, 0 to 1.
    position: f64,
    playing: bool,
    speed: f64,
    hovered: Option<usize>,
}

pub(super) struct TimelinePanel {
    list: Vec<SessionRecordingMeta>,
    open: Option<OpenRecording>,
    /// Where the track was last painted, for pointer positions.
    track: Rc<Cell<Bounds<Pixels>>>,
    play_task: Option<Task<()>>,
    message: Option<String>,
}

pub(super) fn register_timeline_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(
        cx.listener(|this, _: &ShowSessionTimeline, window, cx| this.toggle_timeline(window, cx)),
    )
}

fn green() -> gpui::Hsla {
    gpui::hsla(0.36, 0.65, 0.45, 1.0)
}
fn red() -> gpui::Hsla {
    gpui::hsla(0.0, 0.75, 0.55, 1.0)
}
fn blue() -> gpui::Hsla {
    gpui::hsla(0.6, 0.8, 0.6, 1.0)
}

fn block_color(block: &TimelineBlock) -> gpui::Hsla {
    if block.is_running() {
        blue()
    } else if block.is_success() {
        green()
    } else {
        red()
    }
}

/// Accessibility step of the scrubber (`accessibilityAdjustableAction`).
const A11Y_STEP: f64 = 0.05;

/// `timeline.commandStatus`: "Command: x, succeeded".
fn block_a11y_label(block: &TimelineBlock) -> String {
    format!("Command: {}, {}", block.command, block_status(block))
}

/// `blockStatusLabel`.
fn block_status(block: &TimelineBlock) -> String {
    if block.is_running() {
        "running".into()
    } else if block.is_success() {
        "succeeded".into()
    } else {
        format!("failed with exit code {}", block.exit_code.unwrap_or(-1))
    }
}

fn chip(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    chrome: Chrome,
) -> Stateful<Div> {
    let label: SharedString = label.into();
    div()
        .id(id)
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .bg(chrome.tab_bg)
        .text_color(chrome.text)
        .cursor_pointer()
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .role(Role::Button)
        .aria_label(label.clone())
        .child(label)
}

impl Workspace {
    fn toggle_timeline(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.timeline_panel.take().is_some() {
            self.focus_selected(window, cx);
            cx.notify();
            return;
        }
        self.close_other_panels(Some(PanelKind::Timeline), cx);
        self.panel_generation += 1;
        self.timeline_panel = Some(TimelinePanel {
            list: recorder::list(),
            open: None,
            track: Rc::new(Cell::new(Bounds::default())),
            play_task: None,
            message: None,
        });
        cx.notify();
    }

    /// Record the focused tab, or stop the running recording.
    fn timeline_toggle_recording(&mut self, cx: &mut Context<Self>) {
        let Some(panel) = self.timeline_panel.as_mut() else {
            return;
        };
        if recorder::recording_session().is_some() {
            let meta = recorder::stop();
            panel.list = recorder::list();
            panel.message = meta.map(|m| {
                format!(
                    "Saved '{}' ({} frames, {})",
                    m.title,
                    m.frame_count,
                    crate::history::format_bytes(m.total_bytes.max(0) as u64)
                )
            });
            cx.notify();
            return;
        }
        let Some(tab) = self.state.selected() else {
            return;
        };
        let Some(session) = self
            .entries
            .get(&tab)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
        else {
            return;
        };
        let title = self.tab_title(tab, cx);
        let (id, directory) = {
            let s = session.read(cx);
            (
                s.id,
                s.cwd.as_ref().map(|p| p.to_string_lossy().to_string()),
            )
        };
        recorder::start(id, &title, directory);
        if let Some(panel) = self.timeline_panel.as_mut() {
            panel.message = Some(format!("Recording '{title}'"));
        }
        cx.notify();
    }

    fn timeline_open(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let Some(panel) = self.timeline_panel.as_mut() else {
            return;
        };
        let Some(meta) = panel.list.iter().find(|m| m.id == id).cloned() else {
            return;
        };
        let frames = recorder::load_frames(id);
        if frames.is_empty() {
            panel.message = Some("This recording has no frames.".into());
            cx.notify();
            return;
        }
        let start = frames.first().map_or(meta.start_time, |f| f.timestamp);
        let end = frames
            .last()
            .map_or(start, |f| f.timestamp)
            .max(meta.end_time.unwrap_or(start));
        let blocks = blocks_from_frames(&frames);
        panel.play_task = None;
        panel.message = None;
        panel.open = Some(OpenRecording {
            meta,
            frames,
            blocks,
            timeline: Timeline { start, end },
            position: 0.0,
            playing: false,
            speed: 1.0,
            hovered: None,
        });
        cx.notify();
    }

    fn timeline_delete(&mut self, id: Uuid, cx: &mut Context<Self>) {
        recorder::delete(id);
        if let Some(panel) = self.timeline_panel.as_mut() {
            panel.list = recorder::list();
            if panel.open.as_ref().is_some_and(|o| o.meta.id == id) {
                panel.open = None;
                panel.play_task = None;
            }
        }
        cx.notify();
    }

    /// Move the handle to a pointer position over the track.
    fn timeline_scrub(&mut self, x: Pixels, cx: &mut Context<Self>) {
        let Some(panel) = self.timeline_panel.as_mut() else {
            return;
        };
        let bounds = panel.track.get();
        if bounds.size.width <= px(0.0) {
            return;
        }
        let fraction = f64::from((x - bounds.origin.x) / bounds.size.width).clamp(0.0, 1.0);
        if let Some(open) = panel.open.as_mut() {
            open.position = fraction;
        }
        cx.notify();
    }

    /// Move the handle by `delta` (a fraction of the session), like the
    /// VoiceOver increment and decrement of the Swift scrubber.
    fn timeline_step(&mut self, delta: f64, cx: &mut Context<Self>) {
        if let Some(open) = self.timeline_panel.as_mut().and_then(|p| p.open.as_mut()) {
            open.position = (open.position + delta).clamp(0.0, 1.0);
            cx.notify();
        }
    }

    fn timeline_toggle_play(&mut self, cx: &mut Context<Self>) {
        let Some(panel) = self.timeline_panel.as_mut() else {
            return;
        };
        let Some(open) = panel.open.as_mut() else {
            return;
        };
        if open.playing {
            open.playing = false;
            panel.play_task = None;
            cx.notify();
            return;
        }
        if open.position >= 1.0 {
            open.position = 0.0;
        }
        open.playing = true;
        panel.play_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(50))
                    .await;
                let keep_going = this
                    .update(cx, |this, cx| this.timeline_advance(0.05, cx))
                    .unwrap_or(false);
                if !keep_going {
                    break;
                }
            }
        }));
        cx.notify();
    }

    /// One playback step of `seconds` real time; false when it ended.
    fn timeline_advance(&mut self, seconds: f64, cx: &mut Context<Self>) -> bool {
        let Some(open) = self
            .timeline_panel
            .as_mut()
            .and_then(|p| p.open.as_mut())
            .filter(|o| o.playing)
        else {
            return false;
        };
        open.position += seconds * open.speed / open.timeline.total_duration();
        let more = open.position < 1.0;
        if !more {
            open.position = 1.0;
            open.playing = false;
        }
        cx.notify();
        more
    }

    pub(super) fn render_timeline(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let panel = self.timeline_panel.as_ref()?;
        let recording = recorder::recording_session().is_some();
        let header = div()
            .flex()
            .items_center()
            .gap_2()
            .child(
                div()
                    .flex_1()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(crate::l10n::tr("Session Timeline"))
                    .when(recording, |d| {
                        // ANL-005: the dot pulses while recording.
                        d.child(
                            div()
                                .id("timeline-recording-dot")
                                .role(Role::Label)
                                .aria_label("Recording active")
                                .size(px(8.0))
                                .rounded_full()
                                .bg(red())
                                .with_animation(
                                    "timeline-recording-pulse",
                                    gpui::Animation::new(Duration::from_millis(1600)).repeat(),
                                    |el, delta| {
                                        // 0.8 -> 0.3 -> 0.8 (easeInOut, autoreverses).
                                        let wave = (delta * std::f32::consts::TAU).cos();
                                        el.opacity(0.55 + 0.25 * wave)
                                    },
                                ),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(red())
                                .child(crate::l10n::tr("Recording")),
                        )
                    }),
            )
            .child(
                chip(
                    "timeline-record",
                    if recording {
                        "Stop Recording"
                    } else {
                        "Record This Tab"
                    },
                    chrome,
                )
                .on_click(cx.listener(|this, _, _, cx| this.timeline_toggle_recording(cx))),
            )
            .child(
                chip("timeline-close", "Close", chrome)
                    .on_click(cx.listener(|this, _, window, cx| this.toggle_timeline(window, cx))),
            );

        let list: Vec<gpui::AnyElement> =
            panel
                .list
                .iter()
                .enumerate()
                .map(|(index, meta)| {
                    let id = meta.id;
                    let opened = panel.open.as_ref().is_some_and(|o| o.meta.id == id);
                    let when = meta
                        .start_time
                        .with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M")
                        .to_string();
                    div()
                        .id(("timeline-row", index))
                        .flex()
                        .items_center()
                        .gap_2()
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .bg(if opened {
                            chrome.accent.opacity(0.18)
                        } else {
                            chrome.tab_bg
                        })
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(
                                    div()
                                        .text_sm()
                                        .overflow_hidden()
                                        .whitespace_nowrap()
                                        .text_ellipsis()
                                        .child(meta.title.clone()),
                                )
                                .child(div().text_xs().text_color(chrome.text_muted).child(
                                    format!(
                                        "{when} \u{b7} {} frames \u{b7} {}",
                                        meta.frame_count,
                                        crate::history::format_bytes(meta.total_bytes.max(0) as u64)
                                    ),
                                )),
                        )
                        .child(chip(("timeline-open", index), "Open", chrome).on_click(
                            cx.listener(move |this, _, _, cx| this.timeline_open(id, cx)),
                        ))
                        .child(chip(("timeline-delete", index), "Delete", chrome).on_click(
                            cx.listener(move |this, _, _, cx| this.timeline_delete(id, cx)),
                        ))
                        .into_any_element()
                })
                .collect();

        let scrubber = panel
            .open
            .as_ref()
            .map(|open| self.render_scrubber(open, panel.track.clone(), chrome, cx));

        let content =
            div()
                .flex()
                .flex_col()
                .gap_2()
                .px(px(10.0))
                .pb(px(10.0))
                .key_context("Timeline")
                .child(header)
                .when_some(panel.message.clone(), |d, m| {
                    d.child(div().text_xs().text_color(chrome.text_muted).child(m))
                })
                .when(list.is_empty(), |d| {
                    d.child(
                        div().py_2().text_xs().text_color(chrome.text_muted).child(
                            "No recordings yet. Record This Tab, run some commands, then stop.",
                        ),
                    )
                })
                .when(!list.is_empty(), |d| {
                    d.child(
                        div()
                            .id("timeline-list")
                            .max_h(px(130.0))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .children(list),
                    )
                })
                .children(scrubber)
                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                    match event.keystroke.key.as_str() {
                        "escape" => this.toggle_timeline(window, cx),
                        "space" => this.timeline_toggle_play(cx),
                        // ANL-007: the adjustable scrubber moves by 5%.
                        "left" => this.timeline_step(-A11Y_STEP, cx),
                        "right" => this.timeline_step(A11Y_STEP, cx),
                        _ => {}
                    }
                }))
                .into_any_element();
        Some(self.floating_panel(PanelKind::Timeline, 640.0, chrome, content, cx))
    }

    fn render_scrubber(
        &self,
        open: &OpenRecording,
        track_cell: Rc<Cell<Bounds<Pixels>>>,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let now = chrono::Utc::now();
        let timeline = open.timeline;
        let density = timeline.density(&open.blocks, 120, now);
        let max_density = density.iter().copied().max().unwrap_or(1).max(1);

        // Mini-map: density shading, blocks, viewport box.
        let mini = div()
            .relative()
            .h(px(8.0))
            .w_full()
            .rounded(px(2.0))
            .bg(chrome.border.opacity(0.3))
            .child(
                div()
                    .absolute()
                    .size_full()
                    .flex()
                    .children(density.iter().map(|&count| {
                        div().flex_1().h_full().bg(chrome
                            .accent
                            .opacity(f32::from(count as u16) / f32::from(max_density as u16) * 0.3))
                    })),
            )
            .children(open.blocks.iter().map(|b| {
                div()
                    .absolute()
                    .top_0()
                    .h(px(8.0))
                    .left(relative(timeline.block_start_fraction(b) as f32))
                    .w(relative(timeline.block_width_fraction(b, now) as f32))
                    .min_w(px(2.0))
                    .bg(block_color(b).opacity(0.5))
            }))
            .child(
                div()
                    .absolute()
                    .top_0()
                    .h(px(8.0))
                    .left(relative(open.position as f32 * 0.85))
                    .w(relative(0.15))
                    .border_1()
                    .border_color(chrome.accent),
            );

        // Main track with blocks and handle.
        // ANL-007: an adjustable element, like the Swift scrubber
        // (`accessibilityAdjustableAction`): VoiceOver increment and
        // decrement move the handle by 5%, the value is the elapsed time.
        let step_handler = |delta: f64| {
            let workspace = cx.entity().downgrade();
            move |_: Option<&gpui::accesskit::ActionData>, _: &mut Window, cx: &mut gpui::App| {
                workspace
                    .update(cx, |this, cx| this.timeline_step(delta, cx))
                    .ok();
            }
        };
        let track = div()
            .id("timeline-track")
            .role(Role::Slider)
            .aria_label("Timeline scrubber")
            .aria_value(timeline.label_at(open.position))
            .aria_numeric_value(open.position * 100.0)
            .aria_min_numeric_value(0.0)
            .aria_max_numeric_value(100.0)
            .aria_numeric_value_step(A11Y_STEP * 100.0)
            .aria_orientation(gpui::Orientation::Horizontal)
            .on_a11y_action(AccessibleAction::Increment, step_handler(A11Y_STEP))
            .on_a11y_action(AccessibleAction::Decrement, step_handler(-A11Y_STEP))
            .relative()
            .h(px(24.0))
            .flex_1()
            .cursor_pointer()
            .child(
                canvas(
                    {
                        let cell = track_cell.clone();
                        move |bounds, _, _| cell.set(bounds)
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size_full(),
            )
            .child(
                div()
                    .absolute()
                    .top(px(2.0))
                    .h(px(20.0))
                    .w_full()
                    .rounded(px(4.0))
                    .bg(chrome.border),
            )
            .children(open.blocks.iter().enumerate().map(|(index, b)| {
                div()
                    .id(("timeline-block", index))
                    .role(Role::Label)
                    .aria_label(block_a11y_label(b))
                    .absolute()
                    .top(px(4.0))
                    .h(px(16.0))
                    .left(relative(timeline.block_start_fraction(b) as f32))
                    .w(relative(timeline.block_width_fraction(b, now) as f32))
                    .min_w(px(4.0))
                    .rounded(px(2.0))
                    .bg(block_color(b))
                    .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                        if let Some(open) =
                            this.timeline_panel.as_mut().and_then(|p| p.open.as_mut())
                        {
                            open.hovered = hovered.then_some(index);
                            cx.notify();
                        }
                    }))
            }))
            .child(
                div()
                    .absolute()
                    .top_0()
                    .h(px(24.0))
                    .w(px(4.0))
                    .rounded(px(2.0))
                    .left(relative(open.position as f32))
                    .ml(px(-2.0))
                    .bg(chrome.accent),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _, cx| {
                    this.timeline_scrub(event.position.x, cx)
                }),
            )
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                if event.pressed_button == Some(MouseButton::Left) {
                    this.timeline_scrub(event.position.x, cx);
                }
            }));

        let controls = div()
            .flex()
            .items_center()
            .gap_2()
            .child(
                chip(
                    "timeline-play",
                    if open.playing { "Pause" } else { "Play" },
                    chrome,
                )
                .aria_label(if open.playing {
                    "Pause replay"
                } else {
                    "Play replay"
                })
                .on_click(cx.listener(|this, _, _, cx| this.timeline_toggle_play(cx))),
            )
            .children(SPEEDS.iter().enumerate().map(|(index, speed)| {
                let speed = *speed;
                let selected = (open.speed - speed).abs() < f64::EPSILON;
                chip(("timeline-speed", index), format!("{speed}x"), chrome)
                    .when(selected, |d| d.bg(chrome.accent.opacity(0.25)))
                    .aria_label(format!("Playback speed: {speed:.1}x"))
                    .aria_selected(selected)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(open) =
                            this.timeline_panel.as_mut().and_then(|p| p.open.as_mut())
                        {
                            open.speed = speed;
                            cx.notify();
                        }
                    }))
            }))
            .child(track)
            .child(
                div()
                    .w(px(52.0))
                    .text_right()
                    .text_size(px(10.0))
                    .font_family("Menlo")
                    .text_color(chrome.text_muted)
                    .child(timeline.label_at(open.position)),
            );

        let tooltip = open.hovered.and_then(|i| open.blocks.get(i)).map(|b| {
            div()
                .flex()
                .items_center()
                .gap_2()
                .px_2()
                .py_1()
                .rounded_md()
                .bg(chrome.tab_bg)
                .child(div().size(px(8.0)).rounded_full().bg(block_color(b)))
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .child(b.command.clone()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(b.duration_string()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(block_color(b))
                        .child(block_status(b)),
                )
        });

        let lines = replay_text(&open.frames, timeline.date_at(open.position), REPLAY_LINES);
        let replay = div()
            .id("timeline-replay")
            .h(px(REPLAY_LINES as f32 * 15.0 + 8.0))
            .p_1()
            .rounded_md()
            .bg(gpui::hsla(0.0, 0.0, 0.08, 1.0))
            .text_color(gpui::hsla(0.0, 0.0, 0.88, 1.0))
            .font_family("Menlo")
            .text_size(px(11.0))
            .overflow_hidden()
            .flex()
            .flex_col()
            .children(lines.into_iter().map(|line| {
                div()
                    .h(px(15.0))
                    .whitespace_nowrap()
                    .overflow_hidden()
                    .child(if line.is_empty() {
                        " ".to_string()
                    } else {
                        line
                    })
            }));

        div()
            .flex()
            .flex_col()
            .gap_1()
            .pt_1()
            .child(div().text_xs().text_color(chrome.text_muted).child(format!(
                "{} \u{b7} {} commands",
                open.meta.title,
                open.blocks.len()
            )))
            .child(mini)
            .child(controls)
            .children(tooltip)
            .child(replay)
            .into_any_element()
    }
}

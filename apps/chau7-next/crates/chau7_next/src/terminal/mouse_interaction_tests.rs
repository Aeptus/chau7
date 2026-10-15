//! Rendered terminal mouse regressions. Each fixture uses an isolated `/bin/cat`
//! PTY and a temporary data root; no user profile or provider is involved.

use std::{path::PathBuf, time::Duration};

use chau7_next_core::data_root::DataRoot;
use chau7_terminal::Chau7Terminal;
use gpui::{
    AnyWindowHandle, AppContext, ClipboardItem, Context, Entity, Focusable, Modifiers, MouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, Pixels, PlatformInput, Render, ScrollDelta,
    ScrollWheelEvent, TestAppContext, TouchPhase, Window, div, point, prelude::*, px,
};
use gpui_kit::test::TestWindowExt;

use crate::{
    settings::Settings,
    terminal::{session::TerminalSession, view::TerminalView},
    workspace::AppData,
};

struct MouseTestRoot {
    terminal: Entity<TerminalView>,
    session: Entity<TerminalSession>,
    bubbled_scrolls: usize,
}

impl Render for MouseTestRoot {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .on_scroll_wheel(cx.listener(|this, _, _, _| this.bubbled_scrolls += 1))
            .child(self.terminal.clone())
    }
}

struct Fixture {
    window: AnyWindowHandle,
    root: Entity<MouseTestRoot>,
    terminal: Entity<TerminalView>,
    session: Entity<TerminalSession>,
    home: PathBuf,
}

fn fixture(harness: &mut TestAppContext) -> Fixture {
    let home = std::env::temp_dir().join(format!("chau7-terminal-mouse-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&home).unwrap();
    harness.on_quit({
        let home = home.clone();
        move || {
            let _ = std::fs::remove_dir_all(home);
        }
    });
    let data_root = DataRoot::with_home(home.clone(), true);
    harness.update(|cx| {
        gpui_kit::init(cx);
        let mut settings = Settings::default();
        settings.input.mouse_reporting = true;
        settings.input.copy_on_select = true;
        cx.set_global(settings);
        cx.set_global(AppData::new(data_root));
        crate::terminal::command_guard::init(cx);
        crate::observability::init_for_test(cx);
    });

    let (window, root) = harness.update(|cx| {
        gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
            let model = Chau7Terminal::new_with_args_env_in_dir(
                80,
                24,
                "/bin/cat",
                &[],
                &[("TERM", "xterm-256color")],
                None,
            )
            .unwrap();
            for line in 0..160 {
                model.inject_output(
                    format!("row-{line:03} alpha beta target tail marker\r\n").as_bytes(),
                );
            }
            model.inject_output(b"\x1b[?1000h");
            let session = cx.new(|cx| {
                let mut session = TerminalSession::from_terminal_manually_driven(model, None, cx);
                session.apply_settings(Settings::get(cx));
                session
            });
            let terminal = cx.new(|cx| TerminalView::new(session.clone(), window, cx));
            cx.new(|_| MouseTestRoot {
                terminal,
                session,
                bubbled_scrolls: 0,
            })
        })
        .unwrap()
    });
    let (terminal, session) = harness.update(|cx| {
        let root = root.read(cx);
        (root.terminal.clone(), root.session.clone())
    });
    let fixture = Fixture {
        window,
        root,
        terminal,
        session,
        home,
    };
    harness
        .update_window(fixture.window, |_, window, _| window.activate_window())
        .unwrap();
    harness.run_until_parked();
    harness
        .update_window(fixture.window, |_, window, cx| {
            let focus = fixture.terminal.read(cx).focus_handle(cx);
            window.focus(&focus, cx);
            window.render_frame(cx);
        })
        .unwrap();
    harness.run_until_parked();
    fixture
}

fn close_fixture(harness: &mut TestAppContext, fixture: Fixture) {
    harness.update(|cx| fixture.session.update(cx, |session, _| session.close()));
    harness
        .update_window(fixture.window, |_, window, _| window.remove_window())
        .unwrap();
    let _ = std::fs::remove_dir_all(fixture.home);
}

fn dispatch_scroll(
    harness: &mut TestAppContext,
    fixture: &Fixture,
    position: gpui::Point<Pixels>,
    delta: ScrollDelta,
    modifiers: Modifiers,
    phase: TouchPhase,
) {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_event(
                PlatformInput::ScrollWheel(ScrollWheelEvent {
                    position,
                    delta,
                    modifiers,
                    touch_phase: phase,
                }),
                cx,
            );
            window.render_frame(cx);
        })
        .unwrap();
}

fn dispatch_down(
    harness: &mut TestAppContext,
    fixture: &Fixture,
    position: gpui::Point<Pixels>,
    modifiers: Modifiers,
    click_count: usize,
) {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_event(
                PlatformInput::MouseDown(MouseDownEvent {
                    position,
                    button: MouseButton::Left,
                    modifiers,
                    click_count,
                    first_mouse: false,
                }),
                cx,
            );
            window.render_frame(cx);
        })
        .unwrap();
}

fn dispatch_move(
    harness: &mut TestAppContext,
    fixture: &Fixture,
    position: gpui::Point<Pixels>,
    pressed_button: Option<MouseButton>,
    modifiers: Modifiers,
) {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_event(
                PlatformInput::MouseMove(MouseMoveEvent {
                    position,
                    pressed_button,
                    modifiers,
                }),
                cx,
            );
            window.render_frame(cx);
        })
        .unwrap();
}

fn dispatch_up(
    harness: &mut TestAppContext,
    fixture: &Fixture,
    position: gpui::Point<Pixels>,
    modifiers: Modifiers,
    click_count: usize,
) {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_event(
                PlatformInput::MouseUp(MouseUpEvent {
                    position,
                    button: MouseButton::Left,
                    modifiers,
                    click_count,
                }),
                cx,
            );
            window.render_frame(cx);
        })
        .unwrap();
}

fn cell_point(
    harness: &mut TestAppContext,
    fixture: &Fixture,
    row: usize,
    column: usize,
) -> gpui::Point<Pixels> {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            let terminal = fixture.terminal.read(cx);
            let bounds = terminal.bounds.unwrap();
            let metrics = terminal.metrics.as_ref().unwrap();
            point(
                bounds.origin.x + metrics.cell_width * (column as f32 + 0.5),
                bounds.origin.y + metrics.line_height * (row as f32 + 0.5),
            )
        })
        .unwrap()
}

fn terminal_bounds(harness: &mut TestAppContext, fixture: &Fixture) -> gpui::Bounds<Pixels> {
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            fixture.terminal.read(cx).bounds.unwrap()
        })
        .unwrap()
}

fn visible_row(harness: &TestAppContext, fixture: &Fixture, label: &str) -> usize {
    harness.update(|cx| {
        let session = fixture.session.read(cx);
        let offset = session.display_offset() as i32;
        (0..session.grid.rows as i32)
            .find(|row| {
                session
                    .line_text(*row - offset)
                    .is_some_and(|line| line.contains(label))
            })
            .unwrap_or_else(|| panic!("{label} is not visible at offset {offset}")) as usize
    })
}

fn shift() -> Modifiers {
    Modifiers {
        shift: true,
        ..Default::default()
    }
}

fn shift_alt() -> Modifiers {
    Modifiers {
        shift: true,
        alt: true,
        ..Default::default()
    }
}

#[gpui::test]
fn rendered_wheel_routes_reporting_accumulates_pixels_and_bubbles_horizontal_only(
    harness: &mut TestAppContext,
) {
    let fixture = fixture(harness);
    assert_ne!(
        harness.update(|cx| fixture.session.read(cx).mouse_mode() & 0b111),
        0
    );
    let position = terminal_bounds(harness, &fixture).center();

    // Unmodified wheel input is reported to the terminal program, while Shift
    // forces local scrolling and keeps the event inside the terminal.
    dispatch_scroll(
        harness,
        &fixture,
        position,
        ScrollDelta::Lines(point(0.0, 1.0)),
        Modifiers::default(),
        TouchPhase::Moved,
    );
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        0
    );
    dispatch_scroll(
        harness,
        &fixture,
        position,
        ScrollDelta::Lines(point(0.0, 2.0)),
        shift(),
        TouchPhase::Moved,
    );
    assert!(harness.update(|cx| fixture.session.read(cx).display_offset()) > 0);
    assert_eq!(
        harness.update(|cx| fixture.root.read(cx).bubbled_scrolls),
        0
    );

    let line_height = harness
        .update_window(fixture.window, |_, window, cx| {
            window.render_frame(cx);
            fixture
                .terminal
                .read(cx)
                .metrics
                .as_ref()
                .unwrap()
                .line_height
        })
        .unwrap();
    harness.update(|cx| {
        fixture.session.update(cx, |session, cx| {
            session.scroll_to_bottom();
            session.refresh(cx);
        })
    });
    harness
        .update_window(fixture.window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    let pixel = |fraction: f32| ScrollDelta::Pixels(point(px(0.0), line_height * fraction));

    // The final Ended delta completes a line. A new Started phase discards a
    // previous partial gesture instead of carrying it into the next scroll.
    for (fraction, phase) in [
        (0.25, TouchPhase::Started),
        (0.25, TouchPhase::Moved),
        (0.5, TouchPhase::Ended),
    ] {
        dispatch_scroll(harness, &fixture, position, pixel(fraction), shift(), phase);
    }
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        1
    );
    harness.update(|cx| {
        fixture.session.update(cx, |session, cx| {
            session.scroll_to_bottom();
            session.refresh(cx);
        })
    });
    harness
        .update_window(fixture.window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    for (fraction, phase) in [
        (0.75, TouchPhase::Moved),
        (0.25, TouchPhase::Started),
        (0.5, TouchPhase::Moved),
    ] {
        dispatch_scroll(harness, &fixture, position, pixel(fraction), shift(), phase);
    }
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        0
    );
    dispatch_scroll(
        harness,
        &fixture,
        position,
        pixel(0.25),
        shift(),
        TouchPhase::Ended,
    );
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        1
    );
    assert_eq!(
        harness.update(|cx| fixture.root.read(cx).bubbled_scrolls),
        0
    );

    dispatch_scroll(
        harness,
        &fixture,
        position,
        ScrollDelta::Pixels(point(px(12.0), px(0.0))),
        Modifiers::default(),
        TouchPhase::Moved,
    );
    assert_eq!(
        harness.update(|cx| fixture.root.read(cx).bubbled_scrolls),
        1
    );
    // Default shell settings also scroll without a modifier, even if a
    // program left mouse-reporting mode enabled in the terminal backend.
    harness.update(|cx| {
        let mut settings = Settings::get(cx).clone();
        settings.input.mouse_reporting = false;
        fixture
            .session
            .update(cx, |session, _| session.apply_settings(&settings));
        cx.set_global(settings);
    });
    let offset = harness.update(|cx| fixture.session.read(cx).display_offset());
    dispatch_scroll(
        harness,
        &fixture,
        position,
        ScrollDelta::Lines(point(0.0, 1.0)),
        Modifiers::default(),
        TouchPhase::Moved,
    );
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        offset + 1
    );
    close_fixture(harness, fixture);
}

#[gpui::test]
fn rendered_selection_survives_wheel_drag_copy_paste_and_click_extensions(
    harness: &mut TestAppContext,
) {
    let fixture = fixture(harness);
    harness.update(|cx| {
        fixture.session.update(cx, |session, cx| {
            session.scroll_lines(20);
            session.refresh(cx);
        })
    });
    harness
        .update_window(fixture.window, |_, window, cx| window.render_frame(cx))
        .unwrap();

    let start = cell_point(harness, &fixture, 3, 2);
    let end = cell_point(harness, &fixture, 7, 35);
    dispatch_down(harness, &fixture, start, shift(), 1);
    dispatch_move(harness, &fixture, end, Some(MouseButton::Left), shift());
    let old_offset = harness.update(|cx| fixture.session.read(cx).display_offset());
    dispatch_scroll(
        harness,
        &fixture,
        end,
        ScrollDelta::Lines(point(0.0, 2.0)),
        shift(),
        TouchPhase::Moved,
    );
    let new_offset = harness.update(|cx| fixture.session.read(cx).display_offset());
    assert!(new_offset > old_offset);
    let scrolled_endpoint = harness.update(|cx| {
        let session = fixture.session.read(cx);
        session
            .line_text(7 - session.display_offset() as i32)
            .unwrap()
    });
    let endpoint_label = scrolled_endpoint.split_whitespace().next().unwrap();
    let wheel_selection = harness.update(|cx| fixture.session.read(cx).selection_text().unwrap());
    let last_selected_line = wheel_selection.lines().last().unwrap().trim_start();
    assert!(
        last_selected_line.starts_with(endpoint_label),
        "selection ended at {last_selected_line:?}, expected {endpoint_label:?}"
    );

    // Continue the drag beyond the canvas, let one auto-scroll tick run, then
    // synthesize a lost release outside the canvas and verify the timer stops.
    let bounds = terminal_bounds(harness, &fixture);
    let outside = point(bounds.center().x, bounds.bottom() + px(1.0));
    dispatch_move(harness, &fixture, outside, Some(MouseButton::Left), shift());
    let before_auto_scroll = harness.update(|cx| fixture.session.read(cx).display_offset());
    harness.executor().advance_clock(Duration::from_millis(60));
    harness.run_until_parked();
    let after_auto_scroll = harness.update(|cx| fixture.session.read(cx).display_offset());
    assert!(after_auto_scroll < before_auto_scroll);
    dispatch_move(harness, &fixture, outside, None, shift());
    harness.executor().advance_clock(Duration::from_millis(200));
    harness.run_until_parked();
    assert_eq!(
        harness.update(|cx| fixture.session.read(cx).display_offset()),
        after_auto_scroll,
        "an outside release must stop auto-scroll while preserving the selection"
    );
    assert!(harness.update(|cx| fixture.session.read(cx).selection_text().is_some()));

    // Start a known selection, then Shift-click/drag farther down. The first
    // selected row must remain the original anchor after the second gesture.
    harness.update(|cx| {
        fixture.session.update(cx, |session, cx| {
            session.scroll_to_bottom();
            session.selection_clear();
            session.refresh(cx);
        })
    });
    harness
        .update_window(fixture.window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    let anchor_row = visible_row(harness, &fixture, "row-150");
    let initial_end_row = visible_row(harness, &fixture, "row-151");
    let anchor_label = "row-150";
    let anchor = cell_point(harness, &fixture, anchor_row, 0);
    let initial_end = cell_point(harness, &fixture, initial_end_row, 8);
    // Leave a reported press pending, then start a local Shift selection.
    // The new gesture must release the stale report before taking ownership.
    dispatch_down(harness, &fixture, anchor, Modifiers::default(), 1);
    dispatch_down(harness, &fixture, anchor, shift(), 1);
    dispatch_move(
        harness,
        &fixture,
        initial_end,
        Some(MouseButton::Left),
        shift(),
    );
    dispatch_up(harness, &fixture, initial_end, shift(), 1);
    let extension_row = visible_row(harness, &fixture, "row-153");
    let extension_point = cell_point(harness, &fixture, extension_row, 2);
    dispatch_down(harness, &fixture, extension_point, shift(), 1);
    let extension_end_row = visible_row(harness, &fixture, "row-154");
    let extension_end = cell_point(harness, &fixture, extension_end_row, 8);
    dispatch_move(
        harness,
        &fixture,
        extension_end,
        Some(MouseButton::Left),
        shift(),
    );
    dispatch_up(harness, &fixture, extension_end, shift(), 1);
    let extended = harness.update(|cx| fixture.session.read(cx).selection_text().unwrap());
    assert!(
        extended
            .lines()
            .next()
            .unwrap()
            .trim_start()
            .starts_with(anchor_label),
        "Shift extension lost its original anchor: {extended:?}"
    );

    // A double-click word selection remains draggable, and Cmd+C uses the
    // same selection. Triple-click line selection extends to the next line.
    let word_row = visible_row(harness, &fixture, "row-158");
    let word_start = cell_point(harness, &fixture, word_row, 20);
    let word_end = cell_point(harness, &fixture, word_row, 29);
    dispatch_down(harness, &fixture, word_start, shift(), 2);
    dispatch_move(
        harness,
        &fixture,
        word_end,
        Some(MouseButton::Left),
        shift(),
    );
    dispatch_up(harness, &fixture, word_end, shift(), 2);
    let word_selection = harness.update(|cx| fixture.session.read(cx).selection_text().unwrap());
    assert!(
        word_selection.contains("target tail"),
        "selection was: {word_selection:?}"
    );
    harness.executor().advance_clock(Duration::from_millis(350));
    harness.run_until_parked();
    assert_eq!(
        harness
            .read_from_clipboard()
            .and_then(|item| item.text())
            .as_deref(),
        Some(word_selection.as_str())
    );
    harness.write_to_clipboard(ClipboardItem::new_string("copy-sentinel".into()));
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_action(Box::new(crate::actions::Copy), cx);
        })
        .unwrap();
    harness.run_until_parked();
    assert_eq!(
        harness
            .read_from_clipboard()
            .and_then(|item| item.text())
            .as_deref(),
        Some(word_selection.as_str())
    );

    let line_a = visible_row(harness, &fixture, "row-158");
    let line_b = visible_row(harness, &fixture, "row-159");
    let line_start = cell_point(harness, &fixture, line_a, 2);
    let line_end = cell_point(harness, &fixture, line_b, 8);
    dispatch_down(harness, &fixture, line_start, shift(), 3);
    dispatch_move(
        harness,
        &fixture,
        line_end,
        Some(MouseButton::Left),
        shift(),
    );
    dispatch_up(harness, &fixture, line_end, shift(), 3);
    let line_selection = harness.update(|cx| fixture.session.read(cx).selection_text().unwrap());
    assert!(line_selection.contains("row-158"));
    assert!(line_selection.contains("row-159"));

    harness.executor().advance_clock(Duration::from_millis(350));
    harness.run_until_parked();

    // Alt is remembered from mouse-down even if released before mouse-up;
    // start with no existing selection so this gesture uses Block mode.
    harness.update(|cx| {
        fixture.session.update(cx, |session, cx| {
            session.selection_clear();
            session.refresh(cx);
        })
    });
    // The rectangular selection does not replace the clipboard.
    harness.write_to_clipboard(ClipboardItem::new_string("clipboard-sentinel".into()));
    let block_start = cell_point(harness, &fixture, line_a, 2);
    let block_end = cell_point(harness, &fixture, line_b, 20);
    dispatch_down(harness, &fixture, block_start, shift_alt(), 1);
    dispatch_move(
        harness,
        &fixture,
        block_end,
        Some(MouseButton::Left),
        shift(),
    );
    dispatch_up(harness, &fixture, block_end, shift(), 1);
    harness.executor().advance_clock(Duration::from_millis(350));
    harness.run_until_parked();
    assert_eq!(
        harness
            .read_from_clipboard()
            .and_then(|item| item.text())
            .as_deref(),
        Some("clipboard-sentinel")
    );

    harness.write_to_clipboard(ClipboardItem::new_string("paste-probe".into()));
    let revision = harness.update(|cx| fixture.session.read(cx).input_revision());
    harness
        .update_window(fixture.window, |_, window, cx| {
            window.dispatch_action(Box::new(crate::actions::Paste), cx);
        })
        .unwrap();
    harness.run_until_parked();
    assert!(harness.update(|cx| fixture.session.read(cx).input_revision()) > revision);
    close_fixture(harness, fixture);
}

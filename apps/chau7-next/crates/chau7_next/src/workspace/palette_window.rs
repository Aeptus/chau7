//! The command palette (`CommandPaletteController`): a floating panel 500 pt
//! wide, 100 pt below the top of the screen, centered, with the search field
//! focused. The shortcut or the menu item toggles it; Escape closes it; it
//! hides when it stops being active (Swift: `hidesOnDeactivate`). Return or
//! a click runs the selected command after the panel closes, on the terminal
//! window it was opened from (focused first, so terminal actions reach it).

use gpui::{
    AnyWindowHandle, App, Bounds, Context, Entity, FocusHandle, Focusable, Global, KeyDownEvent,
    Render, ScrollHandle, Subscription, Window, WindowBackgroundAppearance, WindowBounds,
    WindowKind, WindowOptions, div, point, prelude::*, px, size,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::pickers::palette::{self, PaletteCommand, PaletteIcon};
use super::{AppData, Workspace};
use crate::actions::ToggleCommandPalette;
use crate::theme::Chrome;

#[derive(Default)]
struct OpenPalette(Option<AnyWindowHandle>);
impl Global for OpenPalette {}

const WIDTH: f32 = 500.0;
/// Search field, list (at most 350 pt) and footer.
const SEARCH_HEIGHT: f32 = 44.0;
const FOOTER_HEIGHT: f32 = 34.0;
const ROW_HEIGHT: f32 = 40.0;
const LIST_MAX: f32 = 350.0;

fn close_open_palette(cx: &mut App) -> bool {
    let Some(handle) = cx.try_global::<OpenPalette>().and_then(|p| p.0) else {
        return false;
    };
    cx.set_global(OpenPalette(None));
    handle
        .update(cx, |_, window, _| window.remove_window())
        .is_ok()
}

/// Open the palette for the terminal window `window`, or close it when open.
pub(super) fn toggle(window: &mut Window, cx: &mut App) {
    if close_open_palette(cx) {
        return;
    }
    let target = window.window_handle();
    let commands = palette::commands(window, cx);
    let display = window.display(cx);
    let area = display
        .as_ref()
        .map(|d| d.visible_bounds())
        .unwrap_or_else(|| window.bounds());
    let list = (commands.len() as f32 * ROW_HEIGHT).clamp(ROW_HEIGHT, LIST_MAX);
    let height = (SEARCH_HEIGHT + list + FOOTER_HEIGHT).max(200.0);
    let bounds = Bounds::new(
        point(area.center().x - px(WIDTH / 2.0), area.top() + px(100.0)),
        size(px(WIDTH), px(height)),
    );
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        kind: WindowKind::Floating,
        is_movable: true,
        is_resizable: false,
        is_minimizable: false,
        focus: true,
        show: true,
        display_id: display.map(|d| d.id()),
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    };
    match gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&crate::l10n::tr("Command Palette"));
        cx.new(|cx| PalettePanel::new(commands, target, window, cx))
    }) {
        Ok((handle, _)) => {
            let _ = handle.update(cx, |_, window, _| window.activate_window());
            cx.set_global(OpenPalette(Some(handle)));
        }
        Err(err) => log::error!("command palette: {err}"),
    }
}

pub struct PalettePanel {
    input: Entity<InputState>,
    commands: Vec<PaletteCommand>,
    /// Indexes into `commands` that match the search.
    matches: Vec<usize>,
    selected: usize,
    scroll: ScrollHandle,
    target: AnyWindowHandle,
    focus: FocusHandle,
    /// The panel was active once: losing that closes it.
    was_active: bool,
    _subscriptions: Vec<Subscription>,
}

impl PalettePanel {
    fn new(
        commands: Vec<PaletteCommand>,
        target: AnyWindowHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Type a command..."))
        });
        let search =
            cx.subscribe_in(
                &input,
                window,
                |this, _, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => this.refilter(cx),
                    InputEvent::PressEnter { .. } => this.run(this.selected, window, cx),
                    _ => {}
                },
            );
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if window.is_window_active() {
                this.was_active = true;
            } else if this.was_active {
                this.close(window, cx);
            }
        });
        input.update(cx, |i, cx| i.focus(window, cx));
        let matches = (0..commands.len()).collect();
        Self {
            input,
            commands,
            matches,
            selected: 0,
            scroll: ScrollHandle::new(),
            target,
            focus: cx.focus_handle(),
            was_active: false,
            _subscriptions: vec![search, activation],
        }
    }

    /// Title or category contains the query; selection back to the top.
    fn refilter(&mut self, cx: &mut Context<Self>) {
        let query = self.input.read(cx).value().to_string();
        self.matches = self
            .commands
            .iter()
            .enumerate()
            .filter(|(_, c)| palette::matches(c, &query))
            .map(|(i, _)| i)
            .collect();
        self.selected = 0;
        self.scroll.scroll_to_item(0);
        cx.notify();
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if cx
            .try_global::<OpenPalette>()
            .and_then(|p| p.0)
            .is_some_and(|h| h == window.window_handle())
        {
            cx.set_global(OpenPalette(None));
        }
        window.remove_window();
    }

    /// Close, then run the command on the terminal window.
    fn run(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(command) = self
            .matches
            .get(index)
            .and_then(|i| self.commands.get(*i))
            .cloned()
        else {
            return;
        };
        self.close(window, cx);
        let target = self.target;
        cx.defer(move |cx| {
            let workspace = AppData::live(cx)
                .into_iter()
                .find(|(handle, _)| *handle == target)
                .map(|(_, ws)| ws);
            let _ = target.update(cx, |_, window, cx| {
                window.activate_window();
                if let Some(ws) = &workspace {
                    ws.update(cx, |ws: &mut Workspace, cx| ws.focus_selected(window, cx));
                }
                let action = command.action.boxed_clone();
                window.defer(cx, move |window, cx| window.dispatch_action(action, cx));
            });
        });
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let last = self.matches.len().saturating_sub(1) as isize;
        self.selected = (self.selected as isize + delta).clamp(0, last.max(0)) as usize;
        self.scroll.scroll_to_item(self.selected);
        cx.notify();
    }
}

impl Focusable for PalettePanel {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// The 20 pt wide icon column of a row (`CommandRow`: 13 pt symbol).
fn row_icon(icon: PaletteIcon, color: gpui::Hsla) -> gpui::Div {
    let cell = div()
        .w(px(20.0))
        .flex_shrink_0()
        .flex()
        .items_center()
        .justify_center()
        .text_color(color);
    match icon {
        PaletteIcon::Lucide(name) => cell.child(
            gpui::svg()
                .path(name.path())
                .size(px(13.0))
                .text_color(color),
        ),
        // `N.circle`: the digit in a thin circle.
        PaletteIcon::Number(n) => cell.child(
            div()
                .size(px(14.0))
                .rounded_full()
                .border_1()
                .border_color(color)
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(9.0))
                .child(n.to_string()),
        ),
    }
}

impl Render for PalettePanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let rows: Vec<_> = self
            .matches
            .iter()
            .enumerate()
            .filter_map(|(row, index)| Some((row, self.commands.get(*index)?.clone())))
            .map(|(row, command)| {
                let selected = row == self.selected;
                let muted = if selected {
                    gpui::white().opacity(0.7)
                } else {
                    chrome.text_muted
                };
                div()
                    .id(("palette-row", row))
                    .h(px(ROW_HEIGHT))
                    .px_3()
                    .flex()
                    .items_center()
                    .gap(px(10.0))
                    .when(selected, |d| d.bg(chrome.accent).text_color(gpui::white()))
                    .when(!selected, |d| d.hover(|d| d.bg(chrome.tab_hover_bg)))
                    .child(row_icon(
                        command.icon,
                        if selected {
                            gpui::white()
                        } else {
                            chrome.text_muted
                        },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().text_sm().child(command.title.clone()))
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(muted)
                                    .child(crate::l10n::tr(command.category)),
                            ),
                    )
                    .when_some(command.shortcut.clone(), |d, shortcut| {
                        d.child(
                            div()
                                .px_1p5()
                                .py_0p5()
                                .rounded(px(4.0))
                                .bg(if selected {
                                    gpui::white().opacity(0.2)
                                } else {
                                    chrome.border.opacity(0.5)
                                })
                                .text_size(px(11.0))
                                .font_family("Menlo")
                                .text_color(if selected {
                                    gpui::white().opacity(0.8)
                                } else {
                                    chrome.text_muted
                                })
                                .child(shortcut),
                        )
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.selected = row;
                        this.run(row, window, cx);
                    }))
            })
            .collect();
        let count = self.matches.len();
        let hint = |keys: &'static [&'static str], label: String| {
            div()
                .flex()
                .items_center()
                .gap_1()
                .children(keys.iter().map(|k| {
                    div()
                        .px_1()
                        .rounded(px(3.0))
                        .bg(chrome.border.opacity(0.5))
                        .text_size(px(10.0))
                        .font_family("Menlo")
                        .child(*k)
                }))
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(chrome.text_muted)
                        .child(label),
                )
        };
        div()
            .id("command-palette")
            .key_context("Palette")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .rounded(px(10.0))
            .overflow_hidden()
            .border_1()
            .border_color(chrome.border)
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .on_action(
                cx.listener(|this, _: &ToggleCommandPalette, window, cx| this.close(window, cx)),
            )
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "down" => this.move_selection(1, cx),
                    "up" => this.move_selection(-1, cx),
                    "escape" => this.close(window, cx),
                    _ => {}
                }
            }))
            .child(
                div()
                    .h(px(SEARCH_HEIGHT))
                    .px_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        gpui::svg()
                            .path(gpui_kit::assets::IconName::Search.path())
                            .size(px(14.0))
                            .text_color(chrome.text_muted),
                    )
                    .child(
                        div()
                            .flex_1()
                            .child(Input::new(&self.input).appearance(false)),
                    ),
            )
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(
                div()
                    .id("palette-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .py_1()
                    .children(rows)
                    .when(count == 0, |d| {
                        d.child(
                            div()
                                .p_3()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::tr("No matching command.")),
                        )
                    }),
            )
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(
                div()
                    .h(px(FOOTER_HEIGHT))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::lf(
                                "palette.commands.count",
                                "%d commands",
                                &[count.into()],
                            )),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_3()
                            .child(hint(
                                &["↑", "↓"],
                                crate::l10n::l("palette.navigate", "navigate"),
                            ))
                            .child(hint(&["↵"], crate::l10n::l("palette.select", "select")))
                            .child(hint(&["esc"], crate::l10n::l("palette.close", "close"))),
                    ),
            )
    }
}

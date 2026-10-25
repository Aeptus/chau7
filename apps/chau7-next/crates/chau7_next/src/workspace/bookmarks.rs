//! Bookmarks (`BookmarkManager`, `BookmarkListOverlayView`): Cmd+B marks the
//! line at the cursor of the selected tab; the bookmarks panel lists the
//! tab's bookmarks (label, line preview, time), jumps to one on click and
//! removes one with its × button. At most `feature.maxBookmarks` per tab
//! (20 by default, 1 to 200); when full, the oldest unlabeled bookmark goes
//! first. Nothing is added while bookmarks are off (`feature.bookmarksEnabled`).
//!
//! Swift's panel adds a placeholder bookmark (offset 0, "Bookmark at current
//! position"); Chau7 Next records the real line and scrolls back to it.

use std::time::SystemTime;

use gpui::{Context, Div, Entity, Stateful, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{InputEvent, InputState};

use super::Workspace;
use super::panel::PanelKind;
use super::widgets::{button, chrome_input};
use crate::actions::{AddBookmark, ToggleBookmarks};
use crate::settings::Settings;
use crate::tab_bar::TabId;
use crate::theme::Chrome;

#[derive(Debug, Clone)]
pub(super) struct Bookmark {
    id: u64,
    /// Line counted from the top of the scrollback.
    absolute_line: i64,
    preview: String,
    time: SystemTime,
    label: Option<String>,
}

impl Bookmark {
    /// Unique among the bookmarks of the window that holds the tab.
    pub(super) fn id(&self) -> u64 {
        self.id
    }

    #[cfg(test)]
    pub(super) fn for_test(id: u64, label: &str) -> Self {
        Self {
            id,
            absolute_line: 0,
            preview: String::new(),
            time: SystemTime::UNIX_EPOCH,
            label: Some(label.to_string()),
        }
    }

    #[cfg(test)]
    pub(super) fn label(&self) -> Option<&str> {
        self.label.as_deref()
    }
}

pub(super) struct BookmarksPanel {
    label: Entity<InputState>,
    _subscription: Subscription,
}

pub(super) fn register_bookmark_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &AddBookmark, _, cx| this.add_bookmark(None, cx)))
        .on_action(
            cx.listener(|this, _: &ToggleBookmarks, window, cx| this.toggle_bookmarks(window, cx)),
        )
}

/// Keep at most `max` bookmarks before adding one: drop the oldest
/// unlabeled one, else the newest (`addBookmark` in Swift).
fn make_room(bookmarks: &mut Vec<Bookmark>, max: usize) {
    if bookmarks.len() >= max {
        if let Some(index) = bookmarks.iter().position(|b| b.label.is_none()) {
            bookmarks.remove(index);
        } else {
            bookmarks.pop();
        }
    }
}

impl Workspace {
    fn toggle_bookmarks(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.bookmarks_panel.take().is_some() {
            self.focus_selected(window, cx);
            cx.notify();
            return;
        }
        self.close_other_panels(Some(PanelKind::Bookmarks), cx);
        let label = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Bookmark label (optional)"))
        });
        let subscription = cx.subscribe_in(
            &label,
            window,
            |this, input, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { .. } = event {
                    let text = input.read(cx).value().trim().to_string();
                    this.add_bookmark((!text.is_empty()).then_some(text), cx);
                    input.update(cx, |i, cx| i.set_value("", window, cx));
                }
            },
        );
        label.update(cx, |i, cx| i.focus(window, cx));
        self.panel_generation += 1;
        self.bookmarks_panel = Some(BookmarksPanel {
            label,
            _subscription: subscription,
        });
        cx.notify();
    }

    /// Bookmark the cursor line of the selected tab.
    pub(super) fn add_bookmark(&mut self, label: Option<String>, cx: &mut Context<Self>) {
        let productivity = &Settings::get(cx).productivity;
        if !productivity.bookmarks_enabled {
            return;
        }
        let max = productivity.max_bookmarks_per_tab.clamp(1, 200);
        let Some(id) = self.state.selected() else {
            return;
        };
        let Some(session) = self
            .entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
        else {
            return;
        };
        let (absolute_line, preview) = {
            let s = session.read(cx);
            let history = s.grid.scrollback_rows as i64;
            let row = s.cursor.1 as i64;
            let preview: String = s
                .line_text(row as i32)
                .unwrap_or_default()
                .trim_end()
                .chars()
                .take(80)
                .collect();
            (history + row, preview)
        };
        let next_id = self.next_bookmark_id;
        self.next_bookmark_id += 1;
        if let Some(entry) = self.entries.get_mut(&id) {
            make_room(&mut entry.bookmarks, max);
            entry.bookmarks.push(Bookmark {
                id: next_id,
                absolute_line,
                preview,
                time: SystemTime::now(),
                label,
            });
            log::info!("F17: Added bookmark for tab {id}");
        }
        cx.notify();
    }

    fn remove_bookmark(&mut self, tab: TabId, bookmark: u64, cx: &mut Context<Self>) {
        if let Some(entry) = self.entries.get_mut(&tab) {
            entry.bookmarks.retain(|b| b.id != bookmark);
        }
        cx.notify();
    }

    /// Scroll the tab so the bookmarked line is in the middle of the view.
    fn jump_to_bookmark(
        &mut self,
        tab: TabId,
        bookmark: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(mark) = self
            .entries
            .get(&tab)
            .and_then(|e| e.bookmarks.iter().find(|b| b.id == bookmark))
            .cloned()
        else {
            return;
        };
        if self.state.selected() != Some(tab) {
            self.select_tab(tab, window, cx);
        }
        if let Some(view) = self
            .entries
            .get(&tab)
            .and_then(|e| e.panes.read(cx).focused_view())
        {
            let session = view.read(cx).session.clone();
            {
                let s = session.read(cx);
                let history = s.grid.scrollback_rows as i64;
                let rows = s.grid.rows as i64;
                // Grid line now (negative = scrollback). Once the scrollback
                // is full, old lines drop off the top and this drifts.
                let line = mark.absolute_line - history;
                let wanted = (-line + rows / 2).clamp(0, history);
                let offset = s.grid.display_offset as i64;
                s.scroll_lines((wanted - offset) as i32);
            }
            session.update(cx, |s, cx| s.refresh(cx));
        }
        self.bookmarks_panel = None;
        self.focus_selected(window, cx);
        log::info!("F17: Jumped to bookmark {bookmark}");
        cx.notify();
    }

    pub(super) fn render_bookmarks(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let panel = self.bookmarks_panel.as_ref()?;
        let tab = self.state.selected()?;
        let bookmarks = self
            .entries
            .get(&tab)
            .map(|e| e.bookmarks.clone())
            .unwrap_or_default();
        let label_input = panel.label.clone();
        let rows: Vec<gpui::AnyElement> = bookmarks
            .iter()
            .map(|b| {
                let id = b.id;
                let time = chau7_next_core::tab_bar_text::short_time(b.time);
                div()
                    .id(("bookmark", id as usize))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py(px(6.0))
                    .rounded(px(6.0))
                    .bg(chrome.tab_bg)
                    .hover(|d| d.bg(chrome.tab_hover_bg))
                    .child(
                        div()
                            .text_xs()
                            .text_color(gpui::hsla(0.6, 0.9, 0.6, 1.0))
                            .child("🔖︎"),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .when_some(b.label.clone().filter(|l| !l.is_empty()), |d, l| {
                                d.child(
                                    div()
                                        .text_xs()
                                        .font_weight(gpui::FontWeight::MEDIUM)
                                        .child(l),
                                )
                            })
                            .child(
                                div()
                                    .text_xs()
                                    .font_family("Menlo")
                                    .text_color(chrome.text_muted)
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .text_ellipsis()
                                    .child(b.preview.clone()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(chrome.text_muted.opacity(0.7))
                                    .child(time),
                            ),
                    )
                    .child(
                        div()
                            .id(("bookmark-remove", id as usize))
                            .px_1()
                            .rounded_sm()
                            .text_xs()
                            .hover(|d| d.bg(chrome.tab_hover_bg))
                            .child("×")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                cx.stop_propagation();
                                this.remove_bookmark(tab, id, cx);
                            })),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.jump_to_bookmark(tab, id, window, cx)
                    }))
                    .into_any_element()
            })
            .collect();
        let empty = rows.is_empty();
        let content = div()
            .flex()
            .flex_col()
            .gap_2()
            .px(px(10.0))
            .pb(px(10.0))
            .key_context("Bookmarks")
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Bookmarks")),
                    )
                    .child(
                        button("bookmark-add", "Add", chrome, false).on_click(cx.listener(
                            move |this, _, window, cx| {
                                let text = label_input.read(cx).value().trim().to_string();
                                this.add_bookmark((!text.is_empty()).then_some(text), cx);
                                label_input.update(cx, |i, cx| i.set_value("", window, cx));
                            },
                        )),
                    )
                    .child(button("bookmark-close", "Close", chrome, false).on_click(
                        cx.listener(|this, _, window, cx| this.toggle_bookmarks(window, cx)),
                    )),
            )
            .child(chrome_input(&panel.label, chrome))
            .when(empty, |d| {
                d.child(
                    div()
                        .py_2()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("No bookmarks for this tab.")),
                )
            })
            .when(!empty, |d| {
                d.child(
                    div()
                        .id("bookmark-list")
                        .max_h(px(220.0))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .children(rows),
                )
            })
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted.opacity(0.7))
                    .child(if cfg!(target_os = "macos") {
                        "⌘B to add bookmark • Click to jump"
                    } else {
                        "Ctrl+Shift+B to add bookmark • Click to jump"
                    }),
            )
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.toggle_bookmarks(window, cx);
                }
            }))
            .into_any_element();
        Some(self.floating_panel(PanelKind::Bookmarks, 520.0, chrome, content, cx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(id: u64, label: Option<&str>) -> Bookmark {
        Bookmark {
            id,
            absolute_line: 0,
            preview: String::new(),
            time: SystemTime::UNIX_EPOCH,
            label: label.map(str::to_string),
        }
    }

    #[test]
    fn full_list_drops_oldest_unlabeled_then_newest() {
        let mut list = vec![mark(1, Some("a")), mark(2, None), mark(3, None)];
        make_room(&mut list, 3);
        assert_eq!(list.iter().map(|b| b.id).collect::<Vec<_>>(), vec![1, 3]);
        let mut list = vec![mark(1, Some("a")), mark(2, Some("b"))];
        make_room(&mut list, 2);
        assert_eq!(list.iter().map(|b| b.id).collect::<Vec<_>>(), vec![1]);
        let mut list = vec![mark(1, None)];
        make_room(&mut list, 5);
        assert_eq!(list.len(), 1);
    }
}

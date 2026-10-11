//! Find panel (`SearchOverlayView`): search the selected pane's scrollback,
//! highlight matches, case-sensitive (Aa) and regex (.*) toggles, the match
//! count, up to 12 matching lines with the query highlighted, "No results",
//! "Invalid regex" in orange, Prev and Next. The Aa and .* toggles start
//! from `search.defaultCaseSensitive` and `search.defaultRegex`; with
//! `feature.semanticSearch` on, a "Cmd" toggle searches the commands run in
//! the pane (command blocks) instead of the text, and disables Aa and .*.

use chau7_next_core::scrollback_search::{
    self, SearchOptions, highlight_ranges, refresh_debounce_ms,
};
use gpui::{
    Context, Div, Entity, EntityId, HighlightStyle, Stateful, StyledText, Subscription, Task,
    Window, div, prelude::*, px,
};
use gpui_kit::component::input::{InputEvent, InputState};

use super::Workspace;
use super::panel::PanelKind;
use super::widgets::{button, chrome_input};
use crate::actions::{FindNext, FindPrevious, ToggleSearch};
use crate::settings::Settings;
use crate::tab_bar::{StyleColor, style_color};
use crate::terminal::session::SessionEvent;
use crate::theme::Chrome;

pub(super) fn register_find_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &ToggleSearch, window, cx| this.toggle_search(window, cx)))
        .on_action(cx.listener(|this, _: &FindNext, window, cx| {
            if this.search.is_none() {
                this.toggle_search(window, cx);
            } else {
                this.find_step(1, window, cx);
            }
        }))
        .on_action(cx.listener(|this, _: &FindPrevious, window, cx| this.find_step(-1, window, cx)))
}

pub(super) struct SearchState {
    pub(super) input: Entity<InputState>,
    /// (grid line, column range); grid lines are negative in scrollback.
    matches: Vec<(i32, std::ops::Range<usize>)>,
    current: Option<usize>,
    /// Case sensitive, regular expression, whole word (TRM-052).
    options: SearchOptions,
    /// "Cmd": search past commands instead of the text (TRM-054), shown
    /// when `feature.semanticSearch` is on.
    semantic: bool,
    /// "Invalid regex".
    error: Option<String>,
    /// First matching lines (up to 12).
    preview: Vec<String>,
    /// Output of the searched session refreshes the matches (TRM-051).
    session_subscription: Option<(EntityId, Subscription)>,
    refresh_task: Option<Task<()>>,
    _subscription: Subscription,
}

impl Workspace {
    pub(super) fn toggle_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.search.take().is_some() {
            self.clear_highlights(cx);
            self.focus_selected(window, cx);
            cx.notify();
            return;
        }
        self.close_other_panels(Some(PanelKind::Search), cx);
        let input = cx
            .new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Search terminal")));
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::Change => this.refresh_search(cx),
                InputEvent::PressEnter { shift, .. } => {
                    this.find_step(if *shift { -1 } else { 1 }, window, cx)
                }
                _ => {}
            },
        );
        input.update(cx, |i, cx| i.focus(window, cx));
        self.panel_generation += 1;
        // `findCaseSensitiveDefault` / `findRegexDefault` (both off by default).
        let productivity = &Settings::get(cx).productivity;
        let options = SearchOptions {
            case_sensitive: productivity.find_case_sensitive,
            regex: productivity.find_regex,
            ..SearchOptions::default()
        };
        self.search = Some(SearchState {
            input,
            matches: Vec::new(),
            current: None,
            options,
            semantic: false,
            error: None,
            preview: Vec::new(),
            session_subscription: None,
            refresh_task: None,
            _subscription: subscription,
        });
        cx.notify();
    }

    /// Open the find bar with `query` (Use Selection for Find, Cmd+E).
    pub(super) fn search_for(&mut self, query: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.search.is_none() {
            self.toggle_search(window, cx);
        }
        if let Some(search) = self.search.as_ref() {
            // A multi-line selection searches for its first line.
            let query = query.lines().next().unwrap_or("").to_string();
            search
                .input
                .update(cx, |input, cx| input.set_value(query, window, cx));
        }
        self.refresh_search(cx);
    }

    pub(super) fn refresh_search(&mut self, cx: &mut Context<Self>) {
        let Some(session) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
        else {
            return;
        };
        let Some(search) = self.search.as_mut() else {
            return;
        };
        // Follow the searched session's output (debounced by buffer size).
        if search.session_subscription.as_ref().map(|(id, _)| *id) != Some(session.entity_id()) {
            let subscription = cx.subscribe(&session, |this, session, event, cx| {
                if !matches!(event, SessionEvent::Output) {
                    return;
                }
                let Some(search) = this.search.as_mut() else {
                    return;
                };
                if search.refresh_task.is_some() || search.input.read(cx).value().is_empty() {
                    return;
                }
                let lines = {
                    let s = session.read(cx);
                    s.grid.scrollback_rows as usize + s.grid.rows as usize
                };
                let delay = std::time::Duration::from_millis(refresh_debounce_ms(lines));
                search.refresh_task = Some(cx.spawn(async move |this, cx| {
                    cx.background_executor().timer(delay).await;
                    let _ = this.update(cx, |this, cx| {
                        if let Some(search) = this.search.as_mut() {
                            search.refresh_task = None;
                        }
                        this.update_matches(false, cx);
                    });
                }));
            });
            search.session_subscription = Some((session.entity_id(), subscription));
        }
        self.update_matches(true, cx);
    }

    /// Recomputes the matches. `reset`: the query or options changed, so the
    /// current match goes back to the last one.
    fn update_matches(&mut self, reset: bool, cx: &mut Context<Self>) {
        let Some(session) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
        else {
            return;
        };
        let Some(search) = self.search.as_mut() else {
            return;
        };
        let query = search.input.read(cx).value().to_string();
        let semantic = search.semantic && Settings::get(cx).productivity.semantic_search;
        let session = session.read(cx);
        search.matches.clear();
        search.preview.clear();
        search.error = None;
        if !query.is_empty() && semantic {
            // `updateSemanticSearch`: commands containing the query, first
            // match current, previews "cmd (exit N)".
            let history = session.grid.scrollback_rows as i64;
            let (found, previews) = session.semantic_search(&query, 400, 12);
            let text_at = |abs: i64| {
                i32::try_from(abs - history)
                    .ok()
                    .and_then(|l| session.line_text(l))
            };
            search.matches = found
                .into_iter()
                .filter_map(|m| {
                    // Highlight the command where it was typed.
                    let abs = chau7_next_core::semantic_search::locate_command_line(
                        m.line, &m.command, text_at,
                    );
                    let needle: String = m.command.trim().chars().take(40).collect();
                    let col = text_at(abs)
                        .and_then(|t| t.find(&needle).map(|b| t[..b].chars().count()))
                        .unwrap_or(0);
                    let line = i32::try_from(abs - history).ok()?;
                    Some((line, col..col + m.length))
                })
                .collect();
            search.preview = previews;
            if reset || search.current.is_none_or(|c| c >= search.matches.len()) {
                search.current = (!search.matches.is_empty()).then_some(0);
            }
            self.apply_highlights(cx);
            cx.notify();
            return;
        }
        if !query.is_empty() {
            let history = session.grid.scrollback_rows as i32;
            let rows = session.grid.rows as i32;
            let lines: Vec<(i32, String)> = ((-history)..rows)
                .filter_map(|line| session.line_text(line).map(|t| (line, t)))
                .collect();
            let summary = scrollback_search::search_with(&lines, &query, search.options);
            search.matches = summary.matches;
            search.preview = summary.preview;
            search.error = summary.error;
        }
        if reset || search.current.is_none_or(|c| c >= search.matches.len()) {
            search.current = search.matches.len().checked_sub(1);
        }
        self.apply_highlights(cx);
        cx.notify();
    }

    fn toggle_option(&mut self, change: fn(&mut SearchOptions), cx: &mut Context<Self>) {
        if let Some(search) = self.search.as_mut() {
            // Aa and .* are disabled during a semantic search.
            if search.semantic {
                return;
            }
            change(&mut search.options);
        }
        self.refresh_search(cx);
    }

    fn toggle_semantic(&mut self, cx: &mut Context<Self>) {
        if let Some(search) = self.search.as_mut() {
            search.semantic = !search.semantic;
        }
        self.refresh_search(cx);
    }

    pub(super) fn find_step(&mut self, delta: isize, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(search) = self.search.as_mut() else {
            return;
        };
        if search.matches.is_empty() {
            return;
        }
        let len = search.matches.len() as isize;
        let next = search
            .current
            .map(|c| c as isize + delta)
            .unwrap_or(0)
            .rem_euclid(len);
        search.current = Some(next as usize);
        self.apply_highlights(cx);
        cx.notify();
    }

    pub(super) fn apply_highlights(&mut self, cx: &mut Context<Self>) {
        let Some(search) = self.search.as_ref() else {
            return;
        };
        let Some(view) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_view())
        else {
            return;
        };
        let session = view.read(cx).session.clone();
        // Scroll so the current match is visible.
        if let Some((line, _)) = search.current.and_then(|i| search.matches.get(i)) {
            let s = session.read(cx);
            let rows = s.grid.rows as i32;
            let offset = s.grid.display_offset as i32;
            let viewport_row = line + offset;
            if viewport_row < 0 || viewport_row >= rows {
                let wanted = (-line + rows / 2).max(0);
                s.scroll_lines(wanted - offset);
            }
            session.update(cx, |s, cx| s.refresh(cx));
        }
        // Matches are kept as absolute lines (scrollback size + grid line),
        // so the view keeps them on their text while it scrolls and while
        // new output arrives (`TerminalHighlightView`).
        let history = session.read(cx).grid.scrollback_rows as i64;
        let matches: Vec<(i64, std::ops::Range<usize>)> = search
            .matches
            .iter()
            .map(|(line, range)| (history + *line as i64, range.clone()))
            .collect();
        let active = search.current;
        view.update(cx, |v, cx| {
            v.search_matches = matches;
            v.active_match = active;
            cx.notify();
        });
    }

    pub(super) fn clear_highlights(&mut self, cx: &mut Context<Self>) {
        for entry in self.entries.values() {
            for view in entry.panes.read(cx).views() {
                view.update(cx, |v, cx| {
                    v.search_matches.clear();
                    v.active_match = None;
                    cx.notify();
                });
            }
        }
    }

    pub(super) fn render_search(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let search = self.search.as_ref()?;
        let query = search.input.read(cx).value().to_string();
        // The "Cmd" toggle shows only with `feature.semanticSearch` on, and
        // turns the other options off while it is on (Swift disables them).
        let semantic_available = Settings::get(cx).productivity.semantic_search;
        let semantic = search.semantic && semantic_available;
        let orange = style_color(StyleColor::Orange, chrome.text);
        let option = |id: &'static str, label: &'static str, on: bool, label_a11y: &'static str| {
            div()
                .id(id)
                .px_2()
                .py(px(2.0))
                .rounded_md()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .border_1()
                .border_color(if on { chrome.accent } else { chrome.border })
                .bg(if on {
                    chrome.accent.opacity(0.25)
                } else {
                    chrome.tab_bg
                })
                .role(gpui::Role::Button)
                .aria_label(label_a11y)
                .aria_toggled(if on {
                    gpui::Toggled::True
                } else {
                    gpui::Toggled::False
                })
                .child(label)
        };
        let results: gpui::AnyElement = if let Some(error) = &search.error {
            div()
                .text_xs()
                .text_color(orange)
                .child(error.clone())
                .into_any_element()
        } else if search.preview.is_empty() && !query.is_empty() {
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr("No results"))
                .into_any_element()
        } else {
            let case_sensitive = search.options.case_sensitive;
            let regex = search.options.regex;
            div()
                .id("search-results")
                .max_h(px(220.0))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap_1()
                .children(search.preview.iter().map(|line| {
                    // `SearchResultRow`: the query highlighted, except for regex.
                    let ranges = if regex {
                        Vec::new()
                    } else {
                        highlight_ranges(line, &query, case_sensitive)
                    };
                    let byte_ranges: Vec<(std::ops::Range<usize>, HighlightStyle)> = ranges
                        .into_iter()
                        .map(|r| {
                            let start = line.char_indices().nth(r.start).map(|(i, _)| i);
                            let end = line
                                .char_indices()
                                .nth(r.end)
                                .map(|(i, _)| i)
                                .unwrap_or(line.len());
                            (
                                start.unwrap_or(line.len())..end,
                                HighlightStyle {
                                    color: Some(gpui::white()),
                                    background_color: Some(orange.opacity(0.6)),
                                    ..Default::default()
                                },
                            )
                        })
                        .collect();
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .child(StyledText::new(line.clone()).with_highlights(byte_ranges))
                }))
                .into_any_element()
        };
        let count = crate::l10n::count("search.matches", "%d matches", search.matches.len());
        let content = div()
            .flex()
            .flex_col()
            .gap_2()
            .px(px(10.0))
            .pb(px(10.0))
            .key_context("SearchBar")
            .text_xs()
            .text_color(chrome.text_muted)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().child(chrome_input(&search.input, chrome)))
                    .child(count)
                    .child(
                        option(
                            "find-case",
                            "Aa",
                            search.options.case_sensitive,
                            "Case sensitive",
                        )
                        .when(semantic, |d| d.opacity(0.4))
                        .when(!semantic, |d| {
                            d.on_click(cx.listener(|this, _, _, cx| {
                                this.toggle_option(|o| o.case_sensitive = !o.case_sensitive, cx)
                            }))
                        }),
                    )
                    .child(
                        option(
                            "find-regex",
                            ".*",
                            search.options.regex,
                            "Regular expression search",
                        )
                        .when(semantic, |d| d.opacity(0.4))
                        .when(!semantic, |d| {
                            d.on_click(cx.listener(|this, _, _, cx| {
                                this.toggle_option(|o| o.regex = !o.regex, cx)
                            }))
                        }),
                    )
                    .when(semantic_available, |d| {
                        d.child(
                            option("find-semantic", "Cmd", semantic, "Semantic command search")
                                .tooltip(|window, cx| {
                                    gpui_kit::component::tooltip::Tooltip::new(
                                        "Semantic command search",
                                    )
                                    .build(window, cx)
                                })
                                .on_click(cx.listener(|this, _, _, cx| this.toggle_semantic(cx))),
                        )
                    })
                    .child(
                        option("find-word", "W", search.options.whole_word, "Whole word")
                            .when(semantic, |d| d.opacity(0.4))
                            .when(!semantic, |d| {
                                d.on_click(cx.listener(|this, _, _, cx| {
                                    this.toggle_option(|o| o.whole_word = !o.whole_word, cx)
                                }))
                            }),
                    )
                    .child(
                        button("find-close", "Close", chrome, false)
                            .on_click(cx.listener(|this, _, w, cx| this.toggle_search(w, cx))),
                    ),
            )
            .child(results)
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        button("find-prev", "Prev", chrome, false)
                            .aria_label("Previous match")
                            .on_click(cx.listener(|this, _, w, cx| this.find_step(-1, w, cx))),
                    )
                    .child(
                        button("find-next", "Next", chrome, false)
                            .aria_label("Next match")
                            .on_click(cx.listener(|this, _, w, cx| this.find_step(1, w, cx))),
                    ),
            )
            .into_any_element();
        Some(self.floating_panel(PanelKind::Search, 560.0, chrome, content, cx))
    }
}

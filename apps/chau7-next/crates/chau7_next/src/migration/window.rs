//! The import wizard window: Welcome, Scanning, Selection, Importing,
//! Complete (`TerminalMigrationWizardView`).

use chau7_next_core::terminal_import::{
    ImportableProfile, Outcome, ProfileSource, Step, Wizard, scan_home,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, FontWeight, Global, IntoElement, Render, SharedString,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use crate::debug::ui::button;
use crate::theme::Chrome;
use crate::workspace::AppData;

const TITLE: &str = "Import from Other Terminals";

#[derive(Default)]
struct WizardWindow(Option<AnyWindowHandle>);
impl Global for WizardWindow {}

pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<WizardWindow>().and_then(|w| w.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(520.0), px(560.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(420.0), px(420.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |_, cx| cx.new(|_| WizardView::default())) {
        Ok((handle, _)) => cx.set_global(WizardWindow(Some(handle))),
        Err(err) => log::error!("import wizard: {err}"),
    }
}

#[derive(Default)]
struct WizardView {
    wizard: Wizard,
}

impl WizardView {
    fn scan(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.wizard.start_scan();
        let home = cx.global::<AppData>().root.home().to_path_buf();
        let families = window.text_system().all_font_names();
        let task = cx
            .background_executor()
            .spawn(async move { scan_home(&home, &families) });
        cx.spawn(async move |this, cx| {
            let found = task.await;
            let _ = this.update(cx, |this, cx| {
                this.wizard.finish_scan(found);
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn import(&mut self, cx: &mut Context<Self>) {
        if self.wizard.selected_count() == 0 {
            return;
        }
        self.wizard.start_import();
        let chosen = self.wizard.selected_profiles();
        super::import_profiles(&chosen, cx);
        self.wizard.finish_import();
        cx.notify();
    }
}

fn source_glyph(source: ProfileSource) -> &'static str {
    match source {
        ProfileSource::TerminalApp => "\u{25A2}",
        ProfileSource::ITerm2 => "\u{25A5}",
    }
}

impl Render for WizardView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        window.set_window_title(TITLE);
        let step = self.wizard.step;
        let header = div()
            .flex()
            .flex_col()
            .items_center()
            .gap_1()
            .pt_4()
            .child(
                div()
                    .text_xl()
                    .font_weight(FontWeight::BOLD)
                    .child(crate::l10n::tr("Import Your Settings")),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(chrome.text_muted)
                    .child(step.description()),
            );

        let body = match step {
            Step::Welcome => self.welcome_page(chrome, cx).into_any_element(),
            Step::Scanning => note("Scanning...", chrome).into_any_element(),
            Step::Selection => self.selection_page(chrome, cx).into_any_element(),
            Step::Importing => note(
                &crate::l10n::count(
                    "migration.importing",
                    "Importing %d profiles...",
                    self.wizard.selected_count(),
                ),
                chrome,
            )
            .into_any_element(),
            Step::Complete => self.complete_page(chrome).into_any_element(),
        };

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(TitleBar::new().child(div().text_sm().child(TITLE)))
            .child(header)
            .child(div().flex_1().min_h_0().p_4().child(body))
    }
}

fn note(text: &str, chrome: Chrome) -> gpui::Div {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_sm()
        .text_color(chrome.text_muted)
        .child(text.to_string())
}

impl WizardView {
    fn welcome_page(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let source = |source: ProfileSource| {
            div()
                .flex()
                .gap_3()
                .items_center()
                .child(div().w(px(24.0)).text_center().child(source_glyph(source)))
                .child(source.display_name())
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .gap_4()
            .child(
                div()
                    .text_sm()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("Chau7 Next can look for profiles in:")),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(source(ProfileSource::TerminalApp))
                    .child(source(ProfileSource::ITerm2)),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child("Their preference files are only read. Each profile you pick becomes a settings profile named \"Imported: <name>\"; your current settings stay as they are."),
            )
            .child(div().flex_1())
            .child(
                button("import-scan", "Scan for Profiles", chrome)
                    .bg(chrome.accent)
                    .text_color(gpui::white())
                    .on_click(cx.listener(|this, _, window, cx| this.scan(window, cx))),
            )
    }

    fn selection_page(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        let rows = self.wizard.profiles.iter().map(|p: &ImportableProfile| {
            let id = p.id;
            let on = self.wizard.is_selected(id);
            div()
                .id(SharedString::from(format!("import-{id}")))
                .flex()
                .gap_3()
                .items_center()
                .px_2()
                .py_1p5()
                .rounded_md()
                .cursor_pointer()
                .border_1()
                .border_color(if on { chrome.accent } else { chrome.border })
                .bg(chrome.tab_bg)
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(if on { "\u{2611}" } else { "\u{2610}" })
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(div().text_sm().child(p.name.clone()))
                        .child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(p.summary()),
                        ),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.wizard.toggle(id);
                    cx.notify();
                }))
        });
        let enabled = self.wizard.selected_count() > 0;
        div()
            .size_full()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().text_sm().child(crate::l10n::count(
                        "migration.foundProfiles",
                        "Found %d profiles",
                        self.wizard.profiles.len(),
                    )))
                    .child(div().flex_1())
                    .child(
                        button("import-all", "Select All", chrome).on_click(cx.listener(
                            |this, _, _, cx| {
                                this.wizard.select_all();
                                cx.notify();
                            },
                        )),
                    )
                    .child(
                        button("import-none", "Deselect All", chrome).on_click(cx.listener(
                            |this, _, _, cx| {
                                this.wizard.deselect_all();
                                cx.notify();
                            },
                        )),
                    ),
            )
            .child(
                div()
                    .id("import-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .children(rows),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::count(
                                "migration.selectedCount",
                                "%d selected",
                                self.wizard.selected_count(),
                            )),
                    )
                    .child(div().flex_1())
                    .child(
                        button(
                            "import-go",
                            crate::l10n::count(
                                "migration.importButton",
                                "Import %d Profiles",
                                self.wizard.selected_count(),
                            ),
                            chrome,
                        )
                        .when(enabled, |d| d.bg(chrome.accent).text_color(gpui::white()))
                        .when(!enabled, |d| d.opacity(0.4).cursor_default())
                        .on_click(cx.listener(|this, _, _, cx| this.import(cx))),
                    ),
            )
    }

    fn complete_page(&self, chrome: Chrome) -> gpui::Div {
        let (title, detail) = match self.wizard.outcome {
            Some(Outcome::Imported) => (
                "Import Complete".to_string(),
                format!(
                    "{} imported. Find them under Settings > Profiles.",
                    if self.wizard.selected_count() == 1 {
                        "1 profile was".to_string()
                    } else {
                        format!("{} profiles were", self.wizard.selected_count())
                    }
                ),
            ),
            _ => (
                "No Profiles Found".to_string(),
                "No Terminal.app or iTerm2 profiles were found in your preferences.".to_string(),
            ),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_2()
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(div().text_sm().text_color(chrome.text_muted).child(detail))
            .child(
                button("import-done", "Done", chrome)
                    .mt_3()
                    .on_click(|_, window, _| window.remove_window()),
            )
    }
}

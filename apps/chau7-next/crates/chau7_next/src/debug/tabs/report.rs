//! Report tab (`reportView`): a description box, the GitHub report, local
//! reports and snapshots, and the quick actions.

use chau7_next_core::debug_console::Tone;
use gpui::{AnyElement, ClipboardItem, Context, IntoElement, div, prelude::*};
use gpui_kit::component::input::Textarea;

use crate::debug::console::DebugConsole;
use crate::debug::{registry, snapshot, ui};
use crate::theme::Chrome;
use crate::workspace::AppData;

impl DebugConsole {
    pub(in crate::debug) fn report_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let description_box =
            ui::group("Generate Bug Report", chrome)
                .child(
                    div()
                        .text_xs()
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(crate::l10n::tr("Describe the issue:")),
                )
                // The field has the group's background: a border shows where it is.
                .child(
                    div()
                        .rounded_md()
                        .border_1()
                        .border_color(chrome.border)
                        .bg(chrome.panel_bg)
                        .child(Textarea::new(&self.report_input).h(gpui::px(100.0))),
                )
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_2()
                        .child(
                            ui::button("report-github", "Generate Github Report", chrome)
                                .bg(chrome.accent.opacity(0.35))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    let text = this.report_input.read(cx).value().to_string();
                                    let url = snapshot::issue_url(&text, cx);
                                    this.last_report = Some(url.clone());
                                    cx.open_url(&url);
                                    cx.notify();
                                })),
                        )
                        .child(ui::button("report-save", "Save Report", chrome).on_click(
                            cx.listener(|this, _, _, cx| {
                                let text = this.report_input.read(cx).value().to_string();
                                this.last_report = match snapshot::save_report(&text, cx) {
                                    Ok(path) => Some(path.display().to_string()),
                                    Err(err) => {
                                        log::warn!("save report: {err}");
                                        None
                                    }
                                };
                                cx.notify();
                            }),
                        ))
                        .child(
                            ui::button("report-folder", "Open Reports Folder", chrome).on_click(
                                |_, _, cx| open_dir(cx.global::<AppData>().root.reports_dir(), cx),
                            ),
                        )
                        .child(
                            ui::button("report-dialog", "Report an Issue...", chrome)
                                .on_click(|_, _, cx| crate::debug::report_window::open(cx)),
                        ),
                )
                .when_some(self.last_report.clone(), |d, path| {
                    d.child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_xs()
                            .child(
                                div()
                                    .text_color(ui::tone_color(Tone::Good, chrome))
                                    .child("\u{2713}"),
                            )
                            .child(crate::l10n::tr("Report draft:"))
                            .child(
                                div()
                                    .min_w_0()
                                    .overflow_hidden()
                                    .font_family("Menlo")
                                    .child(path),
                            ),
                    )
                });

        let quick = ui::group("Quick Actions", chrome).child(
            div()
                .flex()
                .flex_wrap()
                .gap_3()
                .child(
                    ui::button("report-snapshot", "Capture Snapshot", chrome).on_click(
                        cx.listener(|this, _, _, cx| {
                            let snap = snapshot::capture(cx);
                            if let Ok(path) = snapshot::save_snapshot(&snap, cx) {
                                this.last_report = Some(path.display().to_string());
                            }
                            cx.notify();
                        }),
                    ),
                )
                .child(
                    ui::button("report-copy", "Copy State JSON", chrome).on_click(|_, _, cx| {
                        let json = snapshot::capture(cx).to_json();
                        cx.write_to_clipboard(ClipboardItem::new_string(json));
                    }),
                )
                .child(
                    ui::button("report-clear", "Clear Event History", chrome)
                        .text_color(ui::tone_color(Tone::Bad, chrome))
                        .on_click(|_, _, cx| registry::clear_events(cx)),
                ),
        );

        ui::page(
            "report-page",
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(description_box)
                .child(quick),
        )
        .into_any_element()
    }
}

/// Open a folder in the file manager, creating it first.
fn open_dir(dir: std::path::PathBuf, cx: &mut gpui::App) {
    let _ = std::fs::create_dir_all(&dir);
    cx.open_url(&format!("file://{}", dir.display()));
}

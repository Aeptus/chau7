//! Health tab (`healthDashboardView`): tabs and shell integration, log
//! sizes, rendering info, and the sections other modules register (for
//! example notification reliability).

use std::path::Path;

use chau7_next_core::debug_console::{Tone, format_log_size, log_size_warns};
use gpui::{AnyElement, Context, IntoElement, div, prelude::*};

use crate::debug::console::DebugConsole;
use crate::debug::{registry, snapshot, ui};
use crate::settings::Settings;
use crate::theme::Chrome;
use crate::workspace::AppData;

/// `(file name, size)` of the `.log` files in `dir`.
fn log_sizes(dir: &Path, prefix: &str) -> Vec<(String, u64)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.ends_with(".log") {
                return None;
            }
            let size = entry.metadata().ok()?.len();
            Some((format!("{prefix}{name}"), size))
        })
        .collect()
}

fn health_row(
    label: impl Into<gpui::SharedString>,
    value: impl Into<gpui::SharedString>,
    warn: bool,
    chrome: Chrome,
) -> gpui::Div {
    ui::value_row(label, value, warn.then_some(Tone::Bad), chrome)
}

impl DebugConsole {
    /// `loadHealthData`: sizes of the app log, the dumps and the AI PTY logs,
    /// biggest first.
    pub(in crate::debug) fn load_health(&mut self, cx: &mut Context<Self>) {
        let Some(data) = cx.try_global::<AppData>() else {
            return;
        };
        let state_dir = data.root.state_dir().to_path_buf();
        let ai_dir = data.root.ai_logs_dir();
        let app_log = crate::logging::file_path();
        let mut files = log_sizes(&state_dir, "");
        if let Some(path) = app_log
            && path.parent() != Some(state_dir.as_path())
            && let Some(size) = std::fs::metadata(&path).ok().map(|m| m.len())
        {
            files.push((path.display().to_string(), size));
        }
        files.extend(log_sizes(&ai_dir, "ai-logs/"));
        files.sort_by_key(|f| std::cmp::Reverse(f.1));
        self.log_files = files;
    }

    pub(in crate::debug) fn health_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tabs = snapshot::tabs(cx);
        let total = tabs.len();
        let idle = tabs.iter().filter(|t| t.idle).count();
        let integrated = tabs.iter().filter(|t| t.shell_integration).count();
        let suspended = tabs.iter().filter(|t| t.render_suspended).count();

        let session = ui::group("Session Overview", chrome)
            .child(health_row(
                "Tabs",
                // Idle here means no activity for 10 minutes (Swift's rule), not
                // the command state shown in the State tab.
                format!(
                    "{total} total, {idle} idle (10+ min), {} active",
                    total - idle
                ),
                false,
                chrome,
            ))
            .child(health_row(
                "Shell integration (OSC 133)",
                format!("{integrated}/{total} tabs"),
                false,
                chrome,
            ))
            .child(health_row(
                "Suspended tabs",
                suspended.to_string(),
                false,
                chrome,
            ));

        let mut logs = ui::group("PTY Logs", chrome);
        for (name, size) in &self.log_files {
            logs = logs.child(health_row(
                name.clone(),
                format_log_size(*size),
                log_size_warns(*size),
                chrome,
            ));
        }
        if self.log_files.is_empty() {
            logs = logs.child(ui::caption("No PTY logs", chrome));
        }

        let ligatures = Settings::get(cx).appearance.ligatures;
        let rendering = ui::group("Rendering", chrome)
            .child(health_row("Atlas mode", "Per-renderer", false, chrome))
            .child(health_row(
                "Ligatures enabled",
                if ligatures { "Yes" } else { "No" },
                false,
                chrome,
            ));

        let mut page = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(session)
            .child(logs)
            .child(rendering);
        for (title, rows) in registry::health_sections(cx) {
            let mut group = ui::group(title, chrome);
            for row in rows {
                group = group.child(ui::value_row(row.label, row.value, row.tone, chrome));
            }
            page = page.child(group);
        }
        ui::page("health-page", page).into_any_element()
    }
}

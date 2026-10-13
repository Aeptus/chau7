//! On-demand numeric terminal memory attribution. No history buffers are copied.
use crate::{
    debug::{
        registry::{Panel, register_panel},
        ui,
    },
    theme::Chrome,
};
use gpui::{
    App, ClipboardItem, Context, Entity, Global, IntoElement, Render, Window, div, prelude::*,
};
use serde_json::Value;

struct MemoryPanel(Entity<MemoryView>);
impl Global for MemoryPanel {}
struct MemoryView {
    snapshot: Option<Value>,
    status: Option<String>,
}

pub fn register(cx: &mut App) {
    let entity = cx.new(|_| MemoryView {
        snapshot: None,
        status: None,
    });
    cx.set_global(MemoryPanel(entity));
    register_panel(
        cx,
        Panel::new("memory", "Memory", |_, cx| {
            let entity = cx.global::<MemoryPanel>().0.clone();
            if entity.read(cx).snapshot.is_none() {
                entity.update(cx, |view, cx| view.snapshot = Some(capture(cx)));
            }
            entity.into_any_element()
        }),
    );
}
fn capture(cx: &App) -> Value {
    let mut snapshot = crate::performance::capture(cx);
    snapshot["process"]["physical_footprint_bytes"] =
        serde_json::json!(crate::memory_pressure::physical_footprint_bytes());
    snapshot["diagnostic_kind"] = serde_json::json!("memory");
    snapshot["memory_report"] = serde_json::json!({
        "gpu_instance_buffer_bytes":Value::Null, "gpu_atlas_texture_bytes":Value::Null,
        "gpu_triple_buffer_bytes":Value::Null,
        "coverage":"Known CPU capacities and retained pixel payloads. Native ring bytes are estimates; allocator/HashMap overhead, pending native images and private GPUI GPU resources are unavailable. Shared glyph pixels are counted once, outside terminal entries."
    });
    snapshot
}
fn bytes(value: &Value) -> String {
    value
        .as_u64()
        .map(|bytes| {
            chau7_next_core::l10n::formatters::file_size(chau7_next_core::l10n::current(), bytes)
        })
        .unwrap_or_else(|| "Unavailable".into())
}
fn ordered_terminals(snapshot: &Value) -> Vec<&Value> {
    let mut entries = snapshot["terminals"]
        .as_array()
        .map(|items| items.iter().collect::<Vec<_>>())
        .unwrap_or_default();
    entries.sort_by_key(|entry| {
        std::cmp::Reverse(
            entry["memory"]["native_ring_estimated_bytes"]
                .as_u64()
                .unwrap_or(0)
                .saturating_add(
                    entry["memory"]["known_session_capacity_bytes"]
                        .as_u64()
                        .unwrap_or(0),
                ),
        )
    });
    entries
}
impl Render for MemoryView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let controls = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .child(
                ui::button("memory-refresh", "Refresh", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.snapshot = Some(capture(cx));
                        this.status = None;
                        cx.notify();
                    },
                )),
            )
            .child(
                ui::button("memory-copy", "Copy JSON", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        if let Some(snapshot) = &this.snapshot
                            && let Ok(json) = serde_json::to_string_pretty(snapshot)
                        {
                            cx.write_to_clipboard(ClipboardItem::new_string(json));
                            this.status = Some("Numeric snapshot copied.".into());
                            cx.notify();
                        }
                    },
                )),
            )
            .child(
                ui::button("memory-save", "Save Snapshot", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        if let Some(snapshot) = &this.snapshot {
                            this.status = Some(
                                if crate::performance::persist(snapshot.clone(), cx) {
                                    "Snapshot queued in the performance folder."
                                } else {
                                    "Performance writer unavailable or busy; try again."
                                }
                                .into(),
                            );
                            cx.notify();
                        }
                    },
                )),
            )
            .child(
                ui::button("memory-folder", "Open Performance Folder", chrome).on_click(
                    |_, _, cx| {
                        cx.open_with_system(&crate::performance::directory(cx));
                    },
                ),
            );
        let mut body = div().flex().flex_col().gap_3().child(controls);
        if let Some(status) = &self.status {
            body = body.child(ui::caption(status.clone(), chrome));
        }
        let Some(snapshot) = &self.snapshot else {
            return ui::page(
                "memory-page",
                body.child(ui::caption(
                    "Refresh to capture memory attribution.",
                    chrome,
                )),
            );
        };
        let captured = snapshot["captured_at"].as_str().unwrap_or("Unavailable");
        body = body.child(ui::caption(
            format!(
                "Captured {captured}. Refresh collects a new snapshot; this panel does not poll."
            ),
            chrome,
        ));
        let process = &snapshot["process"];
        let shared = &snapshot["memory_retention"];
        body = body.child(
            ui::group("Process and Shared Resources", chrome)
                .child(ui::state_row(
                    "Resident memory",
                    bytes(&process["resident_bytes"]),
                    chrome,
                ))
                .child(ui::state_row(
                    "Physical footprint",
                    bytes(&process["physical_footprint_bytes"]),
                    chrome,
                ))
                .child(ui::state_row(
                    "Shared CPU glyph pixels",
                    bytes(&shared["cpu_glyph_cache_bytes"]),
                    chrome,
                ))
                .child(ui::state_row(
                    "Shared CPU glyph entries",
                    shared["cpu_glyph_cache_entries"]
                        .as_u64()
                        .map(|count| chau7_next_core::l10n::numbers::integer(count as i64))
                        .unwrap_or_else(|| "Unavailable".into()),
                    chrome,
                ))
                .child(ui::caption(
                    snapshot["memory_report"]["coverage"].as_str().unwrap_or(""),
                    chrome,
                )),
        );
        let entries = ordered_terminals(snapshot);
        let mut terminals = ui::group("Terminal Panes", chrome);
        if entries.is_empty() {
            terminals = terminals.child(ui::caption("No terminal measurements available.", chrome));
        }
        for terminal in entries {
            let memory = &terminal["memory"];
            let tab = terminal["tab_id"].as_str().unwrap_or("?");
            let pane = terminal["pane_id"].as_str().unwrap_or("?");
            let window = terminal["window_id"].as_u64().map_or(0, |id| id + 1);
            let phase = memory["render_phase"].as_str().unwrap_or("unobserved");
            terminals = terminals.child(
                ui::group(format!("Window {window}, tab {tab}, pane {pane}"), chrome)
                    .child(ui::state_row("Render phase", phase, chrome))
                    .child(ui::state_row(
                        "Grid / retained history rows",
                        format!(
                            "{} x {}, {} history",
                            memory["grid_cols"], memory["grid_rows"], memory["history_rows"]
                        ),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Native ring (estimate)",
                        bytes(&memory["native_ring_estimated_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "UI grid cells (capacity)",
                        bytes(&memory["ui_grid_cells_capacity_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Cluster strings (capacity)",
                        bytes(&memory["ui_grid_cluster_string_capacity_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Pending output (capacity)",
                        bytes(&memory["pending_output_capacity_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Pending input (capacity)",
                        bytes(&memory["pending_input_capacity_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Restoration preview (capacity)",
                        bytes(&memory["restoration_preview_capacity_bytes"]),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Refresh cap interval",
                        if memory["display_native_refresh"] == true {
                            "Display Native".into()
                        } else {
                            memory["refresh_cap_interval_ms"]
                                .as_f64()
                                .map(|ms| {
                                    format!("{} ms", chau7_next_core::l10n::numbers::decimal(ms, 3))
                                })
                                .unwrap_or_else(|| "Unavailable".into())
                        },
                        chrome,
                    )),
            );
        }
        body = body.child(terminals);
        if snapshot["terminals_truncated"] == true {
            body = body.child(ui::caption(
                "Terminal list reached the diagnostic snapshot limit.",
                chrome,
            ));
        }
        let mut renderers = ui::group("Terminal Renderers", chrome);
        if let Some(samples) = shared["renderer_samples"].as_array() {
            for sample in samples {
                let renderer = &sample["renderer"];
                let images = &renderer["inline_images"];
                renderers = renderers.child(
                    ui::group(format!("Session {}", sample["session_id"]), chrome)
                        .child(ui::state_row(
                            "Observed renderer",
                            renderer["actual_renderer"]
                                .as_str()
                                .unwrap_or("Not painted yet"),
                            chrome,
                        ))
                        .child(ui::state_row(
                            "CPU bitmap pixels",
                            bytes(&renderer["cached_cpu_bitmap_bytes"]),
                            chrome,
                        ))
                        .child(ui::state_row(
                            "Inline RGBA capacity",
                            bytes(&images["rgba_capacity_bytes"]),
                            chrome,
                        ))
                        .child(ui::state_row(
                            "Inline render pixels",
                            bytes(&images["retained_render_pixel_bytes"]),
                            chrome,
                        ))
                        .child(ui::state_row(
                            "Inline metadata / placements capacity",
                            bytes(
                                &images["image_slot_capacity_bytes"]
                                    .as_u64()
                                    .zip(images["placement_slot_capacity_bytes"].as_u64())
                                    .map(|(a, b)| serde_json::json!(a.saturating_add(b)))
                                    .unwrap_or(Value::Null),
                            ),
                            chrome,
                        )),
                );
            }
        }
        body = body.child(renderers).child(ui::caption("GPU instance buffers, atlas textures and triple buffers: unavailable through GPUI. No zero allocation is inferred.", chrome));
        ui::page("memory-page", body)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn memory_display_preserves_unknown_values_and_orders_estimate_separately() {
        assert_eq!(bytes(&Value::Null), "Unavailable");
        assert_ne!(bytes(&serde_json::json!(0)), "Unavailable");
        let value = serde_json::json!({"terminals":[
            {"pane_id":"small","memory":{"native_ring_estimated_bytes":10,"known_session_capacity_bytes":20}},
            {"pane_id":"large","memory":{"native_ring_estimated_bytes":100,"known_session_capacity_bytes":1}}
        ]});
        assert_eq!(ordered_terminals(&value)[0]["pane_id"], "large");
    }
}

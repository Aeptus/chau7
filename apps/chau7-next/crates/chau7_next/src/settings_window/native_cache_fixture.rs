//! Real native Settings cache acceptance in the common runner's fresh profile.
//! It opens only an owned history store/writer; no provider history integration.
use super::*;
use anyhow::{Context as _, Result, ensure};
use chau7_next_core::{history_record::HistoryRecord, snippet_store::Snippet};
use gpui::{AppContext, AsyncApp};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

pub(crate) async fn verify_native_cache_fixture(cx: &mut AsyncApp) -> Result<Value, String> {
    verify(cx).await.map_err(|error| format!("{error:#}"))
}

fn observation(cx: &mut AsyncApp) -> io_snapshot::NativeEvidence {
    cx.update(|cx| io_snapshot::native_evidence(cx))
}
async fn observed(
    window: AnyWindowHandle,
    cx: &mut AsyncApp,
    label: &str,
    predicate: impl Fn(&io_snapshot::NativeEvidence) -> bool,
) -> Result<io_snapshot::NativeEvidence> {
    let start = Instant::now();
    loop {
        let reading = observation(cx);
        if predicate(&reading) {
            return Ok(reading);
        }
        ensure!(
            start.elapsed() < Duration::from_secs(4),
            "actual cache observation timed out: {label}"
        );
        crate::native_parity_fixture::next_frame(window, cx)
            .await
            .map_err(anyhow::Error::msg)?;
    }
}
fn open(cx: &mut AsyncApp) -> Result<(AnyWindowHandle, Entity<SettingsView>)> {
    cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                focus: false,
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    gpui::point(px(0.0), px(0.0)),
                    size(px(860.0), px(640.0)),
                ))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| SettingsView::new_inner(window, cx, Some(String::new()))),
        )
    })
}
async fn write(path: std::path::PathBuf, bytes: Vec<u8>, cx: &mut AsyncApp) -> Result<()> {
    cx.background_spawn(async move { std::fs::write(path, bytes) })
        .await
        .context("owned cache file write")
}
async fn verify(cx: &mut AsyncApp) -> Result<Value> {
    let root = cx.update(|cx| {
        let root = cx.global::<AppData>().root.clone();
        ensure!(
            cx.windows().is_empty(),
            "cache fixture must precede ordinary windows"
        );
        ensure!(
            chau7_next_core::data_root::is_isolated_test_mode()
                && std::env::var("CHAU7_NEXT_NATIVE_PARITY_FIXTURE").as_deref() == Ok("1")
                && root.state_dir() == root.home().join(".chau7-next-state")
                && std::env::var_os(chau7_next_core::data_root::HOME_ROOT_ENV)
                    .map(std::path::PathBuf::from)
                    .as_deref()
                    == Some(root.home()),
            "cache fixture requires the runner-owned isolated root"
        );
        ensure!(
            cx.global::<ConfigFiles>().global_path() == root.config_file(),
            "cache config ownership mismatch"
        );
        Ok::<_, anyhow::Error>(root)
    })?;
    crate::history::init_native_cache_fixture(cx)
        .await
        .map_err(anyhow::Error::msg)?;
    let snippets = root.user_snippets_dir();
    let first = snippets.join("owned.json");
    let encoded = serde_json::to_vec(&Snippet::new("owned", "Owned cache", "echo owned"))?;
    let folder = snippets.clone();
    cx.background_spawn(async move { std::fs::create_dir_all(folder) })
        .await?;
    write(first.clone(), encoded.clone(), cx).await?;
    let (handle, view) = open(cx)?;
    let initial = observation(cx);
    ensure!(
        initial.snippets_pending && initial.history.pending,
        "initial real snapshots must be pending"
    );
    let initial = observed(handle, cx, "initial exact values", |r| {
        r.snippets == Some(1)
            && r.history
                .value
                .is_some_and(|(count, bytes)| count == 0 && bytes > 0)
            && !r.history.pending
            && !r.history.unavailable
    })
    .await?;
    let initial_bytes = initial.history.value.unwrap().1;
    // Paint the actual pages that consume these held readings. In-process
    // section navigation is not an OS keyboard/pointer acceptance claim.
    for section in [
        SettingsSection::SnippetsTools,
        SettingsSection::History,
        SettingsSection::LogsHistory,
    ] {
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                view.navigation.selection = section;
                cx.notify();
            })
        });
        crate::native_parity_fixture::next_frame(handle, cx)
            .await
            .map_err(anyhow::Error::msg)?;
    }

    // External in-place updates go through the real FSEvents stream, never
    // through manual snapshot invalidation or injected counts.
    write(first.clone(), b"invalid JSON".to_vec(), cx).await?;
    observed(handle, cx, "invalid JSON excluded", |r| {
        r.snippets == Some(0)
    })
    .await?;
    write(first.clone(), encoded.clone(), cx).await?;
    observed(handle, cx, "valid JSON restored", |r| r.snippets == Some(1)).await?;
    let before_rename = observation(cx).snippets_revision;
    let second = snippets.join("renamed.json");
    let (from, to) = (first.clone(), second.clone());
    cx.background_spawn(async move { std::fs::rename(from, to) })
        .await?;
    // No false duplicate count after an ordinary owned atomic rename.
    observed(handle, cx, "rename settles", |r| {
        r.snippets == Some(1) && r.snippets_revision > before_rename
    })
    .await?;

    // Actual service writer and mutation observer invalidate held statistics.
    cx.update(|cx| {
        crate::history::service(cx)
            .unwrap()
            .record(HistoryRecord::new("owned cache record"))
    });
    observed(handle, cx, "real writer insert", |r| {
        r.history.value.is_some_and(|(count, _)| count == 1)
            && !r.history.pending
            && !r.history.unavailable
    })
    .await?;
    let clear = cx.update(|cx| crate::history::clear_native_cache_fixture(cx));
    cx.background_spawn(async move { clear() }).await;
    let cleared = observed(handle, cx, "real producer clear", |r| {
        r.history.value.is_some_and(|(count, _)| count == 0)
            && !r.history.pending
            && !r.history.unavailable
    })
    .await?;
    let previous = cleared.history.value.unwrap();

    // The owned writer is now quiescent. Keep SQLite's reader open while only
    // the primary filename disappears; no insert occurs during this outage.
    let database = root.history_db();
    let moved = database.with_extension("owned-outage");
    let (from, to) = (database.clone(), moved.clone());
    cx.background_spawn(async move { std::fs::rename(from, to) })
        .await?;
    let failed = observed(handle, cx, "real missing-primary error", |r| {
        r.history.unavailable && !r.history.pending
    })
    .await;
    // Restore even when the evidence failed, before returning/central teardown.
    let (from, to) = (moved, database);
    let restored = cx
        .background_spawn(async move { std::fs::rename(from, to) })
        .await;
    restored.context("owned primary restoration")?;
    let failed = failed?;
    ensure!(
        failed.history.value == Some(previous),
        "real statistics error lost last successful counters"
    );
    observed(handle, cx, "primary recovery", |r| {
        !r.history.unavailable
            && !r.history.pending
            && r.history.value.is_some_and(|(count, _)| count == 0)
    })
    .await?;

    // An ordinary directory error is Unknown, with no invented snippet count.
    let archive = snippets.with_file_name("global-owned-outage");
    let (from, to) = (snippets.clone(), archive.clone());
    cx.background_spawn(async move { std::fs::rename(from, to) })
        .await?;
    write(snippets.clone(), b"not a directory".to_vec(), cx).await?;
    let failed = observed(handle, cx, "real snippet read error", |r| {
        r.snippets_unavailable && !r.snippets_pending && r.snippets.is_none()
    })
    .await;
    let (folder, archive) = (snippets.clone(), archive);
    let restored = cx
        .background_spawn(async move {
            std::fs::remove_file(&folder)?;
            std::fs::rename(archive, folder)
        })
        .await;
    restored.context("owned snippets restoration")?;
    failed?;
    observed(handle, cx, "snippet folder recovery", |r| {
        r.snippets == Some(1)
    })
    .await?;

    cx.update_window(handle, |_, window, _| window.remove_window())?;
    drop(view); // No strong Settings entity keeps the closed subscriber alive.
    let root_for_write = snippets.clone();
    let encoded_again = encoded.clone();
    cx.background_spawn(async move {
        std::fs::write(root_for_write.join("second.json"), encoded_again)
    })
    .await?;
    let (reopened, reopened_view) = open(cx)?;
    observed(reopened, cx, "close/reopen fresh values", |r| {
        r.snippets == Some(2)
            && r.history.value.is_some_and(|(count, _)| count == 0)
            && !r.history.pending
            && !r.history.unavailable
    })
    .await?;
    cx.update_window(reopened, |_, window, _| window.remove_window())?;
    drop(reopened_view);
    Ok(json!({
        "actual_native_frames":true,"real_fsevents_in_place_valid_invalid_valid":true,
        "real_snippet_error_unknown_recovery":true,"real_writer_insert_clear":true,
        "history_missing_primary_error_preserves_last_success":true,"primary_restored_before_shutdown":true,
        "close_reopen_exact_snippets":2,"initial_history_bytes":initial_bytes,
        "history_records_after_clear":0,"no_cache_value_injection":true,
        "ordinary_history_provider_init":false,"snapshot_getters_held_only":true,"actual_affected_pages_painted":3
    }))
}

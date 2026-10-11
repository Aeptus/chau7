//! iCloud sync of the settings (`FeatureSettings` "iCloud Sync"): the
//! settings export is saved to the iCloud key-value store 2 seconds after the
//! last change, and a document pushed by another Mac is applied.
//!
//! Swift gets told about outside changes with a notification; here the store
//! is read every [`REMOTE_POLL_SECONDS`] seconds, which looks the same to the
//! user. The store lives in `platform::icloud`.

use std::time::{Duration, Instant, SystemTime};

use gpui::{App, Global};

use super::config_files::ConfigFiles;
use super::export;
use crate::platform::icloud;
use crate::settings::Settings;
use crate::workspace::AppData;

/// Wait after the last change before uploading (`iCloudSyncDebounceInterval`).
pub const DEBOUNCE: Duration = Duration::from_secs(2);
/// How often the store is checked for a document from another Mac.
const REMOTE_POLL_SECONDS: u64 = 30;

/// Key of the settings document (`<bundle id>.settings`).
const KEY: &str = "com.chau7.next.settings";

/// What the Sync & Backup section shows.
#[derive(Default)]
pub struct SyncState {
    /// A change is waiting for the debounce to end.
    pending_since: Option<Instant>,
    /// The last document known to be in the store (pushed or applied).
    last_text: Option<String>,
    last_remote_check: Option<Instant>,
    pub last_sync: Option<SystemTime>,
    pub message: Option<String>,
}

impl Global for SyncState {}

/// Whether an upload is due: a change is pending and the debounce is over.
pub fn push_due(pending_since: Option<Instant>, now: Instant) -> bool {
    pending_since.is_some_and(|since| now.duration_since(since) >= DEBOUNCE)
}

/// A document from the store is worth applying when it differs from the last
/// one seen (our own upload comes back unchanged).
pub fn remote_is_new(last_text: Option<&str>, remote: Option<&str>) -> bool {
    match (last_text, remote) {
        (_, None) => false,
        (Some(last), Some(remote)) => last != remote,
        (None, Some(_)) => true,
    }
}

fn state(cx: &mut App) -> &mut SyncState {
    if !cx.has_global::<SyncState>() {
        cx.set_global(SyncState::default());
    }
    cx.global_mut::<SyncState>()
}

fn enabled(cx: &App) -> bool {
    cx.try_global::<ConfigFiles>()
        .is_some_and(|f| f.base.general.icloud_sync)
}

fn document(cx: &App) -> String {
    let home = cx
        .global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned();
    let base = &cx.global::<ConfigFiles>().base;
    export::export_json(base, &home)
}

/// A setting changed: upload after the debounce (`syncToiCloud`).
pub fn schedule_push(cx: &mut App) {
    if enabled(cx) {
        state(cx).pending_since = Some(Instant::now());
    }
}

/// Upload now, without the debounce (Sync Now, quit).
pub fn push_now(cx: &mut App) {
    if !enabled(cx) {
        return;
    }
    let store = icloud::current();
    let text = document(cx);
    let result = store.set_string(KEY, &text);
    let available = store.is_available();
    let state = state(cx);
    state.pending_since = None;
    match result {
        Ok(()) => {
            state.last_text = Some(text);
            state.last_sync = Some(SystemTime::now());
            state.message = Some(if available {
                "Settings uploaded to iCloud".into()
            } else {
                "iCloud is not available: saved on this Mac only".into()
            });
        }
        Err(err) => state.message = Some(format!("iCloud: {err}")),
    }
}

/// Apply the document in the store (Restore from iCloud, or another Mac
/// changed it).
pub fn restore(cx: &mut App) -> Result<(), String> {
    let store = icloud::current();
    store.synchronize();
    let Some(text) = store.string(KEY) else {
        let message = "No settings found in iCloud".to_string();
        state(cx).message = Some(message.clone());
        return Err(message);
    };
    let home = cx
        .global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned();
    let mut base: Settings = cx.global::<ConfigFiles>().base.clone();
    // The sync switch itself stays as it is on this Mac.
    let sync = base.general.icloud_sync;
    if let Err(err) = export::import_json(&mut base, &text, &home) {
        let message = format!("Could not restore from iCloud: {err}");
        state(cx).message = Some(message.clone());
        return Err(message);
    }
    base.general.icloud_sync = sync;
    crate::settings_window::replace_base(cx, base);
    let state = state(cx);
    state.last_text = Some(text);
    state.last_sync = Some(SystemTime::now());
    state.message = Some("Settings restored from iCloud".into());
    Ok(())
}

/// Called every poll of the app timer (150 ms).
pub fn tick(cx: &mut App) {
    if !enabled(cx) {
        return;
    }
    let now = Instant::now();
    if push_due(state(cx).pending_since, now) {
        // An unchanged document is not uploaded again.
        let text = document(cx);
        if state(cx).last_text.as_deref() == Some(text.as_str()) {
            state(cx).pending_since = None;
        } else {
            push_now(cx);
        }
    }
    let check = state(cx)
        .last_remote_check
        .is_none_or(|t| now.duration_since(t).as_secs() >= REMOTE_POLL_SECONDS);
    if check && state(cx).pending_since.is_none() {
        state(cx).last_remote_check = Some(now);
        let store = icloud::current();
        store.synchronize();
        let remote = store.string(KEY);
        if remote_is_new(state(cx).last_text.as_deref(), remote.as_deref()) {
            // The first look after enabling sync only records the document: the
            // user restores it on purpose with "Restore from iCloud".
            if state(cx).last_text.is_none() {
                state(cx).last_text = remote;
            } else {
                let _ = restore(cx);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_waits_for_the_debounce() {
        let start = Instant::now();
        assert!(!push_due(None, start));
        assert!(!push_due(Some(start), start + Duration::from_millis(1500)));
        assert!(push_due(Some(start), start + Duration::from_secs(2)));
    }

    #[test]
    fn only_a_different_remote_document_is_new() {
        assert!(!remote_is_new(Some("a"), None));
        assert!(!remote_is_new(Some("a"), Some("a")));
        assert!(remote_is_new(Some("a"), Some("b")));
        assert!(remote_is_new(None, Some("b")));
        assert!(!remote_is_new(None, None));
    }
}

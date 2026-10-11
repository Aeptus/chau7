//! iCloud sync of the settings (`FeatureSettings` "iCloud Sync"): the
//! settings export is saved to the iCloud key-value store 2 seconds after the
//! last change, and a document pushed by another Mac is applied.
//!
//! Swift gets told about outside changes with a notification; here the store
//! is read every [`REMOTE_POLL_SECONDS`] seconds, which looks the same to the
//! user. The store lives in `platform::icloud`.

use std::time::{Duration, Instant, SystemTime};

use gpui::{App, Global};

use super::cloud_freshness::{self, RemoteSettings};
use super::config_files::ConfigFiles;
use super::export;
use crate::platform::defaults;
use crate::platform::icloud;
use crate::workspace::AppData;

/// Wait after the last change before uploading (`iCloudSyncDebounceInterval`).
pub const DEBOUNCE: Duration = Duration::from_secs(2);
/// How often the store is checked for a document from another Mac.
const REMOTE_POLL_SECONDS: u64 = 30;

/// Key of the settings document (`<bundle id>.settings`).
const KEY: &str = "com.chau7.next.settings";
const LOCAL_DATE_KEY: &str = "icloud.settings.lastSyncedExportedAt";

/// What the Sync & Backup section shows.
#[derive(Default)]
pub struct SyncState {
    /// A change is waiting for the debounce to end.
    pending_since: Option<Instant>,
    /// The last document known to be in the store (pushed or applied).
    last_text: Option<String>,
    last_fingerprint: Option<String>,
    last_exported_at: Option<f64>,
    last_remote_check: Option<Instant>,
    pub last_sync: Option<SystemTime>,
    pub message: Option<String>,
}

impl SyncState {
    fn upload(
        &mut self,
        store: &dyn icloud::CloudStore,
        text: String,
        now: SystemTime,
    ) -> Result<Option<f64>, String> {
        self.pending_since = None;
        let exported_at = cloud_freshness::timestamp(&text)?;
        let fingerprint = cloud_freshness::fingerprint(&text)?;
        store
            .set_string(KEY, &text)
            .map_err(|err| err.to_string())?;
        self.last_text = Some(text);
        self.last_fingerprint = Some(fingerprint);
        if let Some(date) = exported_at {
            self.last_exported_at = Some(self.last_exported_at.map_or(date, |last| last.max(date)));
        }
        self.last_sync = Some(now);
        Ok(self.last_exported_at)
    }
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
        cx.set_global(SyncState {
            last_exported_at: defaults::app_string(LOCAL_DATE_KEY)
                .and_then(|s| s.parse().ok())
                .and_then(cloud_freshness::finite_timestamp),
            ..SyncState::default()
        });
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
    let available = store.is_available();
    let result = state(cx).upload(store, text, SystemTime::now());
    match result {
        Ok(date) => {
            persist_date(date);
            state(cx).message = Some(if available {
                "Settings uploaded to iCloud".into()
            } else {
                "iCloud is not available: saved on this Mac only".into()
            });
        }
        Err(err) => state(cx).message = Some(format!("iCloud: {err}")),
    }
}

/// Apply the document in the store (Restore from iCloud, or another Mac
/// changed it).
pub fn restore(cx: &mut App) -> Result<(), String> {
    let _ = state(cx);
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
    let base = &cx.global::<ConfigFiles>().base;
    let last_date = cx
        .try_global::<SyncState>()
        .and_then(|state| state.last_exported_at);
    let prepared = cloud_freshness::prepare_remote(base, &text, &home, last_date);
    match prepared {
        Ok(RemoteSettings::NotNewer) => {
            let state = state(cx);
            state.last_text = Some(text);
            state.message = Some("iCloud settings are not newer than the last synced state".into());
        }
        Ok(RemoteSettings::Apply {
            settings,
            exported_at,
            fingerprint,
        }) => {
            crate::settings_window::replace_base(cx, *settings);
            let state = state(cx);
            // Applying a remote document must not immediately echo it back.
            state.pending_since = None;
            state.last_text = Some(text);
            state.last_fingerprint = Some(fingerprint);
            if let Some(date) = exported_at {
                state.last_exported_at = Some(date);
            }
            state.last_sync = Some(SystemTime::now());
            state.message = Some("Settings restored from iCloud".into());
            persist_date(state.last_exported_at);
        }
        Err(err) => {
            let message = format!("Could not restore from iCloud: {err}");
            state(cx).message = Some(message.clone());
            return Err(message);
        }
    }
    Ok(())
}

fn persist_date(date: Option<f64>) {
    if let Some(date) = date
        && let Err(err) = defaults::set_app_string(LOCAL_DATE_KEY, Some(&date.to_string()))
    {
        log::warn!("persist local settings cloud date: {err}");
    }
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
        let fingerprint = cloud_freshness::fingerprint(&text).ok();
        if fingerprint.is_some() && state(cx).last_fingerprint == fingerprint {
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
    use crate::settings::Settings;

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
    struct FakeStore {
        fail: bool,
        writes: std::sync::Mutex<Vec<String>>,
    }
    impl icloud::CloudStore for FakeStore {
        fn is_available(&self) -> bool {
            true
        }
        fn string(&self, _: &str) -> Option<String> {
            None
        }
        fn synchronize(&self) -> bool {
            true
        }
        fn set_string(&self, key: &str, text: &str) -> crate::platform::Result<()> {
            assert_eq!(key, KEY);
            if self.fail {
                return Err(crate::platform::PlatformError::Failed(
                    "fixture failure".into(),
                ));
            }
            self.writes.lock().unwrap().push(text.into());
            Ok(())
        }
    }
    #[test]
    fn only_successful_actual_upload_advances_the_device_watermark() {
        let mut state = SyncState {
            last_exported_at: Some(10.0),
            last_text: Some("previous".into()),
            ..Default::default()
        };
        let mut value: serde_json::Value =
            serde_json::from_str(&export::export_json(&Settings::default(), "/owned/home"))
                .unwrap();
        value["exportedAt"] = serde_json::json!(20.0);
        let text = value.to_string();
        let failing = FakeStore {
            fail: true,
            writes: Default::default(),
        };
        assert!(
            state
                .upload(&failing, text.clone(), SystemTime::UNIX_EPOCH)
                .is_err()
        );
        assert_eq!(state.last_exported_at, Some(10.0));
        assert_eq!(state.last_text.as_deref(), Some("previous"));
        assert!(state.last_sync.is_none());
        let success = FakeStore {
            fail: false,
            writes: Default::default(),
        };
        assert_eq!(
            state
                .upload(&success, text.clone(), SystemTime::UNIX_EPOCH)
                .unwrap(),
            Some(20.0)
        );
        assert_eq!(state.last_text.as_deref(), Some(text.as_str()));
        assert_eq!(success.writes.lock().unwrap().as_slice(), &[text]);
        assert!(state.last_fingerprint.is_some());
        assert_eq!(state.last_sync, Some(SystemTime::UNIX_EPOCH));
    }
}

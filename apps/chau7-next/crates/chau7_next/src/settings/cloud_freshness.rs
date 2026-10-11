//! Swift-compatible export dates and local, per-device freshness checks.
use super::Settings;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

/// JSONEncoder's default Date representation counts from 2001-01-01.
const REFERENCE_EPOCH: f64 = 978_307_200.0;

pub(super) fn export_timestamp(now: SystemTime) -> f64 {
    now.duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
        - REFERENCE_EPOCH
}

pub(super) fn finite_timestamp(value: f64) -> Option<f64> {
    value.is_finite().then_some(value)
}

pub(super) fn timestamp(text: &str) -> Result<Option<f64>, String> {
    let document: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let map = document
        .as_object()
        .ok_or("settings document must be an object")?;
    match map.get("exportedAt") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_f64()
            .and_then(finite_timestamp)
            .map(Some)
            .ok_or_else(|| "invalid settings export date".into()),
    }
}

/// Ignore only the export date when comparing preferences for debounced pushes.
pub(super) fn fingerprint(text: &str) -> Result<String, String> {
    let mut document: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    document
        .as_object_mut()
        .ok_or("settings document must be an object")?
        .remove("exportedAt");
    serde_json::to_string(&document).map_err(|e| e.to_string())
}

pub(super) enum RemoteSettings {
    NotNewer,
    Apply {
        settings: Box<Settings>,
        exported_at: Option<f64>,
        fingerprint: String,
    },
}

/// Prepare into a separate value: malformed, old and future-version documents
/// never mutate the actual settings or advance the local synced date.
pub(super) fn prepare_remote(
    base: &Settings,
    text: &str,
    home: &str,
    last: Option<f64>,
) -> Result<RemoteSettings, String> {
    let exported_at = timestamp(text)?;
    if exported_at
        .zip(last)
        .is_some_and(|(incoming, local)| incoming <= local)
    {
        return Ok(RemoteSettings::NotNewer);
    }
    let mut settings = base.clone();
    super::export::import_json(&mut settings, text, home)?;
    settings.general.icloud_sync = base.general.icloud_sync;
    Ok(RemoteSettings::Apply {
        settings: Box::new(settings),
        exported_at,
        fingerprint: fingerprint(text)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::export;
    use super::*;
    const HOME: &str = "/owned/test/home";
    fn document(settings: &Settings, date: Option<f64>) -> String {
        let mut json: Value = serde_json::from_str(&export::export_json(settings, HOME)).unwrap();
        if let Some(date) = date {
            json["exportedAt"] = serde_json::json!(date);
        } else {
            json.as_object_mut().unwrap().remove("exportedAt");
        }
        json.to_string()
    }
    #[test]
    fn date_uses_the_current_swift_reference_epoch() {
        let start = UNIX_EPOCH + std::time::Duration::from_secs(978_307_200);
        assert_eq!(export_timestamp(start), 0.0);
        assert_eq!(
            export_timestamp(start + std::time::Duration::from_millis(1250)),
            1.25
        );
        assert_eq!(finite_timestamp(f64::NAN), None);
        assert_eq!(finite_timestamp(f64::INFINITY), None);
    }
    #[test]
    fn equal_and_older_exports_do_not_replace_actual_preferences() {
        let base = Settings::default();
        let mut incoming = base.clone();
        incoming.appearance.font_size = 25.0;
        for date in [5.0, 10.0] {
            assert!(matches!(
                prepare_remote(&base, &document(&incoming, Some(date)), HOME, Some(10.0)).unwrap(),
                RemoteSettings::NotNewer
            ));
        }
        assert_eq!(base, Settings::default());
    }
    #[test]
    fn newer_and_legacy_exports_restore_but_keep_local_sync_and_contacts() {
        let mut base = Settings::default();
        base.general.icloud_sync = true;
        base.general.bug_report_contact_name = "Local name".into();
        let mut incoming = Settings::default();
        incoming.appearance.font_size = 25.0;
        for date in [Some(11.0), None] {
            let RemoteSettings::Apply {
                settings,
                exported_at,
                ..
            } = prepare_remote(&base, &document(&incoming, date), HOME, Some(10.0)).unwrap()
            else {
                panic!("should apply")
            };
            assert_eq!(settings.appearance.font_size, 25.0);
            assert!(settings.general.icloud_sync);
            assert_eq!(settings.general.bug_report_contact_name, "Local name");
            assert_eq!(exported_at, date);
        }
    }
    #[test]
    fn unchanged_preferences_have_identical_fingerprints_despite_export_time() {
        let base = Settings::default();
        assert_eq!(
            fingerprint(&document(&base, Some(1.0))).unwrap(),
            fingerprint(&document(&base, Some(2.0))).unwrap()
        );
        let mut changed = base.clone();
        changed.appearance.font_size = 21.0;
        assert_ne!(
            fingerprint(&document(&base, Some(1.0))).unwrap(),
            fingerprint(&document(&changed, Some(1.0))).unwrap()
        );
    }
    #[test]
    fn bad_dates_and_unsupported_versions_cannot_be_prepared() {
        let base = Settings::default();
        let mut json: Value = serde_json::from_str(&document(&base, Some(11.0))).unwrap();
        json["exportedAt"] = serde_json::json!("tomorrow");
        assert!(prepare_remote(&base, &json.to_string(), HOME, Some(10.0)).is_err());
        json["exportedAt"] = serde_json::json!(11.0);
        json["exportVersion"] = serde_json::json!(2);
        assert!(prepare_remote(&base, &json.to_string(), HOME, Some(10.0)).is_err());
        assert_eq!(base, Settings::default());
    }
}

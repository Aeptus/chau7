//! Provider quota capture and bounded history isolated from the Swift app.
use crate::{settings::Settings, workspace::AppData};
use chau7_next_core::{
    data_root::DataRoot,
    telemetry::{
        jsonl_tail::JsonlTail,
        quota::{QuotaHistory, QuotaMetrics, QuotaSnapshot, metrics, warnings},
    },
};
use chrono::{DateTime, Utc};
use gpui::{App, Global};
use parking_lot::Mutex;
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
};
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageProvider {
    pub snapshot: QuotaSnapshot,
    pub metrics: Vec<QuotaMetrics>,
}
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageView {
    pub providers: Vec<UsageProvider>,
    pub last_refresh: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub capture_installed: bool,
    pub refreshing: bool,
}
#[derive(Default)]
struct ProviderHealth {
    snapshots: std::collections::HashMap<
        String,
        chau7_next_core::telemetry::provider_health::HealthSnapshot,
    >,
    failures: u32,
    next_allowed: Option<DateTime<Utc>>,
}
struct HealthGlobal(Arc<Mutex<ProviderHealth>>);
impl Global for HealthGlobal {}
pub fn provider_health(
    cx: &App,
) -> Vec<chau7_next_core::telemetry::provider_health::HealthSnapshot> {
    let now = Utc::now();
    cx.try_global::<HealthGlobal>()
        .map(|g| {
            g.0.lock()
                .snapshots
                .values()
                .filter(|s| {
                    let age = now.signed_duration_since(s.checked_at).num_seconds();
                    (0..=300).contains(&age)
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}
fn init_health(cx: &mut App) {
    let state = Arc::new(Mutex::new(ProviderHealth::default()));
    cx.set_global(HealthGlobal(state.clone()));
    let executor = cx.background_executor().clone();
    cx.background_executor()
        .spawn(async move {
            loop {
                let now = Utc::now();
                if state.lock().next_allowed.is_none_or(|at| now >= at) {
                    let fetched = std::thread::scope(|scope| {
                        let handles: Vec<_> = [
                            (
                                "anthropic",
                                "https://status.claude.com/api/v2/summary.json",
                                vec!["Claude API", "Claude Code"],
                            ),
                            (
                                "openai",
                                "https://status.openai.com/api/v2/summary.json",
                                vec![
                                    "Responses",
                                    "Codex API",
                                    "VS Code extension",
                                    "Codex in ChatGPT Desktop",
                                ],
                            ),
                            (
                                "github",
                                "https://www.githubstatus.com/api/v2/summary.json",
                                vec!["Copilot", "Copilot AI Model Providers"],
                            ),
                            (
                                "google",
                                "https://status.cloud.google.com/incidents.json",
                                vec![],
                            ),
                        ]
                        .into_iter()
                        .map(|(provider, url, fragments)| {
                            scope.spawn(move || {
                                let output = std::process::Command::new("curl")
                                    .args([
                                        "--fail",
                                        "--silent",
                                        "--show-error",
                                        "--location",
                                        "--max-time",
                                        "10",
                                        "--max-filesize",
                                        "1048576",
                                        url,
                                    ])
                                    .output()
                                    .map_err(|e| e.to_string())?;
                                if !output.status.success() {
                                    return Err(format!("{provider} status fetch failed"));
                                }
                                let value: Value = serde_json::from_slice(&output.stdout)
                                    .map_err(|e| e.to_string())?;
                                if provider == "google" {
                                    chau7_next_core::telemetry::provider_health::google_cloud(
                                        &value, url, now,
                                    )
                                } else {
                                    chau7_next_core::telemetry::provider_health::status_page(
                                        &value, provider, &fragments, url, now,
                                    )
                                }
                            })
                        })
                        .collect();
                        handles
                            .into_iter()
                            .map(|h| {
                                h.join().unwrap_or_else(|_| {
                                    Err("Provider status worker stopped".into())
                                })
                            })
                            .collect::<Vec<_>>()
                    });
                    let mut state = state.lock();
                    let mut successes = 0;
                    for result in fetched {
                        match result {
                            Ok(snapshot) => {
                                successes += 1;
                                state.snapshots.insert(snapshot.provider.clone(), snapshot);
                            }
                            Err(e) => log::debug!("Provider status unavailable: {e}"),
                        }
                    }
                    if successes == 0 {
                        state.failures += 1;
                        state.next_allowed = Some(
                            now + chrono::Duration::seconds(
                                chau7_next_core::telemetry::provider_health::retry_delay(
                                    state.failures,
                                ),
                            ),
                        );
                    } else {
                        state.failures = 0;
                        state.next_allowed = None;
                    }
                    state.snapshots.retain(|_, s| {
                        now.signed_duration_since(s.checked_at).num_seconds() <= 300
                    });
                }
                executor.timer(std::time::Duration::from_secs(60)).await;
            }
        })
        .detach();
}

struct UsageState {
    root: DataRoot,
    history: Option<QuotaHistory>,
    view: UsageView,
    codex_path: Option<PathBuf>,
    codex_tail: JsonlTail,
    warnings: HashSet<String>,
}
struct UsageGlobal(Arc<Mutex<UsageState>>);
impl Global for UsageGlobal {}
pub fn view(cx: &App) -> UsageView {
    cx.try_global::<UsageGlobal>()
        .map(|g| g.0.lock().view.clone())
        .unwrap_or_default()
}
fn helper(root: &DataRoot) -> PathBuf {
    root.bin_dir().join("chau7-next-claude-statusline")
}
fn usage_dir(root: &DataRoot) -> PathBuf {
    root.config_dir().join("usage")
}
fn installed(root: &DataRoot) -> bool {
    std::fs::read(root.home().join(".claude/settings.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| {
            v.pointer("/statusLine/command")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .is_some_and(|s| s == helper(root).to_string_lossy())
}
pub fn init(cx: &mut App) {
    init_health(cx);
    let root = cx.global::<AppData>().root.clone();
    let mut state = UsageState {
        root,
        history: None,
        view: UsageView::default(),
        codex_path: None,
        codex_tail: JsonlTail::default(),
        warnings: HashSet::new(),
    };
    state.refresh_view();
    cx.set_global(UsageGlobal(Arc::new(Mutex::new(state))));
    crate::debug::usage::register(cx);
    refresh(cx);
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(30))
                .await;
            cx.update(|cx| {
                if Settings::get(cx).general.usage_monitoring
                    || Settings::get(cx).general.claude_quota_capture
                    || Settings::get(cx).general.usage_quota_warnings
                {
                    refresh(cx);
                }
            });
        }
    })
    .detach();
}
impl UsageState {
    fn refresh_view(&mut self) {
        self.view.capture_installed = installed(&self.root);
        self.view.providers = self
            .history
            .as_ref()
            .map(|h| {
                let now = Utc::now();
                let recent: Vec<_> = h
                    .snapshots
                    .iter()
                    .filter(|s| s.captured_at >= now - chrono::Duration::minutes(10))
                    .cloned()
                    .collect();
                h.latest()
                    .into_iter()
                    .map(|snapshot| UsageProvider {
                        metrics: metrics(&snapshot, &recent, now),
                        snapshot,
                    })
                    .collect()
            })
            .unwrap_or_default();
    }
    fn append(&mut self, snapshot: QuotaSnapshot) {
        if let Some(history) = self.history.as_mut()
            && let Err(e) = history.append(snapshot)
        {
            self.view.last_error = Some(e.to_string());
        }
    }
    fn capture(
        &mut self,
        monitoring: bool,
        claude: bool,
        warn: bool,
    ) -> Vec<chau7_next_core::telemetry::quota::QuotaWarning> {
        self.view.last_error = None;
        if self.history.is_none() {
            match QuotaHistory::open(usage_dir(&self.root).join("snapshots.jsonl")) {
                Ok(h) => self.history = Some(h),
                Err(e) => self.view.last_error = Some(e.to_string()),
            }
        }
        if self.warnings.is_empty()
            && let Ok(bytes) = std::fs::read(usage_dir(&self.root).join("issued-warnings.json"))
        {
            self.warnings = serde_json::from_slice(&bytes).unwrap_or_default();
        }

        if claude {
            let path = usage_dir(&self.root).join("claude-statusline-latest.json");
            if let Ok(file) = std::fs::File::open(&path) {
                use std::io::Read;
                let at = file
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .map(DateTime::<Utc>::from)
                    .unwrap_or_else(Utc::now);
                let mut bytes = Vec::new();
                if file.take(1024 * 1024).read_to_end(&mut bytes).is_ok()
                    && let Ok(v) = serde_json::from_slice(&bytes)
                    && let Some(s) = QuotaSnapshot::parse_claude(
                        &v,
                        at,
                        Some(path.to_string_lossy().into_owned()),
                    )
                {
                    self.append(s);
                }
            }
        }
        if monitoring {
            let mut paths = Vec::new();
            if let Some(path) = self.codex_path.clone() {
                paths.push(path);
            }
            let sessions = self.root.home().join(".codex/sessions");
            for days in 0..14 {
                let date = chrono::Local::now() - chrono::Duration::days(days);
                let dir = sessions.join(date.format("%Y/%m/%d").to_string());
                if let Ok(entries) = std::fs::read_dir(dir) {
                    paths.extend(
                        entries
                            .flatten()
                            .map(|e| e.path())
                            .filter(|p| p.extension().is_some_and(|e| e == "jsonl")),
                    );
                }
            }
            if let Some(path) = paths
                .into_iter()
                .max_by_key(|p| p.metadata().ok().and_then(|m| m.modified().ok()))
            {
                self.codex_path = Some(path.clone());
                match self.codex_tail.read(&path) {
                    Ok(text) => {
                        for line in text.lines() {
                            if let Ok(v) = serde_json::from_str(line)
                                && let Some(s) = QuotaSnapshot::parse_codex(
                                    &v,
                                    Some(path.to_string_lossy().into_owned()),
                                )
                            {
                                self.append(s);
                            }
                        }
                    }
                    Err(e) => self.view.last_error = Some(e.to_string()),
                }
            }
        }
        self.view.last_refresh = Some(Utc::now());
        self.refresh_view();
        if !warn {
            return vec![];
        }
        let mut emit = vec![];
        if let Some(h) = &self.history {
            let now = Utc::now();
            let recent: Vec<_> = h
                .snapshots
                .iter()
                .filter(|s| s.captured_at >= now - chrono::Duration::minutes(10))
                .cloned()
                .collect();
            for latest in h
                .latest()
                .into_iter()
                .filter(|s| s.captured_at >= now - chrono::Duration::minutes(15))
            {
                for warning in warnings(&latest, &recent, now) {
                    if self.warnings.insert(warning.id.clone()) {
                        emit.push(warning);
                    }
                }
            }
        }
        if !emit.is_empty()
            && let Ok(bytes) = serde_json::to_vec(&self.warnings)
            && let Err(e) =
                atomic_write(&usage_dir(&self.root).join("issued-warnings.json"), &bytes)
        {
            self.view.last_error = Some(e);
        }
        emit
    }
}
pub fn refresh(cx: &mut App) {
    let Some(global) = cx.try_global::<UsageGlobal>() else {
        return;
    };
    let state = global.0.clone();
    {
        let mut s = state.lock();
        if s.view.refreshing {
            return;
        }
        s.view.refreshing = true;
    }
    let settings = Settings::get(cx).general.clone();
    cx.spawn(async move |cx| {
        let state2 = state.clone();
        let warnings = cx
            .background_executor()
            .spawn(async move {
                state2.lock().capture(
                    settings.usage_monitoring,
                    settings.claude_quota_capture,
                    settings.usage_quota_warnings,
                )
            })
            .await;
        cx.update(|cx| {
            state.lock().view.refreshing = false;
            for warning in warnings {
                crate::ai::events_out::publish(
                    chau7_next_core::ai::event::AiEvent::new(
                        chau7_next_core::ai::event::AiEventSource::app(),
                        "token_threshold",
                        warning.provider.clone(),
                        format!(
                            "{} quota: {:.0}% remaining ({})",
                            warning.provider,
                            warning.window.remaining(),
                            warning.kind
                        ),
                        Utc::now().to_rfc3339(),
                    ),
                    true,
                    cx,
                );
            }
        });
    })
    .detach();
}
fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing parent directory")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let temporary = parent.join(format!(".chau7-next-write-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = path
                .metadata()
                .map(|m| m.permissions().mode())
                .unwrap_or(0o600);
            file.set_permissions(std::fs::Permissions::from_mode(mode))
                .map_err(|e| e.to_string())?;
        }
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}
/// Only an explicit user control installs or removes the capture wrapper.
pub fn set_capture(enabled: bool, cx: &mut App) {
    let Some(g) = cx.try_global::<UsageGlobal>() else {
        return;
    };
    let state = g.0.clone();
    cx.spawn(async move |cx| {
        let s = state.clone();
        let result = cx
            .background_executor()
            .spawn(async move {
                let root = s.lock().root.clone();
                configure_capture(&root, enabled)
            })
            .await;
        cx.update(|cx| {
            let mut s = state.lock();
            s.view.last_error = result.err();
            s.refresh_view();
            let ok = s.view.last_error.is_none();
            drop(s);
            if ok {
                crate::settings_window::update(cx, |s| s.general.claude_quota_capture = enabled);
            }
            refresh(cx);
        });
    })
    .detach();
}
fn configure_capture(root: &DataRoot, enabled: bool) -> Result<(), String> {
    let settings = root.home().join(".claude/settings.json");
    let original = match std::fs::read(&settings) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => b"{}".to_vec(),
        Err(e) => return Err(e.to_string()),
    };
    let mut json: Value = serde_json::from_slice(&original)
        .map_err(|e| format!("Claude settings.json is invalid: {e}"))?;
    let object = json
        .as_object_mut()
        .ok_or("Claude settings.json must be an object")?;
    let path = helper(root);
    let backup = usage_dir(root).join("claude-statusline-original.json");
    let command = path.to_string_lossy().into_owned();
    let ours = object
        .get("statusLine")
        .and_then(|v| v.get("command"))
        .and_then(Value::as_str)
        == Some(&command);
    if enabled {
        if ours {
            return Ok(());
        }
        let previous = object.get("statusLine").cloned().unwrap_or(Value::Null);
        atomic_write(
            &backup,
            &serde_json::to_vec(&previous).map_err(|e| e.to_string())?,
        )?;
        let script = r#"#!/bin/sh
INPUT=$(cat)
PAYLOAD=__PAYLOAD__
ORIGINAL=__ORIGINAL__
mkdir -p "$(dirname "$PAYLOAD")" || exit 0
TMP="$PAYLOAD.tmp.$$"
printf '%s' "$INPUT" > "$TMP" && mv "$TMP" "$PAYLOAD"
ORIG_CMD=$(/usr/bin/plutil -extract command raw -o - "$ORIGINAL" 2>/dev/null)
[ -z "$ORIG_CMD" ] && exit 0
printf '%s' "$INPUT" | eval "$ORIG_CMD"
"#
        .replace(
            "__PAYLOAD__",
            &shell_quote(&usage_dir(root).join("claude-statusline-latest.json")),
        )
        .replace("__ORIGINAL__", &shell_quote(&backup));
        atomic_write(&path, script.as_bytes())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        object.insert(
            "statusLine".into(),
            serde_json::json!({"type":"command","command":command}),
        );
    } else {
        if !ours {
            return Err("Claude statusLine changed after capture installation; leave the current setting intact.".into());
        }
        let previous: Value =
            serde_json::from_slice(&std::fs::read(&backup).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if previous.is_null() {
            object.remove("statusLine");
        } else {
            object.insert("statusLine".into(), previous);
        }
    }
    if std::fs::read(&settings).unwrap_or_else(|_| b"{}".to_vec()) != original {
        return Err(
            "Claude settings changed while capture was being configured. Try again.".into(),
        );
    }
    atomic_write(
        &settings,
        &serde_json::to_vec_pretty(&json).map_err(|e| e.to_string())?,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> DataRoot {
        let home = std::env::temp_dir().join(format!("chau7-quota-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        DataRoot::with_home(home, true)
    }
    #[test]
    fn capture_restores_exact_original_and_preserves_unrelated_settings() {
        let root = root();
        let p = root.home().join(".claude/settings.json");
        let original = serde_json::json!({"statusLine":{"type":"command","command":"printf original"},"permissions":{"allow":["Read"]}});
        std::fs::write(&p, serde_json::to_vec(&original).unwrap()).unwrap();
        configure_capture(&root, true).unwrap();
        assert!(installed(&root));
        let helper_text = std::fs::read_to_string(helper(&root)).unwrap();
        assert!(helper_text.contains("chau7-next"));
        assert!(helper_text.contains(&root.config_dir().to_string_lossy().to_string()));
        configure_capture(&root, true).unwrap();
        configure_capture(&root, false).unwrap();
        let restored: Value = serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap();
        assert_eq!(restored, original);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn capture_leaves_invalid_or_user_modified_settings_intact() {
        let root = root();
        let p = root.home().join(".claude/settings.json");
        std::fs::write(&p, b"invalid").unwrap();
        assert!(configure_capture(&root, true).is_err());
        assert_eq!(std::fs::read(&p).unwrap(), b"invalid");
        std::fs::write(&p, b"{}").unwrap();
        configure_capture(&root, true).unwrap();
        let changed = b"{\"statusLine\":{\"command\":\"user-replacement\"}}";
        std::fs::write(&p, changed).unwrap();
        assert!(configure_capture(&root, false).is_err());
        assert_eq!(std::fs::read(&p).unwrap(), changed);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
}

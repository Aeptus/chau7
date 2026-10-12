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
    pub active_warnings: Vec<chau7_next_core::telemetry::quota::QuotaWarning>,
}
impl UsageProvider {
    fn from_snapshot(
        snapshot: QuotaSnapshot,
        recent: &[QuotaSnapshot],
        now: DateTime<Utc>,
    ) -> Self {
        let age = now.signed_duration_since(snapshot.captured_at);
        let active_warnings =
            if (chrono::Duration::zero()..=chrono::Duration::minutes(15)).contains(&age) {
                warnings(&snapshot, recent, now)
            } else {
                vec![]
            };
        Self {
            metrics: metrics(&snapshot, recent, now),
            active_warnings,
            snapshot,
        }
    }
}
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageView {
    pub providers: Vec<UsageProvider>,
    pub last_refresh: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub capture_installed: bool,
    pub refreshing: bool,
    pub capture_working: bool,
    pub recent_consumption:
        Option<Vec<chau7_next_core::token_optimization::ProviderConsumptionStats>>,
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
fn automatic_health_worker_allowed(isolated: bool) -> bool {
    !isolated
}

fn init_health(cx: &mut App) {
    let state = Arc::new(Mutex::new(ProviderHealth::default()));
    cx.set_global(HealthGlobal(state.clone()));
    // Keep health getters present with no observations; isolation must not
    // fabricate a healthy status or start external requests/timer tasks.
    if !automatic_health_worker_allowed(chau7_next_core::data_root::is_isolated_test_mode()) {
        return;
    }
    let executor = cx.background_executor().clone();
    let main = crate::mcp::MainThread::start(cx);
    let timer = crate::observability::register_background_timer(
        cx,
        "usage.provider_health",
        "Official provider health",
        "usage",
        60_000,
    );
    let active = cx
        .global::<UsageGlobal>()
        .activity
        .begin()
        .expect("new provider-health lifecycle accepts its monitor");
    let task = cx.background_executor().spawn(async move {
        let _active = active;
        let _timer = timer;
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
                            h.join()
                                .unwrap_or_else(|_| Err("Provider status worker stopped".into()))
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
                state
                    .snapshots
                    .retain(|_, s| now.signed_duration_since(s.checked_at).num_seconds() <= 300);
            }
            // Publish new observations and stale-observation removal even
            // when quota monitoring is disabled. One dispatch per poll;
            // the feed request and snapshot mutex remain off the UI thread.
            if !main.dispatch(|cx| cx.refresh_windows()) {
                break;
            }
            executor.timer(std::time::Duration::from_secs(60)).await;
        }
    });
    cx.global_mut::<UsageGlobal>().health = Some(task);
}

struct UsageState {
    root: DataRoot,
    history: Option<QuotaHistory>,
    view: UsageView,
    codex_locator: chau7_next_core::telemetry::quota_discovery::CodexQuotaLocator,
    codex_tail: JsonlTail,
    warnings: HashSet<String>,
}
struct UsageGlobal {
    worker: Arc<Mutex<UsageState>>,
    snapshot: Arc<Mutex<UsageView>>,
    refreshing: Arc<std::sync::atomic::AtomicBool>,
    capture_working: Arc<std::sync::atomic::AtomicBool>,
    activity: Arc<super::cache::Activity>,
    timer: Option<gpui::Task<()>>,
    monitor_guard: Option<super::cache::WorkGuard>,
    health: Option<gpui::Task<()>>,
}
impl UsageGlobal {
    fn new(root: DataRoot) -> Self {
        Self {
            snapshot: Arc::new(Mutex::new(UsageView::default())),
            worker: Arc::new(Mutex::new(UsageState {
                root,
                history: None,
                view: UsageView::default(),
                codex_locator: Default::default(),
                codex_tail: JsonlTail::default(),
                warnings: HashSet::new(),
            })),
            refreshing: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            capture_working: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            activity: super::cache::Activity::new(4),
            timer: None,
            monitor_guard: None,
            health: None,
        }
    }
}
impl Global for UsageGlobal {}
pub fn view(cx: &App) -> UsageView {
    cx.try_global::<UsageGlobal>()
        .map(|g| g.snapshot.lock().clone())
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
    let root = cx.global::<AppData>().root.clone();
    cx.set_global(UsageGlobal::new(root));
    init_health(cx);
    crate::debug::usage::register(cx);
    refresh(cx);
    let timer = crate::observability::register_timer(
        cx,
        "usage.quota",
        "Quota evidence refresh",
        "usage",
        30_000,
    );
    let active = cx
        .global::<UsageGlobal>()
        .activity
        .begin()
        .expect("new quota lifecycle accepts its monitor");
    cx.global_mut::<UsageGlobal>().monitor_guard = Some(active);
    let task = cx.spawn(async move |cx| {
        let _timer = timer;
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
    });
    cx.global_mut::<UsageGlobal>().timer = Some(task);
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
                    .map(|snapshot| UsageProvider::from_snapshot(snapshot, &recent, now))
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
            let sessions = self.root.home().join(".codex/sessions");
            if let Some(path) = self.codex_locator.find(&sessions, Utc::now()) {
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
    let Some(active) = global.activity.begin() else {
        return;
    };
    let state = global.worker.clone();
    let snapshot = global.snapshot.clone();
    let refreshing = global.refreshing.clone();
    let capture_working = global.capture_working.clone();
    if refreshing.swap(true, std::sync::atomic::Ordering::AcqRel) {
        return;
    }
    snapshot.lock().refreshing = true;
    let recorder = crate::telemetry::recorder(cx);
    let settings = Settings::get(cx).general.clone();
    let state2 = state.clone();
    let observed = super::admission::background_observation(cx, async move {
        let _active = active;
        let mut worker = state2.lock();
        let warnings = worker.capture(
            settings.usage_monitoring,
            settings.claude_quota_capture,
            settings.usage_quota_warnings,
        );
        if let Some(recorder) = recorder {
            let before = recorder.store().failure_count();
            let consumption = recorder
                .store()
                .consumption_per_provider(Some(Utc::now() - chrono::Duration::minutes(10)));
            if recorder.store().failure_count() == before && before != u64::MAX {
                worker.view.recent_consumption = Some(consumption);
            } else {
                worker.view.last_error = Some(
                    "Telemetry usage is unavailable; retaining the last successful observation"
                        .into(),
                );
            }
        }
        (warnings, worker.view.clone())
    });
    cx.spawn(async move |cx| {
        let Ok((warnings, mut view)) = observed.await else {
            return;
        };
        cx.update(|cx| {
            refreshing.store(false, std::sync::atomic::Ordering::Release);
            view.refreshing = false;
            view.capture_working = capture_working.load(std::sync::atomic::Ordering::Acquire);
            *snapshot.lock() = view;
            cx.refresh_windows();
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
    let Some(active) = g.activity.begin() else {
        return;
    };
    let state = g.worker.clone();
    let snapshot = g.snapshot.clone();
    let capture_working = g.capture_working.clone();
    let refreshing = g.refreshing.clone();
    if capture_working.swap(true, std::sync::atomic::Ordering::AcqRel) {
        return;
    }
    snapshot.lock().capture_working = true;
    let root = cx.global::<AppData>().root.clone();
    let observed = super::admission::background_observation(cx, async move {
        let _active = active;
        let result = configure_capture(&root, enabled);
        let mut s = state.lock();
        s.view.last_error = result.as_ref().err().cloned();
        s.refresh_view();
        (result, s.view.clone())
    });
    cx.spawn(async move |cx| {
        let Ok((result, mut view)) = observed.await else {
            return;
        };
        cx.update(|cx| {
            capture_working.store(false, std::sync::atomic::Ordering::Release);
            view.capture_working = false;
            view.refreshing = refreshing.load(std::sync::atomic::Ordering::Acquire);
            *snapshot.lock() = view;
            if result.is_ok() {
                crate::settings_window::update(cx, |s| s.general.claude_quota_capture = enabled);
            }
            cx.refresh_windows();
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

    #[test]
    fn isolation_health_worker_decision_preserves_normal_fetches() {
        assert!(!automatic_health_worker_allowed(true));
        assert!(automatic_health_worker_allowed(false));
        assert!(ProviderHealth::default().snapshots.is_empty());
    }

    #[test]
    fn isolation_health_guard_keeps_global_and_precedes_worker_creation() {
        let prefix = include_str!("usage.rs")
            .split_once("fn init_health(cx: &mut App) {")
            .unwrap()
            .1
            .split_once("let executor")
            .unwrap()
            .0;
        assert!(
            prefix
                .find("cx.set_global(HealthGlobal(state.clone()));")
                .unwrap()
                < prefix.find("if !automatic_health_worker_allowed(").unwrap()
        );
        assert!(prefix.contains("chau7_next_core::data_root::is_isolated_test_mode()"));
        assert!(prefix.contains("return;"));
        assert!(!prefix.contains("register_background_timer"));
        assert!(!prefix.contains(".spawn("));
    }

    fn root() -> DataRoot {
        let home = std::env::temp_dir().join(format!("chau7-quota-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        DataRoot::with_home(home, true)
    }
    #[test]
    fn all_four_bucket_dashboards_share_real_activity_and_missing_latency() {
        use chau7_next_core::telemetry::latency::{
            ActivitySample, BucketKind, MetricKind, TimeRange,
        };
        let now = Utc::now();
        let activity = vec![ActivitySample {
            provider: "claude".into(),
            timestamp: now,
        }];
        let dashboards = build_bucket_dashboards(
            &[],
            &activity,
            "claude",
            MetricKind::FirstResponse,
            TimeRange::Week,
            now,
        );
        assert_eq!(
            dashboards.iter().map(|b| b.kind).collect::<Vec<_>>(),
            BucketKind::ALL
        );
        for b in dashboards {
            assert_eq!(b.dashboard.interaction_count, 1);
            assert!(b.dashboard.aggregate.is_none());
            assert_eq!(
                b.dashboard
                    .buckets
                    .iter()
                    .map(|b| b.interactions)
                    .sum::<usize>(),
                1
            );
        }
    }
    #[test]
    fn usage_diagnostics_preserve_unknown_and_observed_zero() {
        use chau7_next_core::telemetry::latency::{LatencyDashboard, MetricKind};
        let settings = crate::settings::GeneralSettings::default();
        let unknown = UsageDiagnostics::from_snapshots(
            &settings,
            UsageView::default(),
            LatencyView::default(),
        );
        let json = serde_json::to_value(unknown).unwrap();
        assert!(json["usage"]["recentConsumption"].is_null());
        assert!(json["latency"]["dashboard"].is_null());
        assert!(json["latency_coverage"].is_null());
        assert!(json["latency"].get("generation").is_none());
        let dashboard = LatencyDashboard {
            provider: "claude".into(),
            metric_kind: MetricKind::FirstResponse,
            aggregate: None,
            interaction_count: 3,
            buckets: vec![],
        };
        let observed = UsageDiagnostics::from_snapshots(
            &settings,
            UsageView {
                recent_consumption: Some(vec![]),
                ..Default::default()
            },
            LatencyView {
                dashboard: Some(dashboard),
                ..Default::default()
            },
        );
        let json = serde_json::to_value(observed).unwrap();
        assert_eq!(json["usage"]["recentConsumption"], serde_json::json!([]));
        assert_eq!(json["latency_coverage"]["sampled_count"], 0);
        assert_eq!(json["latency_coverage"]["fraction"], 0.);
    }
    #[test]
    fn latency_coverage_uses_actual_samples_and_keeps_empty_denominator_unknown() {
        use chau7_next_core::telemetry::latency::{Aggregate, LatencyDashboard, MetricKind};
        let mut dashboard = LatencyDashboard {
            provider: "claude".into(),
            metric_kind: MetricKind::FirstResponse,
            aggregate: Some(Aggregate {
                count: 2,
                average_latency_ms: 10.,
                p50_latency_ms: 10,
                p95_latency_ms: 10,
                min_latency_ms: 10,
                max_latency_ms: 10,
            }),
            interaction_count: 4,
            buckets: vec![],
        };
        let coverage = LatencyCoverage::from_dashboard(&dashboard);
        assert_eq!(coverage.sampled_count, 2);
        assert_eq!(coverage.fraction, Some(0.5));
        dashboard.interaction_count = 0;
        assert_eq!(LatencyCoverage::from_dashboard(&dashboard).fraction, None);
    }
    #[test]
    fn stale_quota_snapshots_keep_observed_values_but_not_active_warnings() {
        use chau7_next_core::telemetry::quota::QuotaWindow;
        let now = Utc::now();
        let snapshot = QuotaSnapshot {
            provider: "claude".into(),
            captured_at: now,
            source: "test".into(),
            plan_type: None,
            credits: None,
            raw_source_ref: None,
            windows: vec![QuotaWindow {
                id: "session".into(),
                used_percent: 96.,
                window_minutes: Some(300),
                resets_at: Some(now + chrono::Duration::hours(2)),
            }],
        };
        let fresh = UsageProvider::from_snapshot(snapshot.clone(), &[], now);
        assert_eq!(fresh.active_warnings.len(), 1);
        let stale = UsageProvider::from_snapshot(
            snapshot.clone(),
            &[],
            now + chrono::Duration::minutes(16),
        );
        assert!(stale.active_warnings.is_empty());
        assert_eq!(stale.metrics[0].window.used_percent, 96.);
        let future =
            UsageProvider::from_snapshot(snapshot, &[], now - chrono::Duration::seconds(1));
        assert!(future.active_warnings.is_empty());
    }
    #[test]
    fn rendering_snapshot_stays_readable_while_worker_is_busy() {
        let root = DataRoot::with_home(
            std::env::temp_dir().join(format!("chau7-quota-cache-{}", uuid::Uuid::new_v4())),
            true,
        );
        let global = UsageGlobal::new(root);
        let _busy_worker = global.worker.lock();
        let cached = global
            .snapshot
            .try_lock()
            .expect("renderer must not share the worker mutex");
        assert!(cached.providers.is_empty());
        assert!(cached.recent_consumption.is_none());
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

/// Cached latency read model. History reads and aggregation stay off the UI thread.
#[derive(Debug, Clone, Serialize)]
pub struct EvidenceDiagnostics {
    pub retained_records: usize,
    pub reconciled_groups: usize,
    pub priced_groups: usize,
    pub missing_cost_groups: usize,
    pub unassigned_requests: Option<usize>,
    pub total_cost_usd: Option<f64>,
    pub token_groups: usize,
    pub token_usage: chau7_next_core::telemetry::token_metrics::TokenUsage,
    pub incomplete_window: bool,
    pub groups: Vec<EvidenceGroup>,
}
#[derive(Debug, Clone, Serialize)]
pub struct EvidenceGroup {
    pub provider: String,
    pub scope: String,
    pub source: String,
    pub confidence: String,
    pub tokens: Option<i64>,
    pub cost_usd: Option<f64>,
    pub alternatives: usize,
}
#[derive(Debug, Clone, Serialize)]
pub struct LatencyBucketDashboard {
    pub kind: chau7_next_core::telemetry::latency::BucketKind,
    pub dashboard: chau7_next_core::telemetry::latency::LatencyDashboard,
}

#[derive(Debug, Clone, Serialize)]
pub struct LatencyView {
    pub range: chau7_next_core::telemetry::latency::TimeRange,
    pub bucket: chau7_next_core::telemetry::latency::BucketKind,
    pub metric: chau7_next_core::telemetry::latency::MetricKind,
    pub selected_provider: Option<String>,
    pub providers: Vec<String>,
    pub dashboard: Option<chau7_next_core::telemetry::latency::LatencyDashboard>,
    pub bucket_dashboards: Vec<LatencyBucketDashboard>,
    pub refreshed_at: Option<DateTime<Utc>>,
    pub refreshing: bool,
    pub error: Option<String>,
    pub evidence: Option<EvidenceDiagnostics>,
    #[serde(skip_serializing)]
    generation: u64,
}
impl Default for LatencyView {
    fn default() -> Self {
        Self {
            range: chau7_next_core::telemetry::latency::TimeRange::Week,
            bucket: chau7_next_core::telemetry::latency::BucketKind::Day,
            metric: chau7_next_core::telemetry::latency::MetricKind::FirstResponse,
            selected_provider: None,
            providers: vec![],
            dashboard: None,
            bucket_dashboards: vec![],
            refreshed_at: None,
            refreshing: false,
            generation: 0,
            error: None,
            evidence: None,
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct LatencyCoverage {
    pub sampled_count: usize,
    pub interaction_count: usize,
    pub fraction: Option<f64>,
}
impl LatencyCoverage {
    pub fn from_dashboard(
        dashboard: &chau7_next_core::telemetry::latency::LatencyDashboard,
    ) -> Self {
        let sampled_count = dashboard.aggregate.as_ref().map_or(0, |a| a.count);
        Self {
            sampled_count,
            interaction_count: dashboard.interaction_count,
            fraction: (dashboard.interaction_count > 0)
                .then(|| sampled_count as f64 / dashboard.interaction_count as f64),
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct UsageDiagnostics {
    pub schema_version: u32,
    pub captured_at: DateTime<Utc>,
    pub monitoring_enabled: bool,
    pub quota_warnings_enabled: bool,
    pub number_format: String,
    pub usage: UsageView,
    pub latency: LatencyView,
    pub latency_coverage: Option<LatencyCoverage>,
}
impl UsageDiagnostics {
    fn from_snapshots(
        settings: &crate::settings::GeneralSettings,
        usage: UsageView,
        latency: LatencyView,
    ) -> Self {
        let latency_coverage = latency
            .dashboard
            .as_ref()
            .map(LatencyCoverage::from_dashboard);
        Self {
            schema_version: 1,
            captured_at: Utc::now(),
            monitoring_enabled: settings.usage_monitoring,
            quota_warnings_enabled: settings.usage_quota_warnings,
            number_format: settings.regional_number_format.id().into(),
            usage,
            latency,
            latency_coverage,
        }
    }
}
pub fn diagnostics(cx: &App) -> UsageDiagnostics {
    UsageDiagnostics::from_snapshots(&Settings::get(cx).general, view(cx), latency_view(cx))
}

fn build_bucket_dashboards(
    samples: &[chau7_next_core::telemetry::latency::LatencySample],
    activity: &[chau7_next_core::telemetry::latency::ActivitySample],
    provider: &str,
    metric: chau7_next_core::telemetry::latency::MetricKind,
    range: chau7_next_core::telemetry::latency::TimeRange,
    now: DateTime<Utc>,
) -> Vec<LatencyBucketDashboard> {
    chau7_next_core::telemetry::latency::BucketKind::ALL
        .into_iter()
        .map(|kind| LatencyBucketDashboard {
            kind,
            dashboard: chau7_next_core::telemetry::latency::dashboard(
                samples, activity, provider, metric, kind, range, now,
            ),
        })
        .collect()
}

struct LatencyRequest {
    shared: Arc<Mutex<LatencyView>>,
    selection: LatencyView,
    root: chau7_next_core::data_root::DataRoot,
    recorder: Arc<chau7_next_core::telemetry::recorder::TelemetryRecorder>,
    retention_days: i64,
}
#[derive(Default)]
struct MaintenancePending {
    stopped: bool,
    running: bool,
    latest: Option<LatencyRequest>,
}
impl MaintenancePending {
    fn replace(&mut self, request: LatencyRequest) -> bool {
        if self.stopped {
            return false;
        }
        self.latest = Some(request);
        if self.running {
            false
        } else {
            self.running = true;
            true
        }
    }
    fn next(&mut self) -> Option<LatencyRequest> {
        if self.stopped {
            self.latest = None;
        }
        let request = self.latest.take();
        if request.is_none() {
            self.running = false;
        }
        request
    }
}
struct Maintenance {
    pending: Arc<Mutex<MaintenancePending>>,
    activity: Arc<super::cache::Activity>,
    timer: Option<gpui::Task<()>>,
    monitor_guard: Option<super::cache::WorkGuard>,
}
impl Global for Maintenance {}
/// Stop new work and cancel the existing monitor. Completion waits off UI.
pub(super) fn shutdown_quota(cx: &mut App) -> Option<super::cache::Drain> {
    cx.try_global::<UsageGlobal>()?;
    let usage = cx.global_mut::<UsageGlobal>();
    drop(usage.timer.take());
    // Cancellation closes UI dispatch now; the future may be destroyed later.
    drop(usage.monitor_guard.take());
    drop(usage.health.take());
    Some(usage.activity.stop())
}
pub(super) fn shutdown_maintenance(cx: &mut App) -> Option<super::cache::Drain> {
    cx.try_global::<Maintenance>()?;
    let global = cx.global_mut::<Maintenance>();
    {
        let mut pending = global.pending.lock();
        pending.stopped = true;
        pending.latest = None;
    }
    drop(global.timer.take());
    drop(global.monitor_guard.take());
    Some(global.activity.stop())
}
pub(super) fn maintenance_diagnostics(cx: &App) -> serde_json::Value {
    cx.try_global::<Maintenance>()
        .map(|m| {
            let pending = m.pending.lock();
            serde_json::json!({"accepting": !pending.stopped, "running":pending.running,
            "replacement_pending":pending.latest.is_some(), "activity":m.activity.diagnostics()})
        })
        .unwrap_or(serde_json::Value::Null)
}
fn maintenance_guard(cx: &App) -> Option<super::cache::WorkGuard> {
    cx.try_global::<Maintenance>()?.activity.begin()
}
struct LatencyGlobal(Arc<Mutex<LatencyView>>);
impl Global for LatencyGlobal {}
pub fn latency_view(cx: &App) -> LatencyView {
    cx.try_global::<LatencyGlobal>()
        .map(|g| g.0.lock().clone())
        .unwrap_or_default()
}
pub fn init_latency(cx: &mut App) {
    cx.set_global(Maintenance {
        pending: Arc::new(Mutex::new(MaintenancePending::default())),
        activity: super::cache::Activity::new(6),
        timer: None,
        monitor_guard: None,
    });
    cx.set_global(RetentionGlobal(Arc::new(Mutex::new(RetentionView {
        selected_days: Settings::get(cx).general.telemetry_retention_days,
        ..Default::default()
    }))));
    cx.set_global(LatencyGlobal(Arc::new(Mutex::new(LatencyView::default()))));
    refresh_latency(cx);
    let timer = crate::observability::register_timer(
        cx,
        "usage.latency",
        "Latency and activity history refresh",
        "usage",
        30_000,
    );
    let active = maintenance_guard(cx).expect("new maintenance monitor accepts its task");
    cx.global_mut::<Maintenance>().monitor_guard = Some(active);
    let task = cx.spawn(async move |cx| {
        let _timer = timer;
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(30))
                .await;
            cx.update(refresh_latency);
        }
    });
    cx.global_mut::<Maintenance>().timer = Some(task);
}
pub fn select_latency(
    range: Option<chau7_next_core::telemetry::latency::TimeRange>,
    bucket: Option<chau7_next_core::telemetry::latency::BucketKind>,
    metric: Option<chau7_next_core::telemetry::latency::MetricKind>,
    provider: Option<String>,
    cx: &mut App,
) {
    if let Some(global) = cx.try_global::<LatencyGlobal>() {
        let mut s = global.0.lock();
        if let Some(r) = range {
            s.range = r;
        }
        if let Some(b) = bucket {
            s.bucket = b;
        }
        if let Some(m) = metric {
            s.metric = m;
        }
        if let Some(p) = provider {
            s.selected_provider = Some(p);
        }
    }
    refresh_latency(cx);
}
pub fn refresh_latency(cx: &mut App) {
    let (Some(global), Some(recorder), Some(maintenance)) = (
        cx.try_global::<LatencyGlobal>(),
        crate::telemetry::recorder(cx),
        cx.try_global::<Maintenance>(),
    ) else {
        return;
    };
    use chau7_next_core::telemetry::store::StoreReadiness;
    let readiness = recorder.store().readiness();
    if readiness != StoreReadiness::Ready {
        let mut state = global.0.lock();
        state.refreshing = readiness == StoreReadiness::Loading;
        state.error = if readiness == StoreReadiness::Loading {
            None
        } else {
            Some(
                "Telemetry database is unavailable; retaining the last successful observation"
                    .into(),
            )
        };
        return;
    }
    let shared = global.0.clone();
    let mut pending = maintenance.pending.lock();
    if pending.stopped {
        return;
    }
    let selection = {
        let mut state = shared.lock();
        state.refreshing = true;
        state.generation = state.generation.wrapping_add(1);
        state.clone()
    };
    // A running request has at most one newest replacement, independent of
    // rapid tab/metric selection. Only this worker performs the expensive I/O.
    if !pending.replace(LatencyRequest {
        shared: shared.clone(),
        selection,
        root: cx.global::<AppData>().root.clone(),
        recorder,
        retention_days: Settings::get(cx).general.telemetry_retention_days,
    }) {
        return;
    }
    let Some(active) = maintenance.activity.begin() else {
        pending.latest = None;
        pending.running = false;
        let mut state = shared.lock();
        state.refreshing = false;
        state.error = Some("Telemetry maintenance is busy; request was not accepted".into());
        return;
    };
    let pending = maintenance.pending.clone();
    let observed = super::admission::background_observation(cx, async move {
        let _active = active;
        loop {
            let Some(request) = pending.lock().next() else {
                break;
            };
            refresh_latency_request(request);
        }
    });
    cx.spawn(async move |cx| {
        if observed.await.is_ok() {
            cx.update(|cx| cx.refresh_windows());
        }
    })
    .detach();
}
fn refresh_latency_request(request: LatencyRequest) {
    let LatencyRequest {
        shared,
        selection,
        root,
        recorder,
        retention_days,
    } = request;
    let mut span =
        chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
            "telemetry_maintenance",
            "refresh",
            "telemetry",
            "telemetry_maintenance",
            chau7_next_core::work_profiler::Queue::Background,
        ));
    span.items(1);
    let before = recorder.store().failure_count();
    let proxy_path = root.proxy_db();
    let proxy = chau7_next_core::proxy::ProxyAnalyticsStore::new(&proxy_path);
    let now = Utc::now();
    let start = selection.range.start(now);
    let retained = proxy.evidence_batch(recorder.store().evidence_cursor(), 100);
    recorder.store().ingest_evidence_batch(&retained);
    if retention_days > 0 {
        let protected = recorder
            .all_active_runs()
            .into_iter()
            .map(|r| r.id)
            .collect::<Vec<_>>();
        match recorder
            .store()
            .prune_retained(retention_days, &protected, 100, now)
        {
            Ok(report) => {
                if report.rows() > 0 {
                    log::info!(
                        "Telemetry retention: removed {} runs and {} independent records",
                        report.runs,
                        report.rows() - report.runs
                    );
                }
                if let Some(error) = report.compaction_error {
                    log::warn!("Telemetry post-retention compaction failed: {error}");
                }
            }
            Err(error) => log::warn!("Telemetry retention failed: {error}"),
        }
    }
    recorder.store().backfill_latency_batch(100);
    recorder.store().backfill_cost_batch(100);
    let mut samples = recorder.store().latency_samples(start);
    samples.extend(proxy.latency_samples(start));
    let mut activity = recorder.store().activity_samples(start);
    activity.extend(proxy.activity_samples(start));
    let mut providers: Vec<_> = samples
        .iter()
        .map(|s| s.provider.clone())
        .chain(activity.iter().map(|s| s.provider.clone()))
        .collect();
    providers.sort();
    providers.dedup();
    let selected = selection
        .selected_provider
        .filter(|p| providers.contains(p))
        .or_else(|| {
            ["codex", "claude", "anthropic", "openai", "gemini"]
                .into_iter()
                .find(|p| providers.iter().any(|s| s == p))
                .map(str::to_string)
        })
        .or_else(|| providers.first().cloned());
    let bucket_dashboards = selected
        .as_ref()
        .map(|provider| {
            build_bucket_dashboards(
                &samples,
                &activity,
                provider,
                selection.metric,
                selection.range,
                now,
            )
        })
        .unwrap_or_default();
    let dashboard = bucket_dashboards
        .iter()
        .find(|bucket| bucket.kind == selection.bucket)
        .map(|bucket| bucket.dashboard.clone());
    let retained = recorder.store().usage_evidence(start, 5001);
    let incomplete = retained.len() > 5000;
    let selected_records: Vec<_> = retained
        .iter()
        .take(5000)
        .filter(|e| selected.as_ref().is_none_or(|p| e.provider == *p))
        .cloned()
        .collect();
    let report = chau7_next_core::telemetry::evidence::reconcile(&selected_records);
    let runs = recorder
        .store()
        .list_runs(&chau7_next_core::telemetry::run::TelemetryRunFilter {
            limit: Some(501),
            ..Default::default()
        });
    let attributed = chau7_next_core::telemetry::evidence::attributed(&selected_records, &runs);
    let assigned: HashSet<_> = attributed
        .values()
        .flat_map(|a| a.evidence_ids.iter().cloned())
        .collect();
    let unassigned = selected_records
        .iter()
        .filter(|e| {
            e.source_kind == chau7_next_core::telemetry::evidence::SourceKind::Proxy
                && !e.unique_event_key.starts_with("run|")
                && !assigned.contains(&e.id)
        })
        .count();
    let priced_groups = report
        .groups
        .iter()
        .filter(|g| g.selected.evidence.cost_usd.is_some())
        .count();
    let evidence = EvidenceDiagnostics {
        retained_records: selected_records.len(),
        reconciled_groups: report.groups.len(),
        priced_groups,
        missing_cost_groups: report.groups.len() - priced_groups,
        unassigned_requests: (runs.len() <= 500).then_some(unassigned),
        token_groups: report
            .groups
            .iter()
            .filter(|g| g.selected.evidence.has_tokens())
            .count(),
        total_cost_usd: (priced_groups > 0).then_some(report.total_cost_usd),
        token_usage: report.total_token_usage,
        incomplete_window: incomplete || runs.len() > 500,
        groups: report
            .groups
            .iter()
            .take(32)
            .map(|g| EvidenceGroup {
                provider: g.provider.clone(),
                scope: g.reconciliation_key.clone(),
                source: format!("{:?}", g.selected.evidence.source_kind),
                confidence: g.confidence.clone(),
                tokens: g
                    .selected
                    .evidence
                    .has_tokens()
                    .then_some(g.selected.usage().total_billable_tokens()),
                cost_usd: g.selected.evidence.cost_usd,
                alternatives: g.alternatives.len(),
            })
            .collect(),
    };
    let mut s = shared.lock();
    if s.generation != selection.generation {
        return;
    }
    if proxy.failure_count() > 0 || recorder.store().failure_count() != before || before == u64::MAX
    {
        s.refreshing = false;
        s.error = Some(
            "Telemetry history is unavailable; retaining the last successful observation".into(),
        );
        return;
    }
    s.error = None;
    s.providers = providers;
    s.selected_provider = selected;
    s.dashboard = dashboard;
    s.bucket_dashboards = bucket_dashboards;
    s.evidence = Some(evidence);
    s.refreshed_at = Some(now);
    s.refreshing = false;
}

#[derive(Debug, Clone, Default)]
pub struct RetentionView {
    pub selected_days: i64,
    pub preview: Option<chau7_next_core::telemetry::retention::RetentionPreview>,
    pub previewed_at: Option<DateTime<Utc>>,
    pub working: bool,
    pub error: Option<String>,
    pub compact_confirmation: bool,
    pub compacted_at: Option<DateTime<Utc>>,
    generation: u64,
}
struct RetentionGlobal(Arc<Mutex<RetentionView>>);
impl Global for RetentionGlobal {}
pub fn retention_state(cx: &App) -> Option<Arc<Mutex<RetentionView>>> {
    cx.try_global::<RetentionGlobal>().map(|s| s.0.clone())
}
pub fn retention_view(cx: &App) -> RetentionView {
    cx.try_global::<RetentionGlobal>()
        .map(|s| s.0.lock().clone())
        .unwrap_or_default()
}
/// Selecting an expiry only previews its effects. No setting or data is changed.
pub fn preview_retention(days: i64, cx: &mut App) {
    let (Some(global), Some(recorder)) = (
        cx.try_global::<RetentionGlobal>(),
        crate::telemetry::recorder(cx),
    ) else {
        return;
    };
    let days = chau7_next_core::telemetry::retention::normalize_days(days);
    let Some(active) = maintenance_guard(cx) else {
        global.0.lock().error =
            Some("Telemetry maintenance is busy or stopped; request was not accepted".into());
        cx.refresh_windows();
        return;
    };
    let shared = global.0.clone();
    let generation = {
        let mut s = shared.lock();
        s.selected_days = days;
        s.preview = None;
        s.previewed_at = None;
        s.error = None;
        s.working = true;
        s.generation += 1;
        s.generation
    };
    let observed = super::admission::background_observation(cx, async move {
        let _active = active;
        let protected = recorder
            .all_active_runs()
            .into_iter()
            .map(|r| r.id)
            .collect::<Vec<_>>();
        recorder
            .store()
            .retention_preview(days, &protected, Utc::now())
            .map_err(|e| e.to_string())
    });
    cx.spawn(async move |cx| {
        let Ok(result) = observed.await else {
            return;
        };
        cx.update(|cx| {
            let mut s = shared.lock();
            if s.generation != generation {
                return;
            }
            s.working = false;
            match result {
                Ok(preview) => {
                    s.preview = Some(preview);
                    s.previewed_at = Some(Utc::now());
                }
                Err(error) => s.error = Some(error),
            }
            cx.refresh_windows();
        });
    })
    .detach();
}
/// This separate click is required after the read-only preview completes.
pub fn apply_retention(cx: &mut App) {
    let view = retention_view(cx);
    if view.working
        || view.preview.is_none()
        || view
            .previewed_at
            .is_none_or(|at| Utc::now().signed_duration_since(at).num_seconds() > 300)
    {
        return;
    }
    crate::settings_window::update(cx, |s| {
        s.general.telemetry_retention_days = view.selected_days
    });
    refresh_latency(cx);
}
pub fn request_compaction(cx: &mut App) {
    if let Some(global) = cx.try_global::<RetentionGlobal>() {
        let mut s = global.0.lock();
        if !s.working {
            s.compact_confirmation = true;
        }
    }
    cx.refresh_windows();
}
pub fn cancel_compaction(cx: &mut App) {
    if let Some(global) = cx.try_global::<RetentionGlobal>() {
        global.0.lock().compact_confirmation = false;
    }
    cx.refresh_windows();
}
/// Separate manual compaction never deletes records. Retention also compacts
/// automatically after a committed deletion, following the current Swift policy.
pub fn compact_confirmed(cx: &mut App) {
    let (Some(global), Some(recorder)) = (
        cx.try_global::<RetentionGlobal>(),
        crate::telemetry::recorder(cx),
    ) else {
        return;
    };
    let Some(active) = maintenance_guard(cx) else {
        global.0.lock().error =
            Some("Telemetry maintenance is busy or stopped; request was not accepted".into());
        cx.refresh_windows();
        return;
    };
    let shared = global.0.clone();
    {
        let mut s = shared.lock();
        if !s.compact_confirmation || s.working {
            return;
        }
        s.compact_confirmation = false;
        s.working = true;
        s.error = None;
    }
    let observed = super::admission::background_observation(cx, async move {
        let _active = active;
        recorder
            .store()
            .compact_confirmed()
            .map_err(|e| e.to_string())
    });
    cx.spawn(async move |cx| {
        let Ok(result) = observed.await else {
            return;
        };
        cx.update(|cx| {
            let mut s = shared.lock();
            s.working = false;
            match result {
                Ok(()) => s.compacted_at = Some(Utc::now()),
                Err(e) => s.error = Some(e),
            }
            cx.refresh_windows();
        });
    })
    .detach();
}

#[cfg(test)]
mod maintenance_tests {
    use super::*;
    use chau7_next_core::telemetry::{
        recorder::TelemetryRecorder, run::TelemetryRun, store::TelemetryStore,
    };
    #[test]
    fn actual_owned_worker_compacts_deleted_runs_and_preserves_snapshot_on_sql_failure() {
        let directory = std::env::temp_dir().join(format!(
            "next-telemetry-maintenance-{}",
            uuid::Uuid::new_v4()
        ));
        let root = chau7_next_core::data_root::DataRoot::with_home(directory.clone(), true);
        root.ensure_dirs().unwrap();
        let store = Arc::new(TelemetryStore::open(&root.telemetry_db()));
        let mut expired = TelemetryRun::new("owned-fake", "/synthetic");
        expired.started_at = Utc::now() - chrono::Duration::days(40);
        expired.ended_at = Some(expired.started_at + chrono::Duration::seconds(1));
        store.insert_run(&expired);
        let recorder = Arc::new(TelemetryRecorder::new(store.clone(), vec![]));
        let shared = Arc::new(Mutex::new(LatencyView::default()));
        let request = LatencyRequest {
            shared: shared.clone(),
            selection: shared.lock().clone(),
            root: root.clone(),
            recorder: recorder.clone(),
            retention_days: 30,
        };
        let caller = std::thread::current().id();
        let worker = std::thread::spawn(move || {
            let thread = std::thread::current().id();
            refresh_latency_request(request);
            thread
        })
        .join()
        .unwrap();
        assert_ne!(caller, worker);
        assert!(store.get_run(&expired.id).is_none());
        let success = shared.lock().clone();
        assert!(success.refreshed_at.is_some());
        assert!(success.error.is_none());
        store.execute_raw("DROP TABLE runs");
        let request = LatencyRequest {
            shared: shared.clone(),
            selection: shared.lock().clone(),
            root,
            recorder: recorder.clone(),
            retention_days: 0,
        };
        std::thread::spawn(move || refresh_latency_request(request))
            .join()
            .unwrap();
        let error = shared.lock().clone();
        assert!(error.error.is_some());
        assert_eq!(error.refreshed_at, success.refreshed_at);
        assert_eq!(error.providers, success.providers);
        assert!(!error.refreshing);
        let writer = recorder.shutdown().unwrap();
        std::thread::spawn(move || writer.finish().unwrap())
            .join()
            .unwrap();
        drop(recorder);
        drop(store);
        drop(shared);
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn pending_refresh_retains_only_the_latest_selection_without_io() {
        let store = Arc::new(TelemetryStore::in_memory());
        let recorder = Arc::new(TelemetryRecorder::new(store, vec![]));
        let shared = Arc::new(Mutex::new(LatencyView::default()));
        let root = chau7_next_core::data_root::DataRoot::with_home(
            std::env::temp_dir().join("not-created-maintenance-policy"),
            true,
        );
        let mut pending = MaintenancePending {
            running: true,
            ..Default::default()
        };
        for generation in 1..=200 {
            let selection = LatencyView {
                generation,
                ..Default::default()
            };
            assert!(!pending.replace(LatencyRequest {
                shared: shared.clone(),
                selection,
                root: root.clone(),
                recorder: recorder.clone(),
                retention_days: 0,
            }));
        }
        assert!(pending.running);
        assert_eq!(pending.latest.as_ref().unwrap().selection.generation, 200);
        pending.stopped = true;
        assert!(pending.next().is_none());
        assert!(pending.latest.is_none());
        assert!(!pending.running);
        let writer = recorder.shutdown().unwrap();
        std::thread::spawn(move || writer.finish().unwrap())
            .join()
            .unwrap();
    }
}

#[cfg(test)]
mod admission_tests {
    use super::*;
    use futures::channel::oneshot;
    use std::{cell::Cell, rc::Rc};

    #[gpui::test]
    fn canceling_unpolled_ui_monitors_releases_only_their_lifetime_guards(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.background_executor.allow_parking();
        let polled = Rc::new(Cell::new(false));
        cx.update(|app| {
            let root = DataRoot::with_home(
                std::env::temp_dir().join(format!("next-monitor-drain-{}", uuid::Uuid::new_v4())),
                true,
            );
            let mut quota = UsageGlobal::new(root);
            quota.monitor_guard = quota.activity.begin();
            let quota_polled = polled.clone();
            quota.timer = Some(app.spawn(async move |_| {
                quota_polled.set(true);
                std::future::pending::<()>().await;
            }));
            app.set_global(quota);
            let activity = super::super::cache::Activity::new(6);
            let monitor_guard = activity.begin();
            let latency_polled = polled.clone();
            app.set_global(Maintenance {
                pending: Arc::new(Mutex::new(MaintenancePending::default())),
                activity,
                monitor_guard,
                timer: Some(app.spawn(async move |_| {
                    latency_polled.set(true);
                    std::future::pending::<()>().await;
                })),
            });
            let quota = shutdown_quota(app).unwrap();
            let latency = shutdown_maintenance(app).unwrap();
            assert_eq!(
                app.global::<UsageGlobal>().activity.diagnostics()["in_flight"],
                0
            );
            assert_eq!(
                app.global::<Maintenance>().activity.diagnostics()["in_flight"],
                0
            );
            let (done, drained) = oneshot::channel();
            let drainer = std::thread::spawn(move || {
                quota.finish();
                latency.finish();
                done.send(()).unwrap();
            });
            // Drop schedules final task destruction on a blocked foreground
            // queue. Its monitor-only guard must not be owned by that future.
            app.foreground_executor().block_on(drained).unwrap();
            drainer.join().unwrap();
        });
        assert!(!polled.get(), "foreground monitor unexpectedly ran");
    }
}

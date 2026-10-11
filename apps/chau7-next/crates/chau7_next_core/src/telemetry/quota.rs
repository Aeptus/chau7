//! Provider quota windows preserve unknown values and reset-scoped warnings.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub id: String,
    pub used_percent: f64,
    pub window_minutes: Option<i64>,
    pub resets_at: Option<DateTime<Utc>>,
}
impl QuotaWindow {
    pub fn remaining(&self) -> f64 {
        (100. - self.used_percent).max(0.)
    }
    pub fn key(&self) -> String {
        self.window_minutes
            .map(|m| format!("{m}m"))
            .unwrap_or_else(|| self.id.to_lowercase())
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub provider: String,
    pub captured_at: DateTime<Utc>,
    pub source: String,
    pub plan_type: Option<String>,
    pub credits: Option<f64>,
    pub raw_source_ref: Option<String>,
    pub windows: Vec<QuotaWindow>,
}
fn number(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str()?.parse().ok())
        .filter(|n| n.is_finite())
}
fn date(v: &Value) -> Option<DateTime<Utc>> {
    if let Some(s) = v.as_str() {
        DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|d| d.with_timezone(&Utc))
            .or_else(|| {
                s.parse::<i64>()
                    .ok()
                    .and_then(|i| DateTime::from_timestamp(i, 0))
            })
    } else {
        v.as_i64().and_then(|i| DateTime::from_timestamp(i, 0))
    }
}
impl QuotaSnapshot {
    pub fn parse_claude(v: &Value, at: DateTime<Utc>, path: Option<String>) -> Option<Self> {
        Self::parse(
            v,
            v.get("rate_limits")?,
            "claude",
            "claude_statusline",
            at,
            path,
            true,
        )
    }
    pub fn parse_codex(v: &Value, path: Option<String>) -> Option<Self> {
        let at = date(v.get("timestamp")?)?;
        let payload = v.get("payload")?;
        Self::parse(
            payload.get("rate_limits")?,
            payload.get("rate_limits")?,
            "codex",
            "codex_rollout",
            at,
            path,
            false,
        )
    }
    fn parse(
        root: &Value,
        limits: &Value,
        provider: &str,
        source: &str,
        at: DateTime<Utc>,
        path: Option<String>,
        claude: bool,
    ) -> Option<Self> {
        let mut windows = Vec::new();
        for (id, default_minutes) in if claude {
            [("five_hour", Some(300)), ("seven_day", Some(10080))]
        } else {
            [("primary", None), ("secondary", None)]
        } {
            let Some(w) = limits.get(id) else { continue };
            let Some(used) = w
                .get("used_percentage")
                .or_else(|| w.get("used_percent"))
                .and_then(number)
            else {
                continue;
            };
            windows.push(QuotaWindow {
                id: id.to_owned(),
                used_percent: used.clamp(0., 100.),
                window_minutes: w
                    .get("window_minutes")
                    .and_then(Value::as_i64)
                    .or(default_minutes),
                resets_at: w.get("resets_at").and_then(date),
            });
        }
        if windows.is_empty() {
            return None;
        }
        windows.sort_by_key(|w| (w.window_minutes.unwrap_or(i64::MAX), w.id.clone()));
        Some(Self {
            provider: provider.to_owned(),
            captured_at: at,
            source: source.to_owned(),
            plan_type: root
                .get("plan_type")
                .and_then(Value::as_str)
                .map(str::to_owned),
            credits: root.get("credits").and_then(number),
            raw_source_ref: path,
            windows,
        })
    }
    pub fn equivalent_usage(&self, old: &Self) -> bool {
        self.provider.eq_ignore_ascii_case(&old.provider)
            && self.plan_type == old.plan_type
            && self.credits == old.credits
            && self.windows == old.windows
    }
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaMetrics {
    pub window: QuotaWindow,
    pub recent_burn_percent_per_minute: Option<f64>,
    pub sustainable_percent_per_minute: Option<f64>,
    pub remaining_minutes: Option<f64>,
    pub is_unsustainable: bool,
}
pub fn metrics(
    latest: &QuotaSnapshot,
    recent: &[QuotaSnapshot],
    now: DateTime<Utc>,
) -> Vec<QuotaMetrics> {
    latest
        .windows
        .iter()
        .map(|window| {
            let mut points: Vec<_> = recent
                .iter()
                .filter(|s| s.provider.eq_ignore_ascii_case(&latest.provider))
                .filter_map(|s| {
                    let w = s.windows.iter().find(|w| w.key() == window.key())?;
                    if let (Some(a), Some(b)) = (w.resets_at, window.resets_at)
                        && a.signed_duration_since(b).num_seconds().abs() > 1
                    {
                        return None;
                    }
                    Some((s.captured_at, w.used_percent))
                })
                .collect();
            points.sort_by_key(|(at, _)| *at);
            let burn = points
                .first()
                .zip(points.last())
                .and_then(|((a, x), (b, y))| {
                    let mins = b.signed_duration_since(*a).num_milliseconds() as f64 / 60000.;
                    (mins > 0.).then(|| ((y - x) / mins).max(0.))
                });
            let remaining_minutes = window.resets_at.map(|reset| {
                (reset.signed_duration_since(now).num_milliseconds() as f64 / 60000.).max(0.)
            });
            let sustainable = remaining_minutes
                .filter(|m| *m > 0.)
                .map(|m| window.remaining() / m);
            let unsustainable = burn.zip(sustainable).is_some_and(|(b, s)| s > 0. && b > s);
            QuotaMetrics {
                window: window.clone(),
                recent_burn_percent_per_minute: burn,
                sustainable_percent_per_minute: sustainable,
                remaining_minutes,
                is_unsustainable: unsustainable,
            }
        })
        .collect()
}
#[derive(Debug, Clone, Serialize)]
pub struct QuotaWarning {
    pub id: String,
    pub provider: String,
    pub window: QuotaWindow,
    pub kind: &'static str,
}
pub fn warnings(
    latest: &QuotaSnapshot,
    recent: &[QuotaSnapshot],
    now: DateTime<Utc>,
) -> Vec<QuotaWarning> {
    metrics(latest, recent, now)
        .into_iter()
        .filter_map(|m| {
            if m.remaining_minutes.unwrap_or(f64::INFINITY) <= 10. {
                return None;
            }
            let kind = if m.window.remaining() <= 5. {
                "remaining5"
            } else if m.window.remaining() <= 10. {
                "remaining10"
            } else if m.window.remaining() <= 20. {
                "remaining20"
            } else if m.is_unsustainable {
                "unsustainablePace"
            } else {
                return None;
            };
            Some(QuotaWarning {
                id: format!(
                    "{}|{}|{}|{}",
                    latest.provider.to_lowercase(),
                    m.window.key(),
                    kind,
                    m.window
                        .resets_at
                        .map(|d| d.timestamp().to_string())
                        .unwrap_or_else(|| "no-reset".into())
                ),
                provider: latest.provider.clone(),
                window: m.window,
                kind,
            })
        })
        .collect()
}
/// Bounded snapshot history with cached per-provider deduplication.
pub struct QuotaHistory {
    path: std::path::PathBuf,
    pub snapshots: Vec<QuotaSnapshot>,
}
impl QuotaHistory {
    pub fn open(path: std::path::PathBuf) -> std::io::Result<Self> {
        use std::io::{Read, Seek, SeekFrom};
        let snapshots = match std::fs::File::open(&path) {
            Ok(mut file) => {
                let size = file.metadata()?.len();
                let start = size.saturating_sub(8 * 1024 * 1024);
                file.seek(SeekFrom::Start(start))?;
                let mut bytes = Vec::new();
                file.take(8 * 1024 * 1024).read_to_end(&mut bytes)?;
                if start > 0
                    && let Some(i) = bytes.iter().position(|b| *b == b'\n')
                {
                    bytes.drain(..=i);
                }
                String::from_utf8_lossy(&bytes)
                    .lines()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect()
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => vec![],
            Err(e) => return Err(e),
        };
        Ok(Self { path, snapshots })
    }
    pub fn append(&mut self, snapshot: QuotaSnapshot) -> std::io::Result<bool> {
        use std::io::Write;
        let previous = self
            .snapshots
            .iter()
            .rev()
            .find(|s| s.provider.eq_ignore_ascii_case(&snapshot.provider));
        if previous
            .is_some_and(|s| snapshot.captured_at <= s.captured_at || snapshot.equivalent_usage(s))
        {
            return Ok(false);
        }
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        serde_json::to_writer(&mut file, &snapshot)?;
        file.write_all(b"\n")?;
        file.flush()?;
        self.snapshots.push(snapshot);
        if self.snapshots.len() > 10_000 || file.metadata()?.len() > 8 * 1024 * 1024 {
            let drain = self.snapshots.len().saturating_sub(5000);
            self.snapshots.drain(..drain);
            let temp = self.path.with_extension("jsonl.tmp");
            let mut file = std::fs::File::create(&temp)?;
            for s in &self.snapshots {
                serde_json::to_writer(&mut file, s)?;
                file.write_all(b"\n")?;
            }
            file.sync_all()?;
            std::fs::rename(temp, &self.path)?;
        }
        Ok(true)
    }
    pub fn latest(&self) -> Vec<QuotaSnapshot> {
        let mut latest = std::collections::BTreeMap::new();
        for s in &self.snapshots {
            let key = s.provider.to_lowercase();
            let entry = latest.entry(key).or_insert(s);
            if s.captured_at > entry.captured_at {
                *entry = s;
            }
        }
        latest.into_values().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    #[test]
    fn history_deduplicates_without_replay_and_reloads() {
        let path = std::env::temp_dir().join(format!("chau7-quota-{}.jsonl", uuid::Uuid::new_v4()));
        let now = Utc::now();
        let value = serde_json::json!({"rate_limits":{"five_hour":{"used_percent":25}}});
        let snapshot = QuotaSnapshot::parse_claude(&value, now, None).unwrap();
        let mut history = QuotaHistory::open(path.clone()).unwrap();
        assert!(history.append(snapshot.clone()).unwrap());
        let mut duplicate = snapshot.clone();
        duplicate.captured_at += Duration::seconds(30);
        assert!(!history.append(duplicate).unwrap());
        let mut changed = snapshot;
        changed.captured_at += Duration::seconds(60);
        changed.windows[0].used_percent = 30.;
        assert!(history.append(changed).unwrap());
        let restored = QuotaHistory::open(path.clone()).unwrap();
        assert_eq!(restored.snapshots.len(), 2);
        assert_eq!(restored.latest()[0].windows[0].used_percent, 30.);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn parse_usage_and_reset_scoped_warnings() {
        let now = Utc::now();
        let v = serde_json::json!({"plan_type":"max","rate_limits":{"five_hour":{"used_percentage":95,"resets_at":(now+Duration::hours(1)).timestamp()}}});
        let s = QuotaSnapshot::parse_claude(&v, now, None).unwrap();
        assert_eq!(s.windows[0].remaining(), 5.);
        assert_eq!(
            warnings(&s, std::slice::from_ref(&s), now)[0].kind,
            "remaining5"
        );
        assert!(warnings(&s, &[], now + Duration::minutes(55)).is_empty());
        assert!(QuotaSnapshot::parse_claude(&serde_json::json!({}), now, None).is_none());
    }
    #[test]
    fn pace_excludes_different_reset_window() {
        let now = Utc::now();
        let mut s=QuotaSnapshot::parse_claude(&serde_json::json!({"rate_limits":{"five_hour":{"used_percent":80,"resets_at":(now+Duration::hours(1)).timestamp()}}}),now,None).unwrap();
        let mut old = s.clone();
        old.captured_at -= Duration::minutes(10);
        old.windows[0].used_percent = 60.;
        assert_eq!(
            metrics(&s, &[old.clone(), s.clone()], now)[0].recent_burn_percent_per_minute,
            Some(2.)
        );
        old.windows[0].resets_at = Some(now - Duration::hours(1));
        assert!(
            metrics(&s, &[old, s.clone()], now)[0]
                .recent_burn_percent_per_minute
                .is_none()
        );
        s.windows[0].used_percent = 110.;
    }
}

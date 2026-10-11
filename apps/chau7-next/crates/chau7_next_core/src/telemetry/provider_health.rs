//! Official provider status decoders with freshness and retry semantics.
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Unknown,
    Operational,
    Degraded,
    Outage,
}
impl Severity {
    pub fn alerting(self) -> bool {
        matches!(self, Self::Degraded | Self::Outage)
    }
}
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthSnapshot {
    pub provider: String,
    pub severity: Severity,
    pub summary: String,
    pub source_url: String,
    pub checked_at: DateTime<Utc>,
}
impl HealthSnapshot {
    pub fn active_alert(&self, at: DateTime<Utc>) -> Option<Severity> {
        let age = at.signed_duration_since(self.checked_at).num_seconds();
        (self.severity.alerting() && (0..=300).contains(&age)).then_some(self.severity)
    }
}
pub fn status_page(
    value: &Value,
    provider: &str,
    fragments: &[&str],
    url: &str,
    at: DateTime<Utc>,
) -> Result<HealthSnapshot, String> {
    let components = value
        .get("components")
        .and_then(Value::as_array)
        .ok_or("Missing status components")?;
    let relevant: Vec<_> = components
        .iter()
        .filter(|v| {
            v.get("name").and_then(Value::as_str).is_some_and(|name| {
                fragments.iter().any(|fragment| {
                    name.to_ascii_lowercase()
                        .contains(&fragment.to_ascii_lowercase())
                })
            })
        })
        .collect();
    if relevant.is_empty() {
        return Err("No relevant status components".into());
    }
    let mut severity = Severity::Unknown;
    for c in &relevant {
        let status = c
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        severity = severity.max(match status.as_str() {
            "operational" => Severity::Operational,
            "degraded_performance" | "under_maintenance" | "maintenance" => Severity::Degraded,
            "partial_outage" | "major_outage" => Severity::Outage,
            _ => return Err(format!("Unsupported component status: {status}")),
        });
    }
    let summary = value
        .get("incidents")
        .and_then(Value::as_array)
        .and_then(|a| {
            a.iter().find(|incident| {
                incident.get("status").and_then(Value::as_str) != Some("resolved")
                    && incident
                        .get("components")
                        .and_then(Value::as_array)
                        .is_some_and(|affected| {
                            affected
                                .iter()
                                .any(|a| relevant.iter().any(|r| a.get("id") == r.get("id")))
                        })
            })
        })
        .and_then(|i| i.get("name"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| {
            match severity {
                Severity::Operational => "All systems operational",
                Severity::Degraded => "Degraded performance",
                Severity::Outage => "Service outage",
                Severity::Unknown => "Status unavailable",
            }
            .into()
        });
    Ok(HealthSnapshot {
        provider: provider.into(),
        severity,
        summary,
        source_url: url.into(),
        checked_at: at,
    })
}
pub fn google_cloud(value: &Value, url: &str, at: DateTime<Utc>) -> Result<HealthSnapshot, String> {
    let incidents = value.as_array().ok_or("Invalid Google incident feed")?;
    let active: Vec<_> = incidents
        .iter()
        .filter(|i| {
            i.get("end").is_none_or(Value::is_null)
                && (i
                    .get("affected_products")
                    .and_then(Value::as_array)
                    .is_some_and(|products| {
                        products.iter().any(|p| {
                            p.get("title").and_then(Value::as_str).is_some_and(|t| {
                                let t = t.to_lowercase();
                                t.contains("gemini") || t.contains("vertex ai")
                            })
                        })
                    })
                    || i.get("external_desc")
                        .and_then(Value::as_str)
                        .is_some_and(|s| s.to_lowercase().contains("gemini")))
        })
        .collect();
    let severity = active
        .iter()
        .map(|i| {
            let impact = i
                .get("status_impact")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_lowercase();
            let severity = i
                .get("severity")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_lowercase();
            if impact.contains("disruption") || matches!(severity.as_str(), "high" | "medium") {
                Severity::Outage
            } else {
                Severity::Degraded
            }
        })
        .max()
        .unwrap_or(Severity::Operational);
    let summary = active
        .first()
        .and_then(|i| i.get("external_desc"))
        .and_then(Value::as_str)
        .unwrap_or(if active.is_empty() {
            "All systems operational"
        } else {
            "Gemini service incident"
        });
    Ok(HealthSnapshot {
        provider: "google".into(),
        severity,
        summary: summary.into(),
        source_url: url.into(),
        checked_at: at,
    })
}
pub fn retry_delay(failures: u32) -> i64 {
    (60_i64 * 2_i64.pow(failures.saturating_sub(1).min(4))).min(900)
}
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    #[test]
    fn component_filtering_unknown_and_freshness() {
        let now = Utc::now();
        let value = serde_json::json!({"components":[{"id":"a","name":"Responses","status":"operational"},{"id":"b","name":"Images","status":"major_outage"}]});
        let s = status_page(&value, "openai", &["Responses"], "url", now).unwrap();
        assert_eq!(s.severity, Severity::Operational);
        assert!(s.active_alert(now).is_none());
        let value = serde_json::json!({"components":[{"id":"a","name":"Responses","status":"major_outage"}],"incidents":[{"name":"Current API incident","status":"investigating","components":[{"id":"a"}]}]});
        let s = status_page(&value, "openai", &["Responses"], "url", now).unwrap();
        assert_eq!(s.summary, "Current API incident");
        assert_eq!(
            s.active_alert(now + Duration::seconds(300)),
            Some(Severity::Outage)
        );
        assert!(s.active_alert(now + Duration::seconds(301)).is_none());
        assert!(s.active_alert(now - Duration::seconds(1)).is_none());
        assert!(status_page(&value, "openai", &["Missing"], "url", now).is_err());
    }
    #[test]
    fn active_google_incidents_and_backoff() {
        let now = Utc::now();
        let v = serde_json::json!([{"affected_products":[{"title":"Vertex AI"}],"severity":"medium","external_desc":"Gemini degraded"},{"affected_products":[{"title":"Gemini"}],"severity":"high","end":"2026-10-10T00:00:00Z"}]);
        assert_eq!(
            google_cloud(&v, "url", now).unwrap().severity,
            Severity::Outage
        );
        assert_eq!(
            [0, 1, 2, 3, 4, 5, 20].map(retry_delay),
            [60, 60, 120, 240, 480, 900, 900]
        );
    }
}

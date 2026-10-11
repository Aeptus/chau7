//! Isolated current AethymeDelivery.swift contract, using broker advanced.
use serde::Deserialize;
pub const ADAPTER: &str = "chau7-next";
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub tab_id: uuid::Uuid,
    pub ai_session_id: String,
}
impl Target {
    pub fn parse(value: &str) -> Option<Self> {
        let rest = value.strip_prefix("chau7-next://tab/")?;
        if rest.contains('#') {
            return None;
        }
        let (tab, query) = rest.split_once('?')?;
        let tab_id = uuid::Uuid::parse_str(tab).ok()?;
        let mut session = None;
        for item in query.split('&') {
            let (key, value) = item.split_once('=')?;
            if key == "session" {
                if session.is_some() {
                    return None;
                }
                let decoded = decode(value)?;
                if decoded.trim().is_empty() || decoded.chars().any(char::is_control) {
                    return None;
                }
                session = Some(decoded);
            }
        }
        Some(Self {
            tab_id,
            ai_session_id: session?,
        })
    }
    pub fn opaque_value(&self) -> String {
        let mut encoded = String::new();
        for byte in self.ai_session_id.bytes() {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                encoded.push(byte as char);
            } else {
                use std::fmt::Write;
                let _ = write!(encoded, "%{byte:02X}");
            }
        }
        format!("chau7-next://tab/{}?session={encoded}", self.tab_id)
    }
}
fn decode(value: &str) -> Option<String> {
    let mut bytes = Vec::new();
    let mut input = value.bytes();
    while let Some(byte) = input.next() {
        bytes.push(if byte == b'%' {
            (input.next()? as char).to_digit(16)? as u8 * 16
                + (input.next()? as char).to_digit(16)? as u8
        } else {
            byte
        });
    }
    String::from_utf8(bytes).ok()
}
#[derive(Debug, Clone)]
pub struct TabSnapshot {
    pub tab_id: uuid::Uuid,
    pub ai_session_id: Option<String>,
    pub ai_provider: Option<String>,
    pub repository_root: Option<String>,
    pub status: String,
    pub is_at_prompt: bool,
    pub has_pending_input: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    Retry(&'static str),
    Failed(&'static str),
}
impl Readiness {
    pub fn outcome(&self) -> &'static str {
        match self {
            Self::Ready => "delivered",
            Self::Retry(_) => "retry",
            Self::Failed(_) => "failed",
        }
    }
    pub fn error_code(&self) -> Option<&'static str> {
        match self {
            Self::Ready => None,
            Self::Retry(code) | Self::Failed(code) => Some(code),
        }
    }
}
/// Repository strings have already been canonicalized off the UI thread.
pub fn evaluate(target: &Target, tab: Option<&TabSnapshot>, repository_root: &str) -> Readiness {
    let Some(tab) = tab else {
        return Readiness::Retry("target_tab_missing");
    };
    if tab.tab_id != target.tab_id {
        return Readiness::Failed("target_tab_mismatch");
    }
    if tab.ai_session_id.as_deref() != Some(&target.ai_session_id) {
        return Readiness::Failed("target_session_mismatch");
    }
    if tab.repository_root.as_deref() != Some(repository_root) {
        return Readiness::Failed("target_repository_mismatch");
    }
    if tab
        .ai_provider
        .as_deref()
        .is_none_or(|provider| provider.trim().is_empty())
    {
        return Readiness::Retry("target_agent_unavailable");
    }
    if !matches!(tab.status.as_str(), "idle" | "done") {
        return Readiness::Retry("target_tab_busy");
    }
    if !tab.is_at_prompt {
        return Readiness::Retry("target_not_at_prompt");
    }
    if tab.has_pending_input {
        return Readiness::Retry("target_has_pending_input");
    }
    Readiness::Ready
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Policy {
    Notify,
    Resume,
    ReviewAndPush,
}
#[derive(Debug, Deserialize)]
pub struct Watch {
    pub id: i64,
    pub status: String,
    pub next_poll_at: Option<i64>,
}
#[derive(Debug, Deserialize)]
pub struct ClaimReport {
    pub adapter: String,
    pub worker: String,
    pub delivery: Option<Envelope>,
}
#[derive(Debug, Deserialize)]
pub struct Envelope {
    pub item: Item,
    pub subscription: Subscription,
    pub watch: DeliveryWatch,
    pub batch: Batch,
    pub prompt: String,
}
#[derive(Debug, Deserialize)]
pub struct Item {
    pub id: i64,
    pub generation: i64,
}
#[derive(Debug, Deserialize)]
pub struct Subscription {
    pub id: i64,
    pub target: String,
    pub policy: Policy,
}
#[derive(Debug, Deserialize)]
pub struct DeliveryWatch {
    pub id: i64,
    pub canonical_repository: String,
    pub pr_number: i64,
    pub head_sha: String,
}
#[derive(Debug, Deserialize)]
pub struct Batch {
    pub id: i64,
    pub head_sha: String,
}
impl ClaimReport {
    pub fn validated(self, worker: &str) -> Result<Option<Envelope>, &'static str> {
        if self.adapter != ADAPTER || self.worker != worker {
            return Err("claim_worker_mismatch");
        }
        if let Some(e) = &self.delivery
            && (e.item.id <= 0
                || e.item.generation < 0
                || e.subscription.id <= 0
                || e.watch.id <= 0
                || e.batch.id <= 0
                || e.watch.pr_number <= 0
                || e.watch.canonical_repository.is_empty()
                || e.prompt.trim().is_empty()
                || e.prompt.contains('\0'))
        {
            return Err("invalid_delivery_envelope");
        }
        Ok(self.delivery)
    }
}
fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).into()).collect()
}
pub fn list_watches() -> Vec<String> {
    args(&["broker", "advanced", "watch", "pr", "list", "--json"])
}
pub fn poll_watch(id: i64) -> Vec<String> {
    args(&[
        "broker",
        "advanced",
        "watch",
        "pr",
        "poll",
        "--id",
        &id.to_string(),
        "--json",
    ])
}
pub fn claim(worker: &str) -> Vec<String> {
    args(&[
        "broker",
        "advanced",
        "deliveries",
        "claim",
        "--adapter",
        ADAPTER,
        "--worker",
        worker,
        "--seconds",
        "120",
        "--json",
    ])
}
pub fn complete(item: &Item, worker: &str, readiness: &Readiness) -> Vec<String> {
    let mut result = args(&[
        "broker",
        "advanced",
        "deliveries",
        "complete",
        "--id",
        &item.id.to_string(),
        "--worker",
        worker,
        "--generation",
        &item.generation.to_string(),
        "--outcome",
        readiness.outcome(),
    ]);
    if let Some(code) = readiness.error_code() {
        result.extend(args(&["--error-code", code]));
    }
    result.push("--json".into());
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    fn target() -> Target {
        Target {
            tab_id: uuid::Uuid::new_v4(),
            ai_session_id: "native/é +?&".into(),
        }
    }
    fn tab(t: &Target) -> TabSnapshot {
        TabSnapshot {
            tab_id: t.tab_id,
            ai_session_id: Some(t.ai_session_id.clone()),
            ai_provider: Some("codex".into()),
            repository_root: Some("/repo".into()),
            status: "done".into(),
            is_at_prompt: true,
            has_pending_input: false,
        }
    }
    #[test]
    fn own_target_round_trip_and_swift_is_rejected() {
        let t = target();
        assert_eq!(Target::parse(&t.opaque_value()), Some(t.clone()));
        for v in [
            t.opaque_value().replacen("chau7-next:", "chau7:", 1),
            format!("{}&session=other", t.opaque_value()),
            format!("chau7-next://tab/{}?session=%0A", t.tab_id),
            format!("chau7-next://tab/{}?session=%GG", t.tab_id),
        ] {
            assert!(Target::parse(&v).is_none());
        }
    }
    #[test]
    fn exact_recipient_and_readiness_are_required() {
        let t = target();
        let mut s = tab(&t);
        assert_eq!(
            evaluate(&t, None, "/repo"),
            Readiness::Retry("target_tab_missing")
        );
        assert_eq!(evaluate(&t, Some(&s), "/repo"), Readiness::Ready);
        s.has_pending_input = true;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_has_pending_input")
        );
        s.has_pending_input = false;
        s.is_at_prompt = false;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_not_at_prompt")
        );
        s.is_at_prompt = true;
        s.status = "approval_required".into();
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_tab_busy")
        );
        s.status = "idle".into();
        s.ai_provider = None;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_agent_unavailable")
        );
        s.ai_provider = Some("claude".into());
        assert_eq!(
            evaluate(&t, Some(&s), "/other"),
            Readiness::Failed("target_repository_mismatch")
        );
        s.ai_session_id = Some("other".into());
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Failed("target_session_mismatch")
        );
        s.tab_id = uuid::Uuid::new_v4();
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Failed("target_tab_mismatch")
        );
    }
    #[test]
    fn completion_preserves_fencing_and_exact_argv() {
        assert_eq!(
            complete(
                &Item {
                    id: 7,
                    generation: 11
                },
                "chau7-next-42",
                &Readiness::Retry("target_tab_busy")
            ),
            args(&[
                "broker",
                "advanced",
                "deliveries",
                "complete",
                "--id",
                "7",
                "--worker",
                "chau7-next-42",
                "--generation",
                "11",
                "--outcome",
                "retry",
                "--error-code",
                "target_tab_busy",
                "--json"
            ])
        );
        assert!(
            claim("worker")
                .windows(2)
                .any(|args| args == ["--adapter", "chau7-next"])
        );
        assert!(list_watches().starts_with(&args(&["broker", "advanced", "watch"])));
    }
    #[test]
    fn incomplete_and_wrong_owner_claims_are_not_accepted() {
        assert!(
            serde_json::from_str::<ClaimReport>(
                r#"{"adapter":"chau7-next","worker":"worker","delivery":{} }"#
            )
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: "chau7".into(),
                worker: "worker".into(),
                delivery: None
            }
            .validated("worker")
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: ADAPTER.into(),
                worker: "other".into(),
                delivery: None
            }
            .validated("worker")
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: ADAPTER.into(),
                worker: "worker".into(),
                delivery: None
            }
            .validated("worker")
            .unwrap()
            .is_none()
        );
    }
}

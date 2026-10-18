//! Live generation speed with explicit source and confidence.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};

// Aging changes the label, never whether a measured rate is displayed.
pub const TOKEN_RATE_FRESHNESS_SECONDS: i64 = 60;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TokenRateSource {
    ProxyStreamEstimate,
    ProxyUsage,
    ProxyRequestUsage,
    ProxyEstimatedUsage,
    ClaudeTranscript,
    CodexTranscript,
}
impl TokenRateSource {
    pub fn estimated(self) -> bool {
        self != Self::ProxyUsage
    }
    pub fn transcript(self) -> bool {
        matches!(self, Self::ClaudeTranscript | Self::CodexTranscript)
    }
    pub fn description(self) -> &'static str {
        match self {
            Self::ProxyStreamEstimate => "Live estimate from streamed API text deltas.",
            Self::ProxyUsage => {
                "Provider output tokens divided by generation time after first response."
            }
            Self::ProxyRequestUsage => {
                "Provider output tokens divided by request duration, including setup and prefill."
            }
            Self::ProxyEstimatedUsage => "Estimated output tokens divided by generation time.",
            Self::ClaudeTranscript | Self::CodexTranscript => {
                "Transcript usage and request timing; may include reasoning or unobserved tool delays."
            }
        }
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenRateReading {
    pub provider: String,
    pub tokens_per_second: f64,
    pub output_tokens: i64,
    pub duration_ms: i64,
    pub source: TokenRateSource,
    pub updated_at: DateTime<Utc>,
}
impl TokenRateReading {
    fn age_seconds_at(&self, now: &DateTime<Utc>) -> i64 {
        now.signed_duration_since(self.updated_at).num_seconds()
    }
    pub fn is_fresh_at(&self, now: &DateTime<Utc>) -> bool {
        (0..=TOKEN_RATE_FRESHNESS_SECONDS).contains(&self.age_seconds_at(now))
    }
    pub fn is_stale_at(&self, now: &DateTime<Utc>) -> bool {
        self.age_seconds_at(now) > TOKEN_RATE_FRESHNESS_SECONDS
    }
    /// A running CLI alone does not make a previous turn's reading current.
    pub fn is_current_for(
        &self,
        status: crate::shell_session::CommandStatus,
        turn_started_at: Option<f64>,
        now: &DateTime<Utc>,
    ) -> bool {
        status == crate::shell_session::CommandStatus::Running
            && self.is_fresh_at(now)
            && turn_started_at.is_some_and(|at| {
                at.is_finite() && self.updated_at.timestamp_millis() as f64 / 1000. >= at
            })
    }
    pub fn formatted(&self) -> String {
        format!(
            "{}{:.0} t/s",
            if self.source.estimated() { "~" } else { "" },
            self.tokens_per_second
        )
    }
    pub fn detail(&self) -> String {
        format!(
            "{}: {} output tokens in {:.1}s. {}",
            self.provider,
            self.output_tokens,
            self.duration_ms as f64 / 1000.,
            self.source.description()
        )
    }
}
#[derive(Default)]
pub struct TokenRateStore {
    readings: HashMap<String, TokenRateReading>,
    owners: HashMap<String, String>,
}
impl TokenRateStore {
    /// Fence asynchronous transcript reads to the exact telemetry run/native session.
    pub fn bind(&mut self, tab: &str, owner: &str) {
        if self.owners.get(tab).is_none_or(|old| old != owner) {
            self.readings.remove(tab);
            self.owners.insert(tab.to_owned(), owner.to_owned());
        }
    }
    pub fn record_owned(&mut self, tab: &str, owner: &str, reading: TokenRateReading) -> bool {
        if self.owners.get(tab).is_none_or(|current| current != owner) {
            return false;
        }
        self.record_rate(
            tab,
            &reading.provider,
            reading.tokens_per_second,
            reading.output_tokens,
            reading.duration_ms,
            reading.source,
            reading.updated_at,
        )
    }
    /// Stop asynchronous writes while retaining the last measurement for display.
    pub fn unbind(&mut self, tab: &str) {
        self.owners.remove(tab);
    }
    pub fn reading(&self, tab: &str) -> Option<&TokenRateReading> {
        self.readings.get(tab)
    }
    pub fn snapshot(&self) -> HashMap<String, TokenRateReading> {
        self.readings.clone()
    }
    pub fn remove(&mut self, tab: &str) {
        self.readings.remove(tab);
        self.owners.remove(tab);
    }
    pub fn record(
        &mut self,
        tab: &str,
        provider: &str,
        output: i64,
        duration: i64,
        source: TokenRateSource,
        at: DateTime<Utc>,
    ) -> bool {
        self.record_rate(
            tab,
            provider,
            output as f64 * 1000. / duration as f64,
            output,
            duration,
            source,
            at,
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub fn record_rate(
        &mut self,
        tab: &str,
        provider: &str,
        rate: f64,
        output: i64,
        duration: i64,
        source: TokenRateSource,
        at: DateTime<Utc>,
    ) -> bool {
        if tab.trim().is_empty()
            || tab == "default"
            || output <= 0
            || duration <= 0
            || !rate.is_finite()
            || rate <= 0.
        {
            return false;
        }
        if let Some(old) = self.readings.get(tab)
            && (at < old.updated_at
                || (source.transcript()
                    && matches!(
                        old.source,
                        TokenRateSource::ProxyUsage | TokenRateSource::ProxyRequestUsage
                    )
                    && at.signed_duration_since(old.updated_at).num_milliseconds() < 5000))
        {
            return false;
        }
        self.readings.insert(
            tab.to_owned(),
            TokenRateReading {
                provider: provider.to_owned(),
                tokens_per_second: rate,
                output_tokens: output,
                duration_ms: duration,
                source,
                updated_at: at,
            },
        );
        if self.readings.len() > 512 {
            let mut keep: Vec<_> = self
                .readings
                .iter()
                .map(|(k, v)| (k.clone(), v.updated_at))
                .collect();
            keep.sort_by_key(|(_, t)| std::cmp::Reverse(*t));
            let keys: HashSet<_> = keep.into_iter().take(384).map(|(k, _)| k).collect();
            self.readings.retain(|k, _| keys.contains(k));
        }
        true
    }
}
#[derive(Default)]
pub struct TranscriptRateState {
    last_user: Option<DateTime<Utc>>,
    last_assistant: Option<DateTime<Utc>>,
    turn_started: Option<DateTime<Utc>>,
    last_codex: Option<DateTime<Utc>>,
    codex_total_output: Option<i64>,
    codex_turn_closed: bool,
    seen: HashSet<String>,
    order: VecDeque<String>,
    pub model: Option<String>,
}
impl TranscriptRateState {
    fn remember(&mut self, key: String) -> bool {
        if !self.seen.insert(key.clone()) {
            return false;
        }
        self.order.push_back(key);
        if self.order.len() > 512
            && let Some(k) = self.order.pop_front()
        {
            self.seen.remove(&k);
        }
        true
    }
    pub fn consume(&mut self, provider: &str, line: &str) -> Option<TokenRateReading> {
        let v: Value = serde_json::from_str(line).ok()?;
        let at = DateTime::parse_from_rfc3339(v.get("timestamp")?.as_str()?)
            .ok()?
            .with_timezone(&Utc);
        let (output, start, source) = if matches!(provider, "claude" | "anthropic") {
            let m = v.get("message")?;
            match v.get("type")?.as_str()? {
                "user" => {
                    let tool = m.get("content").and_then(Value::as_array).is_some_and(|a| {
                        a.iter()
                            .any(|x| x.get("type").and_then(Value::as_str) == Some("tool_result"))
                    });
                    if tool {
                        self.last_assistant = Some(at);
                    } else {
                        self.last_user = Some(at);
                        self.last_assistant = None;
                    }
                    return None;
                }
                "assistant" => {}
                _ => return None,
            }
            if let Some(model) = m.get("model").and_then(Value::as_str) {
                self.model = Some(model.to_owned());
            }
            let output = m
                .pointer("/usage/output_tokens")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let key = v
                .as_object()
                .zip(m.as_object())
                .and_then(|(o, m)| super::claude_transcript::request_usage_key(o, m))
                .unwrap_or_else(|| format!("{at}|{output}"));
            if output <= 0 || !self.remember(key) {
                return None;
            }
            let start = self.last_assistant.or(self.last_user);
            self.last_assistant = Some(at);
            (output, start, TokenRateSource::ClaudeTranscript)
        } else if matches!(provider, "codex" | "openai") {
            let payload = v.get("payload")?;
            if v.get("type").and_then(Value::as_str) == Some("turn_context") {
                self.turn_started = Some(at);
                self.last_codex = None;
                self.codex_turn_closed = false;
                self.model = payload
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                return None;
            }
            let kind = payload.get("type").and_then(Value::as_str);
            if !self.codex_turn_closed
                && v.get("type").and_then(Value::as_str) == Some("response_item")
                && matches!(
                    kind,
                    Some("function_call_output" | "custom_tool_call_output")
                )
            {
                // The next request begins after the tool returns, not before
                // its potentially long execution or approval wait.
                self.turn_started = Some(at);
                self.last_codex = None;
                return None;
            }
            if v.get("type").and_then(Value::as_str) == Some("event_msg") {
                match kind {
                    Some("task_started") => {
                        self.codex_turn_closed = false;
                        self.turn_started = Some(at);
                        self.last_codex = None;
                        return None;
                    }
                    Some("task_complete" | "turn_aborted") => {
                        self.codex_turn_closed = true;
                        self.turn_started = None;
                        self.last_codex = None;
                        return None;
                    }
                    _ => {}
                }
            }
            if self.codex_turn_closed
                || v.get("type").and_then(Value::as_str) != Some("event_msg")
                || payload.get("type").and_then(Value::as_str) != Some("token_count")
            {
                return None;
            }
            let output = payload
                .pointer("/info/last_token_usage/output_tokens")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let total = payload
                .pointer("/info/total_token_usage/output_tokens")
                .and_then(Value::as_i64);
            // Codex repeats token_count for context/rate-limit refreshes. A
            // different timestamp does not establish newly generated tokens.
            if let Some(total) = total {
                if self.codex_total_output.is_some_and(|old| total <= old) {
                    return None;
                }
                self.codex_total_output = Some(total);
            }
            if output <= 0 || !self.remember(format!("{at}|{output}")) {
                return None;
            }
            let start = self.last_codex.or(self.turn_started);
            self.last_codex = Some(at);
            (output, start, TokenRateSource::CodexTranscript)
        } else {
            return None;
        };
        let duration = at.signed_duration_since(start?).num_milliseconds();
        if !(250..=3_600_000).contains(&duration) {
            return None;
        }
        Some(TokenRateReading {
            provider: provider.to_owned(),
            tokens_per_second: output as f64 * 1000. / duration as f64,
            output_tokens: output,
            duration_ms: duration,
            source,
            updated_at: at,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    #[test]
    fn freshness_uses_the_shared_measurement_aging_window() {
        let measured_at = Utc::now();
        let reading = TokenRateReading {
            provider: "claude".into(),
            tokens_per_second: 20.0,
            output_tokens: 20,
            duration_ms: 1000,
            source: TokenRateSource::ProxyUsage,
            updated_at: measured_at,
        };

        assert!(reading.is_fresh_at(&measured_at));
        assert!(!reading.is_stale_at(&measured_at));
        let before_measurement = measured_at - Duration::seconds(1);
        assert!(!reading.is_fresh_at(&before_measurement));
        // Preserve the existing distinction between future and old readings.
        assert!(!reading.is_stale_at(&before_measurement));

        let fresh_at = measured_at + Duration::seconds(TOKEN_RATE_FRESHNESS_SECONDS);
        assert!(reading.is_fresh_at(&fresh_at));
        assert!(!reading.is_stale_at(&fresh_at));

        // Existing UI checks use whole seconds, so the boundary is inclusive.
        let within_last_second = fresh_at + Duration::milliseconds(999);
        assert!(reading.is_fresh_at(&within_last_second));
        assert!(!reading.is_stale_at(&within_last_second));

        let stale_at = measured_at + Duration::seconds(TOKEN_RATE_FRESHNESS_SECONDS + 1);
        assert!(!reading.is_fresh_at(&stale_at));
        assert!(reading.is_stale_at(&stale_at));
    }

    #[test]
    fn source_priority_and_invalid_values() {
        let mut s = TokenRateStore::default();
        let t = Utc::now();
        assert!(!s.record(
            "default",
            "claude",
            20,
            1000,
            TokenRateSource::ProxyUsage,
            t
        ));
        assert!(!s.record("a", "claude", 20, 0, TokenRateSource::ProxyUsage, t));
        assert!(s.record("a", "claude", 20, 1000, TokenRateSource::ProxyUsage, t));
        assert_eq!(s.reading("a").unwrap().formatted(), "20 t/s");
        assert!(!s.record(
            "a",
            "claude",
            30,
            1000,
            TokenRateSource::ClaudeTranscript,
            t + Duration::seconds(2)
        ));
        assert!(s.record(
            "a",
            "claude",
            30,
            1000,
            TokenRateSource::ClaudeTranscript,
            t + Duration::seconds(6)
        ));
        assert_eq!(s.reading("a").unwrap().formatted(), "~30 t/s");
        assert!(!s.record("a", "claude", 30, 1000, TokenRateSource::ProxyUsage, t));
    }
    fn codex_line(seconds: i64, kind: &str, extra: serde_json::Value) -> String {
        let mut payload = extra.as_object().cloned().unwrap_or_default();
        payload.insert("type".into(), kind.into());
        serde_json::json!({"timestamp":(DateTime::from_timestamp(1_760_184_000, 0).unwrap() + Duration::seconds(seconds)).to_rfc3339(),
            "type":"event_msg", "payload":payload})
        .to_string()
    }

    #[test]
    fn lifecycle_changes_label_without_discarding_old_readings() {
        use crate::shell_session::CommandStatus;
        let t = Utc::now();
        let mut store = TokenRateStore::default();
        store.bind("tab", "run:session");
        store.record(
            "tab",
            "codex",
            100,
            2000,
            TokenRateSource::CodexTranscript,
            t,
        );
        let r = store.reading("tab").unwrap();
        let started_at = t.timestamp_millis() as f64 / 1000. - 1.;
        let started = Some(started_at);
        assert!(r.is_current_for(
            CommandStatus::Running,
            started,
            &(t + Duration::seconds(30))
        ));
        for status in [
            CommandStatus::Done,
            CommandStatus::ApprovalRequired,
            CommandStatus::WaitingForInput,
            CommandStatus::Idle,
            CommandStatus::Exited,
        ] {
            assert!(!r.is_current_for(status, started, &t));
        }
        assert!(!r.is_current_for(CommandStatus::Running, Some(started_at + 2.), &t));
        assert!(!r.is_current_for(CommandStatus::Running, None, &t));
        assert!(!r.is_current_for(
            CommandStatus::Running,
            started,
            &(t + Duration::minutes(10))
        ));
        assert!(store.reading("tab").is_some());
    }

    #[test]
    fn session_rebinding_fences_late_readings_without_touching_other_tabs() {
        let mut s = TokenRateStore::default();
        let t = Utc::now();
        let reading = TokenRateReading {
            provider: "codex".into(),
            tokens_per_second: 20.,
            output_tokens: 20,
            duration_ms: 1000,
            source: TokenRateSource::CodexTranscript,
            updated_at: t,
        };
        s.bind("a", "run-1:session-1");
        s.bind("b", "run-2:session-2");
        assert!(s.record_owned("a", "run-1:session-1", reading.clone()));
        assert!(s.record_owned("b", "run-2:session-2", reading.clone()));
        s.bind("a", "run-3:session-3");
        assert!(s.reading("a").is_none());
        assert!(!s.record_owned("a", "run-1:session-1", reading.clone()));
        assert!(s.reading("b").is_some());
        assert!(s.record_owned("a", "run-3:session-3", reading.clone()));
        s.unbind("a");
        assert!(s.reading("a").is_some());
        assert!(!s.record_owned("a", "run-3:session-3", reading));
    }

    #[test]
    fn codex_repeated_usage_does_not_create_speed_and_tool_time_is_excluded() {
        let mut s = TranscriptRateState::default();
        s.consume(
            "codex",
            &codex_line(0, "task_started", serde_json::json!({})),
        );
        let usage = |total| {
            serde_json::json!({"info":{"last_token_usage":{"output_tokens":20},
            "total_token_usage":{"output_tokens":total}}})
        };
        let first = s
            .consume("codex", &codex_line(1, "token_count", usage(20)))
            .unwrap();
        assert!(first.tokens_per_second > 19. && first.tokens_per_second < 21.);
        assert!(
            s.consume("codex", &codex_line(5, "token_count", usage(20)))
                .is_none()
        );
        let tool_result = serde_json::json!({"type":"response_item", "timestamp":
            (DateTime::from_timestamp(1_760_184_000, 0).unwrap()+Duration::seconds(301)).to_rfc3339(),
            "payload":{"type":"function_call_output", "call_id":"tool"}})
        .to_string();
        s.consume("codex", &tool_result);
        let after_tool = s
            .consume("codex", &codex_line(302, "token_count", usage(40)))
            .unwrap();
        assert!(after_tool.duration_ms >= 999 && after_tool.duration_ms <= 1001);
        assert!(after_tool.tokens_per_second > 19. && after_tool.tokens_per_second < 21.);
        s.consume(
            "codex",
            &codex_line(303, "task_complete", serde_json::json!({})),
        );
        s.consume("codex", &tool_result);
        assert!(
            s.consume("codex", &codex_line(304, "token_count", usage(60)))
                .is_none()
        );
        s.consume(
            "codex",
            &codex_line(305, "task_started", serde_json::json!({})),
        );
        let next = s
            .consume("codex", &codex_line(306, "token_count", usage(80)))
            .unwrap();
        assert!(next.tokens_per_second > 19. && next.tokens_per_second < 21.);
    }

    #[test]
    fn long_provider_turn_still_produces_an_estimated_rate() {
        let mut s = TranscriptRateState::default();
        s.consume(
            "codex",
            &codex_line(0, "task_started", serde_json::json!({})),
        );
        let reading = s
            .consume(
                "codex",
                &codex_line(
                    600,
                    "token_count",
                    serde_json::json!({
                        "info":{"last_token_usage":{"output_tokens":600},
                                "total_token_usage":{"output_tokens":600}}
                    }),
                ),
            )
            .unwrap();
        assert_eq!(reading.duration_ms, 600_000);
        assert_eq!(reading.tokens_per_second, 1.);
        assert!(reading.source.estimated());
    }

    #[test]
    fn transcript_timing_dedup_and_bounds() {
        let mut s = TranscriptRateState::default();
        assert!(s.consume("claude",r#"{"timestamp":"2026-10-11T12:00:00Z","type":"user","message":{"content":"hello"}}"#).is_none());
        let line = r#"{"timestamp":"2026-10-11T12:00:01Z","type":"assistant","requestId":"r","message":{"id":"m","model":"claude-sonnet-4","usage":{"output_tokens":20}}}"#;
        let r = s.consume("claude", line).unwrap();
        assert_eq!(r.tokens_per_second, 20.);
        assert!(r.source.estimated());
        assert!(s.consume("claude", line).is_none());
    }
}

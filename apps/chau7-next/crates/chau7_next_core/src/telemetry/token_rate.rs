//! Live generation speed with explicit source and confidence.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
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
                "Transcript usage and timestamps; includes response and tool delays."
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
}
impl TokenRateStore {
    pub fn reading(&self, tab: &str) -> Option<&TokenRateReading> {
        self.readings.get(tab)
    }
    pub fn snapshot(&self) -> HashMap<String, TokenRateReading> {
        self.readings.clone()
    }
    pub fn remove(&mut self, tab: &str) {
        self.readings.remove(tab);
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
                self.model = payload
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                return None;
            }
            if v.get("type").and_then(Value::as_str) != Some("event_msg")
                || payload.get("type").and_then(Value::as_str) != Some("token_count")
            {
                return None;
            }
            let output = payload
                .pointer("/info/last_token_usage/output_tokens")
                .and_then(Value::as_i64)
                .unwrap_or(0);
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
        if !(250..=300_000).contains(&duration) {
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

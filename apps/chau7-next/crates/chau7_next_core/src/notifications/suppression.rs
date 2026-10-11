//! The single deterministic delivery suppression and routing-retry owner.
//! Current Swift windows, with explicit reopen cleanup and provider-scoped
//! close identities so unrelated providers cannot mute one another.
use super::{delivery, observation};
use crate::ai::event::{AiEvent, AiEventReliability};
use chrono::{DateTime, Utc};
use std::{collections::HashMap, time::Duration};
use uuid::Uuid;

pub const REPEATED_ATTENTION_RETENTION: chrono::Duration = chrono::Duration::seconds(90);
pub const CLOSED_SESSION_RETENTION: chrono::Duration = chrono::Duration::seconds(180);
pub const RETRY_DELAYS: [Duration; 3] = [
    Duration::from_millis(50),
    Duration::from_millis(150),
    Duration::from_millis(500),
];
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Pass,
    Drop { reason: String },
    Retry { delay: Duration, attempt: usize },
}
#[derive(Debug, Default)]
pub struct SuppressionCenter {
    authoritative: HashMap<String, DateTime<Utc>>,
    repeated: HashMap<String, DateTime<Utc>>,
    closed: HashMap<String, DateTime<Utc>>,
    retry: HashMap<Uuid, (usize, DateTime<Utc>)>,
}
fn family(event: &AiEvent) -> bool {
    matches!(
        event.normalized_type().as_str(),
        "permission" | "waiting_input" | "attention_required" | "idle" | "elicitation"
    )
}
fn repeat_key(event: &AiEvent) -> Option<String> {
    family(event).then(|| {
        format!(
            "interactive_attention|{}",
            observation::aliases(event).first().unwrap().key()
        )
    })
}
fn close_keys(event: &AiEvent) -> Vec<String> {
    observation::aliases(event)
        .iter()
        .map(observation::Alias::key)
        .collect()
}
// Prefer the strongest identity present at evaluation. Directory overlap
// cannot let a finished sibling session shadow a distinct precise session.
fn exact_close_keys(event: &AiEvent) -> Vec<String> {
    observation::aliases(event)
        .first()
        .map(|alias| vec![alias.key()])
        .unwrap_or_default()
}
fn authority_keys(event: &AiEvent) -> Vec<String> {
    if !delivery::AUTHORITATIVE_ROUTING_TYPES.contains(&event.normalized_type().as_str()) {
        return Vec::new();
    }
    observation::aliases(event)
        .iter()
        .map(|alias| format!("{}|{}", event.normalized_type(), alias.key()))
        .collect()
}
fn exact_authority_keys(event: &AiEvent) -> Vec<String> {
    authority_keys(event).into_iter().take(1).collect()
}
fn recent(
    map: &HashMap<String, DateTime<Utc>>,
    keys: impl IntoIterator<Item = String>,
    now: DateTime<Utc>,
    retention: chrono::Duration,
) -> bool {
    keys.into_iter()
        .any(|key| map.get(&key).is_some_and(|seen| now - *seen <= retention))
}
impl SuppressionCenter {
    pub fn reset(&mut self) {
        *self = Self::default();
    }
    pub fn prune(&mut self, now: DateTime<Utc>) {
        self.authoritative
            .retain(|_, seen| now - *seen <= chrono::Duration::seconds(180));
        self.repeated
            .retain(|_, seen| now - *seen <= REPEATED_ATTENTION_RETENTION);
        self.closed
            .retain(|_, seen| now - *seen <= CLOSED_SESSION_RETENTION);
        self.retry
            .retain(|_, (_, seen)| now - *seen <= CLOSED_SESSION_RETENTION);
    }
    pub fn forget_retry(&mut self, id: Uuid) {
        self.retry.remove(&id);
    }
    pub fn routing(&mut self, event: &AiEvent, now: DateTime<Utc>) -> Verdict {
        if !delivery::requires_authoritative_routing(event) {
            return Verdict::Pass;
        }
        let attempts = self.retry.get(&event.id).map(|v| v.0).unwrap_or(0);
        let has_identity = event
            .session_id
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
            || event
                .directory
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty());
        if attempts < RETRY_DELAYS.len() && has_identity {
            if !self.retry.contains_key(&event.id)
                && self.retry.len() >= 100
                && let Some(oldest) = self
                    .retry
                    .iter()
                    .min_by_key(|(id, (_, seen))| (*seen, **id))
                    .map(|(id, _)| *id)
            {
                self.retry.remove(&oldest);
            }
            let attempt = attempts + 1;
            self.retry.insert(event.id, (attempt, now));
            return Verdict::Retry {
                delay: RETRY_DELAYS[attempts],
                attempt,
            };
        }
        self.forget_retry(event.id);
        Verdict::Drop {
            reason: delivery::unresolved_routing_drop_reason(event, attempts, RETRY_DELAYS.len()),
        }
    }
    pub fn post_close(&mut self, event: &AiEvent, now: DateTime<Utc>) -> Verdict {
        if family(event)
            && recent(
                &self.closed,
                exact_close_keys(event),
                now,
                CLOSED_SESSION_RETENTION,
            )
        {
            self.forget_retry(event.id);
            return Verdict::Drop {
                reason: "Suppressed stale post-close notification for an already-finished session"
                    .into(),
            };
        }
        Verdict::Pass
    }
    pub fn fallback_shadow(&self, event: &AiEvent, now: DateTime<Utc>) -> Verdict {
        if event.reliability != AiEventReliability::Authoritative
            && recent(
                &self.authoritative,
                exact_authority_keys(event),
                now,
                chrono::Duration::seconds(180),
            )
        {
            return Verdict::Drop {
                reason: "Suppressed fallback event shadowed by authoritative delivery".into(),
            };
        }
        Verdict::Pass
    }
    pub fn repeat(&mut self, event: &AiEvent, now: DateTime<Utc>) -> Verdict {
        if repeat_key(event)
            .is_some_and(|key| recent(&self.repeated, [key], now, REPEATED_ATTENTION_RETENTION))
        {
            self.forget_retry(event.id);
            return Verdict::Drop{reason:"Suppressed repeated interactive-attention notification for unchanged session state".into()};
        }
        Verdict::Pass
    }
    pub fn register_closed(&mut self, event: &AiEvent, now: DateTime<Utc>) {
        if matches!(event.normalized_type().as_str(), "finished" | "failed") {
            for key in close_keys(event) {
                self.closed.insert(key, now);
            }
        }
    }
    pub fn register_authoritative(&mut self, event: &AiEvent, now: DateTime<Utc>) {
        if event.reliability == AiEventReliability::Authoritative {
            for key in authority_keys(event) {
                self.authoritative.insert(key, now);
            }
            self.forget_retry(event.id);
        }
    }
    pub fn register_repeat(&mut self, event: &AiEvent, now: DateTime<Utc>) {
        if let Some(key) = repeat_key(event) {
            self.repeated.insert(key, now);
        }
    }
    /// Only a reconciled real transition/lifecycle reopens a session. A lagging
    /// heuristic never reaches this method via the app notification engine.
    pub fn reopen(&mut self, event: &AiEvent) {
        for key in close_keys(event) {
            self.closed.remove(&key);
        }
        let mut identity = event.clone();
        identity.event_type = "waiting_input".into();
        if let Some(key) = repeat_key(&identity) {
            self.repeated.remove(&key);
        }
        for kind in delivery::AUTHORITATIVE_ROUTING_TYPES {
            identity.event_type = kind.into();
            for key in authority_keys(&identity) {
                self.authoritative.remove(&key);
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;
    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000, 0).unwrap()
    }
    fn event(kind: &str) -> AiEvent {
        let mut e = AiEvent::new(AiEventSource::codex(), kind, "Codex", "", "raw ts");
        e.reliability = AiEventReliability::Authoritative;
        e.session_id = Some("session".into());
        e.tab_id = Some(Uuid::nil());
        e
    }
    #[test]
    fn routing_missing_identity_retries_and_exhaustion() {
        let mut s = SuppressionCenter::default();
        let mut e = event("permission");
        e.tab_id = None;
        for (index, delay) in RETRY_DELAYS.iter().enumerate() {
            assert_eq!(
                s.routing(&e, now()),
                Verdict::Retry {
                    delay: *delay,
                    attempt: index + 1
                }
            );
        }
        assert!(matches!(s.routing(&e, now()), Verdict::Drop { .. }));
        assert!(s.retry.is_empty());
        e.session_id = None;
        assert!(matches!(s.routing(&e, now()), Verdict::Drop { .. }));
        e.tab_id = Some(Uuid::nil());
        assert_eq!(s.routing(&e, now()), Verdict::Pass);
    }
    #[test]
    fn retry_dictionary_is_bounded_even_for_live_unresolved_events() {
        let mut s = SuppressionCenter::default();
        for _ in 0..150 {
            let mut e = event("finished");
            e.tab_id = None;
            s.routing(&e, now());
        }
        assert_eq!(s.retry.len(), 100);
        s.prune(now() + chrono::Duration::seconds(181));
        assert!(s.retry.is_empty());
    }
    #[test]
    fn independent_windows_and_inclusive_boundaries() {
        let mut s = SuppressionCenter::default();
        let mut e = event("waiting_input");
        s.register_authoritative(&e, now());
        s.register_repeat(&e, now());
        e.reliability = AiEventReliability::Fallback;
        assert!(matches!(
            s.fallback_shadow(&e, now() + chrono::Duration::seconds(180)),
            Verdict::Drop { .. }
        ));
        assert_eq!(
            s.fallback_shadow(&e, now() + chrono::Duration::seconds(181)),
            Verdict::Pass
        );
        assert!(matches!(
            s.repeat(&e, now() + chrono::Duration::seconds(90)),
            Verdict::Drop { .. }
        ));
        assert_eq!(
            s.repeat(&e, now() + chrono::Duration::seconds(91)),
            Verdict::Pass
        );
    }
    #[test]
    fn close_drops_lagging_attention_reopen_clears_every_cycle_gate() {
        let mut s = SuppressionCenter::default();
        let finished = event("finished");
        s.register_closed(&finished, now());
        s.register_authoritative(&finished, now());
        let waiting = event("waiting_input");
        s.register_repeat(&waiting, now());
        assert!(matches!(
            s.post_close(&waiting, now()),
            Verdict::Drop { .. }
        ));
        let mut other = waiting.clone();
        other.source = AiEventSource::claude_code();
        other.tool = "Claude".into();
        assert_eq!(s.post_close(&other, now()), Verdict::Pass);
        s.reopen(&waiting);
        assert_eq!(s.post_close(&waiting, now()), Verdict::Pass);
        assert_eq!(s.repeat(&waiting, now()), Verdict::Pass);
        let mut fallback = finished.clone();
        fallback.reliability = AiEventReliability::Fallback;
        assert_eq!(s.fallback_shadow(&fallback, now()), Verdict::Pass);
    }
    #[test]
    fn precise_same_directory_sibling_session_is_not_shadowed_or_closed() {
        let mut s = SuppressionCenter::default();
        let mut done = event("finished");
        done.directory = Some("/shared/repo".into());
        s.register_closed(&done, now());
        s.register_authoritative(&done, now());
        let mut sibling = done.clone();
        sibling.session_id = Some("different-session".into());
        sibling.tab_id = Some(Uuid::new_v4());
        sibling.event_type = "waiting_input".into();
        assert_eq!(s.post_close(&sibling, now()), Verdict::Pass);
        sibling.event_type = "finished".into();
        sibling.reliability = AiEventReliability::Fallback;
        assert_eq!(s.fallback_shadow(&sibling, now()), Verdict::Pass);
        let mut tab_fallback = done.clone();
        tab_fallback.session_id = None;
        tab_fallback.event_type = "waiting_input".into();
        assert!(matches!(
            s.post_close(&tab_fallback, now()),
            Verdict::Drop { .. }
        ));
    }

    #[test]
    fn deterministic_replay_and_expiry_reset() {
        let replay = || {
            let mut s = SuppressionCenter::default();
            let e = event("permission");
            s.register_repeat(&e, now());
            let first = s.repeat(&e, now());
            s.prune(now() + chrono::Duration::seconds(181));
            let second = s.repeat(&e, now() + chrono::Duration::seconds(181));
            s.reset();
            (first, second, s.retry.len())
        };
        assert_eq!(replay(), replay());
    }
}

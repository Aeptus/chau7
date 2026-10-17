//! Deterministic session attention transitions, ported from current Swift.
//! Precise sessions sharing a directory remain independent; ambiguous directory
//! evidence never merges their authoritative state.
use super::{
    adapters::AcceptedEvent,
    observation::{Alias, Observation, SourceClass, State},
};
use crate::ai::event::{AiEvent, AiEventReliability};
use chrono::{DateTime, Duration, Utc};
use std::collections::{BTreeMap, BTreeSet};

pub const TERMINAL_REPEAT_WINDOW: Duration = Duration::seconds(10);
pub const RECORD_RETENTION: Duration = Duration::minutes(30);
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Emit,
    Drop { reason: String },
}
#[derive(Debug, Clone)]
struct Record {
    aliases: BTreeSet<Alias>,
    state: State,
    strength: u16,
    updated: DateTime<Utc>,
}
#[derive(Debug)]
pub struct Reconciler {
    records: BTreeMap<String, Record>,
    by_alias: BTreeMap<String, BTreeSet<String>>,
    pub stronger_replacement_window: Duration,
    pub terminal_repeat_window: Duration,
    pub retention: Duration,
}
impl Default for Reconciler {
    fn default() -> Self {
        Self {
            records: BTreeMap::new(),
            by_alias: BTreeMap::new(),
            stronger_replacement_window: Duration::milliseconds(250),
            terminal_repeat_window: TERMINAL_REPEAT_WINDOW,
            retention: RECORD_RETENTION,
        }
    }
}
impl Reconciler {
    pub fn reset(&mut self) {
        self.records.clear();
        self.by_alias.clear();
    }
    pub fn observe_raw(&mut self, event: &AiEvent, now: DateTime<Utc>) -> Option<String> {
        let mut o = Observation::lifecycle(event, now)?;
        self.prune(now);
        if self.ambiguous(&o) {
            return None;
        }
        let key = self.merge(&mut o);
        let mut r = self.records.remove(&key).unwrap_or_else(|| Self::blank(&o));
        r.aliases.extend(o.aliases.clone());
        r.state = o.state;
        r.strength = o.strength();
        r.updated = now;
        self.store(key, r);
        Some(format!(
            "Observed raw {} as running",
            event.normalized_type()
        ))
    }
    pub fn reconcile(&mut self, accepted: &AcceptedEvent, now: DateTime<Utc>) -> Decision {
        let Some(mut o) =
            Observation::notification(&accepted.shared_event, accepted.canonical_event.kind, now)
        else {
            return Decision::Emit;
        };
        self.prune(now);
        if self.ambiguous(&o) {
            return Decision::Drop {
                reason: "Ambiguous weak identity spans distinct provider sessions".into(),
            };
        }
        let key = self.merge(&mut o);
        let mut r = self.records.remove(&key).unwrap_or_else(|| Self::blank(&o));
        let (emit, update, reason) = self.transition(&o, &r);
        r.aliases.extend(o.aliases.clone());
        if update {
            r.state = o.state;
            r.strength = o.strength();
            r.updated = now;
        }
        self.store(key, r);
        if emit {
            Decision::Emit
        } else {
            Decision::Drop {
                reason: reason.into(),
            }
        }
    }
    /// Recheck queued/retrying delivery against the current session state.
    /// A prompt superseded by completion, or completion superseded by the next
    /// running turn, cannot apply stale style after its coalescing delay.
    pub fn is_relevant(&self, event: &AiEvent, now: DateTime<Utc>) -> bool {
        let kind = super::delivery::semantic_kind(event);
        let Some(observation) = Observation::notification(event, kind, now) else {
            return true;
        };
        let keys: BTreeSet<_> = observation
            .aliases
            .iter()
            .filter_map(|alias| self.by_alias.get(&alias.key()))
            .flatten()
            .filter(|key| {
                self.records
                    .get(*key)
                    .is_some_and(|record| Self::compatible(&observation, record))
            })
            .collect();
        if self.ambiguous(&observation) {
            return false;
        }
        if keys.len() != 1 {
            return true;
        }
        let record = &self.records[*keys.first().unwrap()];
        now - record.updated > self.retention || record.state == observation.state
    }

    fn blank(o: &Observation) -> Record {
        Record {
            aliases: o.aliases.clone(),
            state: State::Unknown,
            strength: 0,
            updated: o.timestamp,
        }
    }
    fn transition(&self, o: &Observation, r: &Record) -> (bool, bool, &'static str) {
        if r.state == State::Unknown {
            return (true, true, "first session observation");
        }
        if r.state.terminal() {
            if o.state.interactive()
                && (o.reliability == AiEventReliability::Authoritative
                    || o.timestamp - r.updated > self.terminal_repeat_window)
            {
                return (
                    true,
                    true,
                    "reopened terminal session for interactive attention",
                );
            }
            if o.state.terminal() {
                if o.state == r.state {
                    return self.same(o, r, "duplicate terminal session state");
                }
                if o.strength() > r.strength {
                    return (true, true, "stronger terminal session state");
                }
                return (false, false, "stale weaker terminal session state");
            }
            return (false, false, "same-turn post-terminal session state");
        }
        if o.state == r.state {
            return self.same(o, r, "duplicate session state");
        }
        if r.state.interactive()
            && o.state.interactive()
            && o.state.specificity() <= r.state.specificity()
            && o.strength() <= r.strength
        {
            return (false, false, "weaker duplicate interactive session state");
        }
        if o.state == State::Idle
            && r.state.interactive()
            && o.reliability != AiEventReliability::Authoritative
        {
            return (
                false,
                false,
                "ignored fallback idle while session still needs attention",
            );
        }
        (true, true, "session state transition")
    }
    fn same(
        &self,
        o: &Observation,
        r: &Record,
        reason: &'static str,
    ) -> (bool, bool, &'static str) {
        if o.strength() == r.strength
            && o.state.terminal()
            && o.reliability == AiEventReliability::Authoritative
            && matches!(o.class, SourceClass::Runtime | SourceClass::ProviderHook)
            && o.timestamp - r.updated > self.terminal_repeat_window
        {
            return (true, true, "repeated terminal session state");
        }
        if o.strength() <= r.strength {
            return (false, false, reason);
        }
        if o.timestamp - r.updated <= self.stronger_replacement_window {
            (true, true, "stronger session state replacement")
        } else {
            (
                false,
                true,
                "updated stronger duplicate without re-notifying",
            )
        }
    }
    fn compatible(o: &Observation, r: &Record) -> bool {
        for scope in [0, 1] {
            let incoming: BTreeSet<_> = o.aliases.iter().filter(|a| a.scope == scope).collect();
            let known: BTreeSet<_> = r.aliases.iter().filter(|a| a.scope == scope).collect();
            if !incoming.is_empty() && !known.is_empty() && incoming.is_disjoint(&known) {
                if scope == 1
                    && o.aliases
                        .iter()
                        .any(|a| a.scope == 0 && r.aliases.contains(a))
                {
                    continue;
                }
                return false;
            }
        }
        true
    }
    fn ambiguous(&self, observation: &Observation) -> bool {
        if observation.aliases.iter().any(|alias| alias.scope == 0) {
            return false;
        }
        let sessions: BTreeSet<_> = observation
            .aliases
            .iter()
            .filter_map(|alias| self.by_alias.get(&alias.key()))
            .flatten()
            .filter_map(|key| self.records.get(key))
            .filter(|record| Self::compatible(observation, record))
            .flat_map(|record| record.aliases.iter().filter(|alias| alias.scope == 0))
            .collect();
        sessions.len() > 1
    }

    fn merge(&mut self, o: &mut Observation) -> String {
        let mut linked: BTreeSet<String> = o
            .aliases
            .iter()
            .filter_map(|a| self.by_alias.get(&a.key()))
            .flatten()
            .filter(|key| {
                self.records
                    .get(*key)
                    .is_some_and(|r| Self::compatible(o, r))
            })
            .cloned()
            .collect();
        if o.aliases.iter().all(|a| a.scope >= 2) && linked.len() > 1 {
            o.aliases.retain(|a| a.scope != 2);
            linked.clear();
            return o.event_key.clone();
        }
        if linked.is_empty() {
            return o.primary_key();
        }
        let mut aliases = o.aliases.clone();
        let mut records = Vec::new();
        for key in &linked {
            if let Some(r) = self.records.remove(key) {
                aliases.extend(r.aliases.clone());
                records.push(r)
            }
        }
        let key = aliases
            .first()
            .map(Alias::key)
            .unwrap_or_else(|| o.event_key.clone());
        let selected = records
            .into_iter()
            .max_by(|a, b| {
                a.updated
                    .cmp(&b.updated)
                    .then(a.strength.cmp(&b.strength))
                    .then_with(|| b.state.name().cmp(a.state.name()))
            })
            .unwrap();
        for mapped in self.by_alias.values_mut() {
            mapped.retain(|k| !linked.contains(k));
        }
        self.store(
            key.clone(),
            Record {
                aliases,
                ..selected
            },
        );
        key
    }
    fn store(&mut self, key: String, r: Record) {
        for a in &r.aliases {
            self.by_alias
                .entry(a.key())
                .or_default()
                .insert(key.clone());
        }
        self.records.insert(key, r);
    }
    fn prune(&mut self, now: DateTime<Utc>) {
        self.records
            .retain(|_, r| now - r.updated <= self.retention);
        self.by_alias.retain(|_, keys| {
            keys.retain(|k| self.records.contains_key(k));
            !keys.is_empty()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ai::event::AiEventSource,
        notifications::{
            adapters::{self, IngressDecision},
            canonical::NotificationSemanticKind as K,
        },
    };
    fn base() -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000, 0).unwrap()
    }
    fn event(kind: &str, reliability: AiEventReliability) -> AiEvent {
        let mut e = AiEvent::new(
            AiEventSource::codex(),
            kind,
            "Codex",
            "Completed",
            "old timestamp",
        );
        e.reliability = reliability;
        e.session_id = Some("session".into());
        e.tab_id = Some(uuid::Uuid::nil());
        e
    }
    fn accepted(e: &AiEvent) -> AcceptedEvent {
        match adapters::ingest(e) {
            IngressDecision::Accept(a) => a,
            IngressDecision::Drop { reason } => panic!("{reason}"),
        }
    }
    fn emits(r: &mut Reconciler, e: &AiEvent, seconds: i64) -> bool {
        r.reconcile(&accepted(e), base() + Duration::seconds(seconds)) == Decision::Emit
    }
    #[test]
    fn duplicate_terminal_and_later_provider_turn_completion() {
        let mut r = Reconciler::default();
        let e = event("finished", AiEventReliability::Authoritative);
        assert!(emits(&mut r, &e, 0));
        assert!(!emits(&mut r, &e, 10));
        assert!(emits(&mut r, &e, 11));
    }
    #[test]
    fn raw_lifecycle_reopens_without_delivering_and_keeps_processing_clock() {
        let mut r = Reconciler::default();
        let mut e = event("finished", AiEventReliability::Authoritative);
        assert!(emits(&mut r, &e, 0));
        e.raw_type = Some("user-prompt".into());
        assert!(r.observe_raw(&e, base() + Duration::seconds(1)).is_some());
        e.raw_type = None;
        assert!(emits(&mut r, &e, 2));
    }
    #[test]
    fn authoritative_interactive_reopens_but_same_turn_heuristic_does_not() {
        let mut r = Reconciler::default();
        assert!(emits(
            &mut r,
            &event("finished", AiEventReliability::Authoritative),
            0
        ));
        assert!(!emits(
            &mut r,
            &event("waiting_input", AiEventReliability::Heuristic),
            1
        ));
        assert!(emits(
            &mut r,
            &event("permission", AiEventReliability::Authoritative),
            2
        ));
    }
    #[test]
    fn later_interactive_reopens_without_provider_lifecycle() {
        let mut r = Reconciler::default();
        assert!(emits(
            &mut r,
            &event("finished", AiEventReliability::Authoritative),
            0
        ));
        assert!(emits(
            &mut r,
            &event("waiting_input", AiEventReliability::Heuristic),
            11
        ));
    }
    #[test]
    fn specific_attention_survives_weaker_prompt_and_idle() {
        let mut r = Reconciler::default();
        assert!(emits(
            &mut r,
            &event("permission", AiEventReliability::Authoritative),
            0
        ));
        assert!(!emits(
            &mut r,
            &event("waiting_input", AiEventReliability::Heuristic),
            1
        ));
        assert!(!emits(
            &mut r,
            &event("idle", AiEventReliability::Fallback),
            2
        ));
    }
    #[test]
    fn stronger_replacement_within_window_then_update_without_re_notify() {
        let mut r = Reconciler::default();
        let weak = accepted(&event("waiting_input", AiEventReliability::Heuristic));
        let strong = accepted(&event("waiting_input", AiEventReliability::Authoritative));
        assert_eq!(r.reconcile(&weak, base()), Decision::Emit);
        assert_eq!(
            r.reconcile(&strong, base() + Duration::milliseconds(250)),
            Decision::Emit
        );
        let mut r = Reconciler::default();
        r.reconcile(&weak, base());
        assert!(matches!(
            r.reconcile(&strong, base() + Duration::seconds(1)),
            Decision::Drop { .. }
        ));
        assert!(matches!(
            r.reconcile(&weak, base() + Duration::seconds(2)),
            Decision::Drop { .. }
        ));
    }
    #[test]
    fn aliases_bridge_directory_tab_and_session_records() {
        let mut r = Reconciler::default();
        let mut e = event("waiting_input", AiEventReliability::Authoritative);
        e.directory = Some("/repo".into());
        e.session_id = None;
        e.tab_id = None;
        assert!(emits(&mut r, &e, 0));
        e.tab_id = Some(uuid::Uuid::nil());
        assert!(!emits(&mut r, &e, 1));
        e.session_id = Some("session".into());
        assert!(!emits(&mut r, &e, 2));
        e.directory = None;
        e.tab_id = None;
        assert!(!emits(&mut r, &e, 3));
    }
    #[test]
    fn same_repo_distinct_sessions_and_tabs_do_not_merge() {
        let mut r = Reconciler::default();
        let mut e = event("finished", AiEventReliability::Authoritative);
        e.directory = Some("/repo".into());
        assert!(emits(&mut r, &e, 0));
        e.session_id = Some("other-session".into());
        e.tab_id = Some(uuid::Uuid::new_v4());
        assert!(emits(&mut r, &e, 1));
        e.session_id = None;
        e.tab_id = None;
        assert!(!emits(&mut r, &e, 2));
        assert_eq!(r.records.len(), 2);
    }
    #[test]
    fn weak_tab_identity_cannot_merge_sequential_precise_sessions() {
        let mut r = Reconciler::default();
        let mut e = event("finished", AiEventReliability::Authoritative);
        assert!(emits(&mut r, &e, 0));
        e.session_id = Some("next-session".into());
        assert!(emits(&mut r, &e, 1));
        e.session_id = None;
        e.event_type = "waiting_input".into();
        e.reliability = AiEventReliability::Fallback;
        assert!(!emits(&mut r, &e, 2));
        assert!(!r.is_relevant(&e, base() + Duration::seconds(3)));
        e.raw_type = Some("user_prompt".into());
        assert!(r.observe_raw(&e, base() + Duration::seconds(4)).is_none());
        assert_eq!(r.records.len(), 2);
    }

    #[test]
    fn provider_identity_and_retention_are_independent() {
        let mut r = Reconciler::default();
        let mut e = event("finished", AiEventReliability::Authoritative);
        assert!(emits(&mut r, &e, 0));
        e.source = AiEventSource::claude_code();
        e.tool = "Claude".into();
        assert!(emits(&mut r, &e, 1));
        e.source = AiEventSource::codex();
        e.tool = "Codex".into();
        assert!(emits(&mut r, &e, 1801));
    }
    #[test]
    fn tool_failed_is_stateless_between_permission_and_completion() {
        let mut r = Reconciler::default();
        assert!(emits(
            &mut r,
            &event("permission", AiEventReliability::Authoritative),
            0
        ));
        let e = event("tool_failed", AiEventReliability::Authoritative);
        let mut a = accepted(&event("finished", AiEventReliability::Authoritative));
        a.shared_event = e;
        a.canonical_event.kind = K::ToolFailed;
        assert_eq!(
            r.reconcile(&a, base() + Duration::seconds(1)),
            Decision::Emit
        );
        assert!(!emits(
            &mut r,
            &event("permission", AiEventReliability::Authoritative),
            2
        ));
        assert!(emits(
            &mut r,
            &event("finished", AiEventReliability::Authoritative),
            3
        ));
    }
    #[test]
    fn queued_attention_and_previous_turn_completion_cannot_apply_stale_style() {
        let mut r = Reconciler::default();
        let waiting = accepted(&event("permission", AiEventReliability::Authoritative));
        assert_eq!(r.reconcile(&waiting, base()), Decision::Emit);
        let done = accepted(&event("finished", AiEventReliability::Authoritative));
        assert_eq!(
            r.reconcile(&done, base() + Duration::milliseconds(100)),
            Decision::Emit
        );
        assert!(!r.is_relevant(&waiting.shared_event, base() + Duration::milliseconds(250)));
        assert!(r.is_relevant(&done.shared_event, base() + Duration::milliseconds(250)));
        let mut started = done.shared_event.clone();
        started.raw_type = Some("user_prompt".into());
        r.observe_raw(&started, base() + Duration::milliseconds(300));
        assert!(!r.is_relevant(&done.shared_event, base() + Duration::milliseconds(400)));
        assert_eq!(
            r.reconcile(&waiting, base() + Duration::milliseconds(500)),
            Decision::Emit
        );
        assert!(r.is_relevant(&waiting.shared_event, base() + Duration::milliseconds(750)));
    }

    #[test]
    fn recorded_current_swift_attention_scenarios_replay_deterministically() {
        let replays: serde_json::Value =
            serde_json::from_str(include_str!("attention_replays.json")).unwrap();
        assert!(replays.as_array().unwrap().len() >= 12);
        for replay in replays.as_array().unwrap() {
            let mut r = Reconciler::default();
            for fixture in replay["events"].as_array().unwrap() {
                let source = if fixture["source"] == "codex" {
                    AiEventSource::codex()
                } else {
                    AiEventSource::claude_code()
                };
                let raw = fixture["raw_type"].as_str().unwrap();
                let mut e = AiEvent::new(
                    source,
                    raw,
                    if fixture["source"] == "codex" {
                        "Codex"
                    } else {
                        "Claude"
                    },
                    fixture["message"].as_str().unwrap(),
                    "raw timestamp",
                );
                e.raw_type = Some(raw.into());
                e.notification_type = fixture["notification_type"].as_str().map(str::to_string);
                e.tab_id = Some(uuid::Uuid::nil());
                e.session_id = Some("replay-session".into());
                e.reliability = AiEventReliability::Authoritative;
                let now = base()
                    + Duration::milliseconds((fixture["offset"].as_f64().unwrap() * 1000.) as i64);
                r.observe_raw(&e, now);
                let stage = fixture["expected_stage"].as_str().unwrap();
                match adapters::ingest(&e) {
                    IngressDecision::Drop { .. } => {
                        assert_eq!(stage, "ingress_drop", "{}", replay["name"])
                    }
                    IngressDecision::Accept(a) => {
                        assert_eq!(
                            a.canonical_event.kind.raw_value(),
                            fixture["expected_kind"].as_str().unwrap(),
                            "{}",
                            replay["name"]
                        );
                        assert_eq!(
                            r.reconcile(&a, now) == Decision::Emit,
                            stage == "deliver",
                            "{}",
                            replay["name"]
                        );
                        if stage == "deliver" {
                            assert_eq!(
                                super::super::delivery::default_style_action(&a.shared_event)
                                    .and_then(|a| a.config.get("style").cloned())
                                    .as_deref(),
                                fixture["expected_style"].as_str(),
                                "{}",
                                replay["name"]
                            );
                        }
                    }
                }
            }
        }
    }
}

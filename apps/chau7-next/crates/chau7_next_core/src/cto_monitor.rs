//! Runtime monitor of the token optimizer: records every flag decision and
//! lifecycle event, and builds the snapshot the settings and the Debug Console
//! show.
//!
//! Port of `CTORuntimeMonitor.swift`. The Swift class is a locked singleton and
//! logs under the `cto` category as it records; here it is a plain struct
//! (the app wraps it in a mutex) and the record methods return the decision
//! event to log, so this file stays free of logging and of the clock of the
//! caller.

use std::collections::{HashMap, HashSet};

use crate::token_optimization::{
    CTODecisionEvent, CTODecisionReason, CTORuntimeSnapshot, TabTokenOptOverride,
    TokenOptimizationMode, reference_now,
};

const MAX_RECENT_DECISIONS: usize = 50;

/// Every this many recalculations the monitor asks for a summary line.
pub const SUMMARY_INTERVAL: i64 = 25;

/// What one decision looked like (the arguments of `recordDecision`).
#[derive(Debug, Clone, Copy)]
pub struct Decision {
    pub mode: TokenOptimizationMode,
    pub override_mode: TabTokenOptOverride,
    pub is_ai_active: bool,
    pub previous_state: bool,
    pub next_state: bool,
    pub changed: bool,
    pub reason: CTODecisionReason,
}

#[derive(Debug)]
pub struct CtoMonitor {
    recalc_count: i64,
    created_count: i64,
    removed_count: i64,
    unchanged_count: i64,
    deferred_set_count: i64,
    deferred_flush_count: i64,
    deferred_skip_count: i64,
    setup_count: i64,
    teardown_count: i64,
    mode_change_count: i64,
    last_mode_change_at: Option<f64>,
    last_decision_at: Option<f64>,
    last_decision: Option<CTODecisionEvent>,
    active_session_count: i64,
    tracked_sessions: i64,
    reason_breakdown: HashMap<CTODecisionReason, i64>,
    active_sessions: HashSet<String>,
    tracked_session_ids: HashSet<String>,
    deferred_session_ids: HashSet<String>,
    recent_decisions: Vec<CTODecisionEvent>,
    deferred_flush_delay_sum_ms: i64,
    deferred_flush_delay_min_ms: i64,
    deferred_flush_delay_max_ms: i64,
    deferred_flush_delay_last_ms: Option<i64>,
    deferred_flush_delay_count: i64,
    current_mode: TokenOptimizationMode,
    first_seen_at: f64,
}

impl Default for CtoMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl CtoMonitor {
    pub fn new() -> Self {
        Self {
            recalc_count: 0,
            created_count: 0,
            removed_count: 0,
            unchanged_count: 0,
            deferred_set_count: 0,
            deferred_flush_count: 0,
            deferred_skip_count: 0,
            setup_count: 0,
            teardown_count: 0,
            mode_change_count: 0,
            last_mode_change_at: None,
            last_decision_at: None,
            last_decision: None,
            active_session_count: 0,
            tracked_sessions: 0,
            reason_breakdown: HashMap::new(),
            active_sessions: HashSet::new(),
            tracked_session_ids: HashSet::new(),
            deferred_session_ids: HashSet::new(),
            recent_decisions: Vec::new(),
            deferred_flush_delay_sum_ms: 0,
            deferred_flush_delay_min_ms: 0,
            deferred_flush_delay_max_ms: 0,
            deferred_flush_delay_last_ms: None,
            deferred_flush_delay_count: 0,
            current_mode: TokenOptimizationMode::Off,
            first_seen_at: reference_now(),
        }
    }

    pub fn snapshot(&self) -> CTORuntimeSnapshot {
        self.snapshot_at(reference_now())
    }

    pub fn snapshot_at(&self, now: f64) -> CTORuntimeSnapshot {
        let elapsed = (now - self.first_seen_at).max(1.0);
        let have_delay = self.deferred_flush_delay_count > 0;
        CTORuntimeSnapshot {
            mode: self.current_mode.raw_value().to_string(),
            recalc_count: self.recalc_count,
            created_count: self.created_count,
            removed_count: self.removed_count,
            unchanged_count: self.unchanged_count,
            deferred_set_count: self.deferred_set_count,
            deferred_flush_count: self.deferred_flush_count,
            deferred_skip_count: self.deferred_skip_count,
            setup_count: self.setup_count,
            teardown_count: self.teardown_count,
            mode_change_count: self.mode_change_count,
            last_mode_change_at: self.last_mode_change_at,
            last_decision_at: self.last_decision_at,
            last_decision: self.last_decision.clone(),
            active_session_count: self.active_session_count,
            tracked_sessions: self.tracked_sessions,
            pending_deferred_sessions: self.deferred_session_ids.len() as i64,
            reason_breakdown: self
                .reason_breakdown
                .iter()
                .map(|(k, v)| (reason_name(*k), *v))
                .collect(),
            deferred_flush_delay_count: self.deferred_flush_delay_count,
            deferred_flush_delay_min_ms: have_delay.then_some(self.deferred_flush_delay_min_ms),
            deferred_flush_delay_max_ms: have_delay.then_some(self.deferred_flush_delay_max_ms),
            deferred_flush_delay_average_ms: have_delay.then(|| {
                self.deferred_flush_delay_sum_ms as f64 / self.deferred_flush_delay_count as f64
            }),
            deferred_flush_delay_last_ms: self.deferred_flush_delay_last_ms,
            recent_decisions: self.recent_decisions.clone(),
            first_seen_at: self.first_seen_at,
            uptime_seconds: elapsed.round() as i64,
            decisions_per_minute: self.recalc_count as f64 / elapsed * 60.0,
        }
    }

    /// "Reset": all counters back to zero (`resetForTesting`). The first-seen
    /// time stays, as in Swift.
    pub fn reset(&mut self) {
        let first_seen_at = self.first_seen_at;
        *self = Self::new();
        self.first_seen_at = first_seen_at;
    }

    /// The mode at launch: not a change.
    pub fn set_initial_mode(&mut self, mode: TokenOptimizationMode) {
        self.current_mode = mode;
    }

    /// Returns true when the mode really changed (the caller logs it).
    pub fn record_mode_changed(
        &mut self,
        previous: TokenOptimizationMode,
        current: TokenOptimizationMode,
    ) -> bool {
        if previous != current {
            self.mode_change_count += 1;
            self.last_mode_change_at = Some(reference_now());
        }
        self.current_mode = current;
        if current == TokenOptimizationMode::Off {
            self.deferred_session_ids.clear();
        }
        previous != current
    }

    /// Returns true when a summary line is due (every fifth setup).
    pub fn record_manager_setup(&mut self, mode: Option<TokenOptimizationMode>) -> bool {
        if let Some(mode) = mode {
            self.current_mode = mode;
        }
        self.setup_count += 1;
        self.setup_count % 5 == 0
    }

    pub fn record_manager_teardown(&mut self) {
        self.teardown_count += 1;
        self.deferred_session_ids.clear();
    }

    /// A tab closed: forget it. True when something was forgotten.
    pub fn untrack_session(&mut self, session_id: &str) -> bool {
        let tracked = self.tracked_session_ids.remove(session_id);
        let active = self.active_sessions.remove(session_id);
        let deferred = self.deferred_session_ids.remove(session_id);
        self.active_session_count = self.active_sessions.len() as i64;
        self.tracked_sessions = self.tracked_session_ids.len() as i64;
        tracked || active || deferred
    }

    pub fn record_manager_bulk_remove(&mut self, count: i64) {
        self.removed_count += count;
        *self
            .reason_breakdown
            .entry(CTODecisionReason::Off)
            .or_insert(0) += count;
        self.deferred_session_ids.clear();
        for id in &self.active_sessions {
            self.tracked_session_ids.remove(id);
        }
        self.active_sessions.clear();
        self.active_session_count = 0;
        self.tracked_sessions = self.tracked_session_ids.len() as i64;
    }

    /// Returns the number of sessions waiting for their first prompt.
    pub fn record_deferred_set(&mut self, session_id: &str) -> usize {
        self.deferred_set_count += 1;
        self.deferred_session_ids.insert(session_id.to_string());
        self.track(session_id);
        self.deferred_session_ids.len()
    }

    pub fn record_deferred_flush(
        &mut self,
        session_id: &str,
        delay_to_activate_ms: i64,
        decision: Decision,
        note: Option<&str>,
    ) -> CTODecisionEvent {
        self.deferred_flush_count += 1;
        self.deferred_session_ids.remove(session_id);
        self.track(session_id);
        self.update_deferred_delay(delay_to_activate_ms);
        self.record_internal(
            session_id,
            decision,
            true,
            Some(delay_to_activate_ms),
            note.map(str::to_string),
        )
    }

    pub fn record_deferred_skip(
        &mut self,
        session_id: &str,
        reason: &str,
        mode: TokenOptimizationMode,
        override_mode: TabTokenOptOverride,
        is_ai_active: bool,
    ) -> CTODecisionEvent {
        self.deferred_skip_count += 1;
        self.deferred_session_ids.remove(session_id);
        self.track(session_id);
        let mut event = CTODecisionEvent::new(
            session_id,
            mode,
            override_mode,
            is_ai_active,
            false,
            false,
            CTODecisionReason::SkippedDueToDeferred,
        );
        event.deferred = true;
        event.changed = false;
        event.debug_note = Some(reason.to_string());
        self.append_recent(event.clone());
        event
    }

    /// Records a recalculation. The second value is true when a summary
    /// line is due.
    pub fn record_decision(
        &mut self,
        session_id: &str,
        decision: Decision,
        delay_to_activate_ms: Option<i64>,
        note: Option<&str>,
    ) -> (CTODecisionEvent, bool) {
        let event = self.record_internal(
            session_id,
            decision,
            false,
            delay_to_activate_ms,
            note.map(str::to_string),
        );
        (event, self.recalc_count % SUMMARY_INTERVAL == 0)
    }

    fn record_internal(
        &mut self,
        session_id: &str,
        d: Decision,
        deferred: bool,
        delay: Option<i64>,
        note: Option<String>,
    ) -> CTODecisionEvent {
        self.recalc_count += 1;
        *self.reason_breakdown.entry(d.reason).or_insert(0) += 1;
        if d.changed {
            if d.next_state {
                self.created_count += 1;
            } else {
                self.removed_count += 1;
            }
        } else {
            self.unchanged_count += 1;
        }
        self.track(session_id);
        if d.next_state {
            self.active_sessions.insert(session_id.to_string());
        } else {
            self.active_sessions.remove(session_id);
        }
        self.active_session_count = self.active_sessions.len() as i64;
        let mut event = CTODecisionEvent::new(
            session_id,
            d.mode,
            d.override_mode,
            d.is_ai_active,
            d.previous_state,
            d.next_state,
            d.reason,
        );
        event.deferred = deferred;
        event.delay_to_activate_ms = delay;
        event.changed = d.changed;
        event.debug_note = note;
        self.last_decision = Some(event.clone());
        self.last_decision_at = Some(event.timestamp);
        self.append_recent(event.clone());
        event
    }

    fn update_deferred_delay(&mut self, delay_ms: i64) {
        self.deferred_flush_delay_last_ms = Some(delay_ms);
        self.deferred_flush_delay_count += 1;
        self.deferred_flush_delay_sum_ms += delay_ms;
        if self.deferred_flush_delay_count == 1 {
            self.deferred_flush_delay_min_ms = delay_ms;
            self.deferred_flush_delay_max_ms = delay_ms;
        } else {
            self.deferred_flush_delay_min_ms = self.deferred_flush_delay_min_ms.min(delay_ms);
            self.deferred_flush_delay_max_ms = self.deferred_flush_delay_max_ms.max(delay_ms);
        }
    }

    fn track(&mut self, session_id: &str) {
        if self.tracked_session_ids.insert(session_id.to_string()) {
            self.tracked_sessions = self.tracked_session_ids.len() as i64;
        }
    }

    fn append_recent(&mut self, event: CTODecisionEvent) {
        self.recent_decisions.push(event);
        if self.recent_decisions.len() > MAX_RECENT_DECISIONS {
            let excess = self.recent_decisions.len() - MAX_RECENT_DECISIONS;
            self.recent_decisions.drain(..excess);
        }
    }
}

fn reason_name(reason: CTODecisionReason) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use CTODecisionReason as R;
    use TabTokenOptOverride as O;
    use TokenOptimizationMode as M;

    fn decision(changed: bool, next: bool, reason: R) -> Decision {
        Decision {
            mode: M::AllTabs,
            override_mode: O::Default,
            is_ai_active: false,
            previous_state: !next,
            next_state: next,
            changed,
            reason,
        }
    }

    #[test]
    fn decisions_update_the_counters_and_sessions() {
        let mut m = CtoMonitor::new();
        m.record_decision("A", decision(true, true, R::AllTabsDefault), None, None);
        m.record_decision("B", decision(true, true, R::AllTabsDefault), None, None);
        m.record_decision("A", decision(false, true, R::AllTabsDefault), None, None);
        m.record_decision("B", decision(true, false, R::ForceOff), None, None);
        let s = m.snapshot();
        assert_eq!(s.recalc_count, 4);
        assert_eq!(s.created_count, 2);
        assert_eq!(s.removed_count, 1);
        assert_eq!(s.unchanged_count, 1);
        assert_eq!(s.active_session_count, 1);
        assert_eq!(s.tracked_sessions, 2);
        assert_eq!(s.reason_breakdown["allTabsDefault"], 3);
        assert_eq!(s.reason_breakdown["forceOff"], 1);
        assert_eq!(s.recent_decisions.len(), 4);
        assert_eq!(s.last_decision.unwrap().session_id, "B");
    }

    #[test]
    fn recent_decisions_keep_the_last_fifty() {
        let mut m = CtoMonitor::new();
        for i in 0..60 {
            m.record_decision(
                &format!("S{i}"),
                decision(true, true, R::ForceOn),
                None,
                None,
            );
        }
        let s = m.snapshot();
        assert_eq!(s.recent_decisions.len(), 50);
        assert_eq!(s.recent_decisions[0].session_id, "S10");
    }

    #[test]
    fn summary_is_due_every_twenty_fifth_decision() {
        let mut m = CtoMonitor::new();
        let mut due = 0;
        for _ in 0..50 {
            let (_, summary) =
                m.record_decision("A", decision(false, true, R::Unchanged), None, None);
            due += usize::from(summary);
        }
        assert_eq!(due, 2);
    }

    #[test]
    fn deferred_flow_counts_delays() {
        let mut m = CtoMonitor::new();
        assert_eq!(m.record_deferred_set("A"), 1);
        assert_eq!(m.record_deferred_set("B"), 2);
        let event =
            m.record_deferred_flush("A", 120, decision(true, true, R::AllTabsDefault), None);
        assert!(event.deferred);
        assert_eq!(event.delay_to_activate_ms, Some(120));
        m.record_deferred_flush("B", 80, decision(true, true, R::AllTabsDefault), None);
        let skip = m.record_deferred_skip("C", "mode-off", M::Off, O::Default, false);
        assert_eq!(skip.reason, R::SkippedDueToDeferred);
        assert!(!skip.changed);
        assert_eq!(skip.debug_note.as_deref(), Some("mode-off"));
        let s = m.snapshot();
        assert_eq!(s.deferred_set_count, 2);
        assert_eq!(s.deferred_flush_count, 2);
        assert_eq!(s.deferred_skip_count, 1);
        assert_eq!(s.pending_deferred_sessions, 0);
        assert_eq!(s.deferred_flush_delay_count, 2);
        assert_eq!(s.deferred_flush_delay_min_ms, Some(80));
        assert_eq!(s.deferred_flush_delay_max_ms, Some(120));
        assert_eq!(s.deferred_flush_delay_average_ms, Some(100.0));
        assert_eq!(s.deferred_flush_delay_last_ms, Some(80));
        // The skip is not a recalculation.
        assert_eq!(s.recalc_count, 2);
        assert_eq!(s.recent_decisions.len(), 3);
    }

    #[test]
    fn no_delay_samples_give_no_delay_stats() {
        let s = CtoMonitor::new().snapshot();
        assert_eq!(s.deferred_flush_delay_min_ms, None);
        assert_eq!(s.deferred_flush_delay_average_ms, None);
    }

    #[test]
    fn mode_changes_and_setup_teardown() {
        let mut m = CtoMonitor::new();
        m.record_deferred_set("A");
        assert!(m.record_mode_changed(M::Off, M::AiOnly));
        assert!(!m.record_mode_changed(M::AiOnly, M::AiOnly));
        assert_eq!(m.snapshot().mode, "aiOnly");
        assert_eq!(m.snapshot().mode_change_count, 1);
        assert_eq!(m.snapshot().pending_deferred_sessions, 1);
        assert!(m.record_mode_changed(M::AiOnly, M::Off));
        assert_eq!(m.snapshot().pending_deferred_sessions, 0);
        for i in 1..=5 {
            assert_eq!(m.record_manager_setup(Some(M::Manual)), i == 5);
        }
        m.record_manager_teardown();
        let s = m.snapshot();
        assert_eq!((s.setup_count, s.teardown_count), (5, 1));
    }

    #[test]
    fn bulk_remove_and_untrack() {
        let mut m = CtoMonitor::new();
        m.record_decision("A", decision(true, true, R::ForceOn), None, None);
        m.record_decision("B", decision(true, true, R::ForceOn), None, None);
        m.record_decision("C", decision(true, false, R::ForceOff), None, None);
        m.record_manager_bulk_remove(2);
        let s = m.snapshot();
        assert_eq!(s.active_session_count, 0);
        assert_eq!(s.tracked_sessions, 1);
        assert_eq!(s.removed_count, 3);
        assert_eq!(s.reason_breakdown["off"], 2);
        assert!(m.untrack_session("C"));
        assert!(!m.untrack_session("C"));
        assert_eq!(m.snapshot().tracked_sessions, 0);
    }

    #[test]
    fn reset_clears_counters_but_not_the_start_time() {
        let mut m = CtoMonitor::new();
        let first = m.snapshot().first_seen_at;
        m.record_decision("A", decision(true, true, R::ForceOn), None, None);
        m.record_manager_setup(Some(M::AllTabs));
        m.reset();
        let s = m.snapshot();
        assert_eq!(
            (s.recalc_count, s.setup_count, s.tracked_sessions),
            (0, 0, 0)
        );
        assert_eq!(s.mode, "off");
        assert_eq!(s.first_seen_at, first);
        assert!(s.recent_decisions.is_empty());
    }

    #[test]
    fn rates_follow_the_elapsed_time() {
        let mut m = CtoMonitor::new();
        for _ in 0..30 {
            m.record_decision("A", decision(false, false, R::Unchanged), None, None);
        }
        let s = m.snapshot_at(m.first_seen_at + 60.0);
        assert_eq!(s.uptime_seconds, 60);
        assert!((s.decisions_per_minute - 30.0).abs() < 1e-9);
        let early = m.snapshot_at(m.first_seen_at);
        assert_eq!(early.uptime_seconds, 1, "elapsed time is at least a second");
    }
}

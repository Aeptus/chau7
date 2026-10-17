//! Session tracking from the Claude and Codex history files
//! (`Monitoring/HistoryIdleMonitor.swift` and the session status half of
//! `AppModel.updateSessionStatus`).
//!
//! The history files are read only. [`HistoryIdleTracker`] turns the entries
//! of one file into session states: a session is active on every entry,
//! idle after `idle_seconds` without one (one idle callback per session until
//! a user prompt arrives), closed by an exit marker or after `stale_seconds`.
//! [`SessionStatuses`] is the list the settings window shows and decides
//! when "Session completed (history)" fires.
//!
//! All functions take `now` (Unix seconds) so they are tested without
//! clocks or threads.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::history_events::{
    HistoryEntry, HistoryEntryActivityKind, HistorySessionState, evaluate_session_transition,
};
use crate::notifications::schedule::next_history_check_delay;

/// Default idle seconds (`idleSecondsText` default `5`).
pub const DEFAULT_IDLE_SECONDS: f64 = 5.0;
/// Default stale seconds (`staleSecondsText` default `180`).
pub const DEFAULT_STALE_SECONDS: f64 = 180.0;
/// Closed sessions remembered (`AppConstants.Limits.maxClosedSessions`).
pub const MAX_CLOSED_SESSIONS: usize = 100;
/// Shortest wait between two checks.
const MINIMUM_CHECK_INTERVAL: f64 = 1.0;
/// Seconds before the same session can fire "finished" again.
pub const FINISHED_COOLDOWN: f64 = 30.0;

/// `AppModel.idleSeconds`: parsed from the text field, at least 1.
pub fn idle_seconds(text: &str) -> f64 {
    text.trim()
        .parse::<f64>()
        .unwrap_or(DEFAULT_IDLE_SECONDS)
        .max(1.0)
}

/// `AppModel.staleSeconds`: at least one second more than the idle seconds.
pub fn stale_seconds(text: &str, idle: f64) -> f64 {
    text.trim()
        .parse::<f64>()
        .unwrap_or(DEFAULT_STALE_SECONDS)
        .max(idle + 1.0)
}

/// What the tracker reports.
#[derive(Debug, Clone, PartialEq)]
pub enum TrackerOutput {
    /// A session changed state (`onStateChange`).
    StateChange {
        session_id: String,
        state: HistorySessionState,
        last_seen: f64,
        idle_for: Option<f64>,
        last_entry: Option<HistoryEntry>,
    },
    /// A session has been quiet for the idle time (`onIdle`), once per
    /// stretch without user activity.
    Idle { entry: HistoryEntry, idle_for: f64 },
}

/// Insertion-ordered set with a size limit (`BoundedSet`).
#[derive(Debug, Default)]
struct BoundedSet {
    items: HashSet<String>,
    order: VecDeque<String>,
}

impl BoundedSet {
    fn insert(&mut self, item: &str) {
        if self.items.contains(item) {
            self.order.retain(|i| i != item);
            self.order.push_back(item.to_string());
            return;
        }
        while self.items.len() >= MAX_CLOSED_SESSIONS {
            match self.order.pop_front() {
                Some(oldest) => {
                    self.items.remove(&oldest);
                }
                None => break,
            }
        }
        self.items.insert(item.to_string());
        self.order.push_back(item.to_string());
    }

    fn remove(&mut self, item: &str) {
        self.items.remove(item);
        self.order.retain(|i| i != item);
    }
}

/// One history file's sessions.
#[derive(Debug, Default)]
pub struct HistoryIdleTracker {
    last_seen: HashMap<String, f64>,
    last_entry: HashMap<String, HistoryEntry>,
    /// Sessions told idle with no user activity since.
    idle_notified: HashSet<String>,
    closed: BoundedSet,
}

impl HistoryIdleTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// An entry was read at `now` (`record(entry:)`).
    pub fn record(&mut self, entry: &HistoryEntry, now: f64) -> Vec<TrackerOutput> {
        let id = entry.session_id.clone();
        if entry.is_exit {
            self.closed.insert(&id);
            self.last_seen.remove(&id);
            self.last_entry.remove(&id);
            self.idle_notified.remove(&id);
            return vec![TrackerOutput::StateChange {
                session_id: id,
                state: HistorySessionState::Closed,
                last_seen: now,
                idle_for: None,
                last_entry: Some(entry.clone()),
            }];
        }
        self.closed.remove(&id);
        self.last_seen.insert(id.clone(), now);
        self.last_entry.insert(id.clone(), entry.clone());
        // Heartbeat entries have empty summaries: only real activity clears
        // the idle dedup.
        if !entry.summary.trim().is_empty() {
            self.idle_notified.remove(&id);
        }
        vec![TrackerOutput::StateChange {
            session_id: id,
            state: HistorySessionState::Active,
            last_seen: now,
            idle_for: None,
            last_entry: Some(entry.clone()),
        }]
    }

    /// Look for idle and stale sessions (`checkIdle`).
    pub fn check(&mut self, now: f64, idle_seconds: f64, stale_seconds: f64) -> Vec<TrackerOutput> {
        let idle_seconds = idle_seconds.max(1.0);
        let stale_seconds = stale_seconds.max(idle_seconds + 1.0);
        let mut out = Vec::new();
        let mut stale = Vec::new();
        let mut snapshot: Vec<(String, f64)> = self
            .last_seen
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect();
        snapshot.sort_by(|a, b| a.0.cmp(&b.0));
        for (id, seen) in snapshot {
            let idle_for = now - seen;
            if idle_for < idle_seconds {
                continue;
            }
            if idle_for >= stale_seconds {
                self.closed.insert(&id);
                stale.push(id);
                continue;
            }
            if self.idle_notified.contains(&id) {
                continue;
            }
            let entry = self
                .last_entry
                .get(&id)
                .cloned()
                .unwrap_or_else(|| HistoryEntry::new(&id, now, "", false));
            out.push(TrackerOutput::Idle {
                entry: entry.clone(),
                idle_for,
            });
            self.idle_notified.insert(id.clone());
            out.push(TrackerOutput::StateChange {
                session_id: id,
                state: HistorySessionState::Idle,
                last_seen: seen,
                idle_for: Some(idle_for),
                last_entry: Some(entry),
            });
        }
        for id in stale {
            let Some(seen) = self.last_seen.remove(&id) else {
                continue;
            };
            out.push(TrackerOutput::StateChange {
                session_id: id.clone(),
                state: HistorySessionState::Closed,
                last_seen: seen,
                idle_for: Some(now - seen),
                last_entry: self.last_entry.remove(&id),
            });
            self.idle_notified.remove(&id);
        }
        out
    }

    /// Seconds until the next check is needed (`None` without sessions).
    pub fn next_check_delay(&self, now: f64, idle_seconds: f64, stale_seconds: f64) -> Option<f64> {
        next_history_check_delay(
            now,
            MINIMUM_CHECK_INTERVAL,
            idle_seconds,
            stale_seconds,
            &self.last_seen,
            &self.idle_notified,
        )
    }

    pub fn is_empty(&self) -> bool {
        self.last_seen.is_empty()
    }

    pub fn clear(&mut self) {
        self.last_seen.clear();
        self.last_entry.clear();
        self.idle_notified.clear();
        self.closed = BoundedSet::default();
    }
}

// MARK: statuses

/// One row of "Active Sessions" (`SessionStatus`).
#[derive(Debug, Clone, PartialEq)]
pub struct SessionStatus {
    /// `<tool>-<session id>`.
    pub id: String,
    pub session_id: String,
    pub tool: String,
    pub state: HistorySessionState,
    pub last_seen: f64,
}

/// What a state change means for the notification pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusUpdate {
    pub is_reactivation: bool,
    /// Fire "Session completed (history)" now.
    pub emits_finished: bool,
}

/// The sessions seen in history files, with the "finished" cooldown.
#[derive(Debug, Default)]
pub struct SessionStatuses {
    pub list: Vec<SessionStatus>,
    finished_at: HashMap<String, f64>,
}

impl SessionStatuses {
    pub fn new() -> Self {
        Self::default()
    }

    /// `updateSessionStatus`: record the state and decide whether the
    /// session just completed. The 30 s cooldown per session stops repeats
    /// from active/idle flapping within one run.
    pub fn update(
        &mut self,
        tool: &str,
        session_id: &str,
        state: HistorySessionState,
        last_seen: f64,
        last_activity: HistoryEntryActivityKind,
        now: f64,
    ) -> StatusUpdate {
        let id = format!("{tool}-{session_id}");
        let previous = match self.list.iter_mut().find(|s| s.id == id) {
            Some(existing) => {
                let previous = existing.state;
                existing.state = state;
                existing.last_seen = last_seen;
                Some(previous)
            }
            None => {
                self.list.push(SessionStatus {
                    id: id.clone(),
                    session_id: session_id.to_string(),
                    tool: tool.to_string(),
                    state,
                    last_seen,
                });
                None
            }
        };
        let decision = evaluate_session_transition(previous, state, last_activity);
        let mut emits = false;
        if decision.emits_finished_event {
            let fire = self
                .finished_at
                .get(&id)
                .is_none_or(|last| now - last > FINISHED_COOLDOWN);
            if fire {
                self.finished_at.insert(id, now);
                emits = true;
            }
        }
        StatusUpdate {
            is_reactivation: decision.is_reactivation,
            emits_finished: emits,
        }
    }

    /// Newest first, as the settings list shows them.
    pub fn sorted(&self) -> Vec<&SessionStatus> {
        let mut list: Vec<&SessionStatus> = self.list.iter().collect();
        list.sort_by(|a, b| {
            b.last_seen
                .partial_cmp(&a.last_seen)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        list
    }

    /// The seven-day cleanup (`performCleanup`) and the finished cooldown
    /// pruned to the surviving sessions.
    pub fn prune_older_than(&mut self, cutoff: f64) {
        self.list.retain(|s| s.last_seen >= cutoff);
        let alive: HashSet<&String> = self.list.iter().map(|s| &s.id).collect();
        self.finished_at.retain(|id, _| alive.contains(id));
    }

    /// `clearHistory`.
    pub fn clear(&mut self) {
        self.list.clear();
    }
}

/// `AppModel.latestSessionStatus(toolName:sessionId:)`: the most recently
/// seen status of a session (tool compared without case, both trimmed).
pub fn latest_session_status<'a>(
    list: &'a [SessionStatus],
    tool: &str,
    session_id: &str,
) -> Option<&'a SessionStatus> {
    let (tool, session_id) = (tool.trim(), session_id.trim());
    if tool.is_empty() || session_id.is_empty() {
        return None;
    }
    list.iter()
        .filter(|s| s.session_id == session_id && s.tool.eq_ignore_ascii_case(tool))
        .max_by(|a, b| a.last_seen.total_cmp(&b.last_seen))
}

/// `TerminalSessionModel.resolveEffectiveStatus`: the AI CLI's history
/// state wins over the shell's status (`effectiveStatus`).
pub fn resolve_effective_status(
    history: HistorySessionState,
    fallback: crate::shell_session::CommandStatus,
) -> crate::shell_session::CommandStatus {
    use crate::shell_session::CommandStatus as C;
    match history {
        HistorySessionState::Active => {
            if fallback == C::WaitingForInput {
                C::WaitingForInput
            } else {
                C::Running
            }
        }
        HistorySessionState::Idle => {
            if fallback == C::Exited {
                C::Exited
            } else {
                C::Idle
            }
        }
        HistorySessionState::Closed => fallback,
    }
}

/// `resolveEffectivePromptState` (`effectiveIsAtPrompt`).
pub fn resolve_effective_prompt_state(history: HistorySessionState, fallback: bool) -> bool {
    match history {
        HistorySessionState::Active => false,
        HistorySessionState::Idle => true,
        HistorySessionState::Closed => fallback,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_status_prefers_the_history_state() {
        use crate::shell_session::CommandStatus as C;
        use HistorySessionState as H;
        assert_eq!(resolve_effective_status(H::Active, C::Idle), C::Running);
        assert_eq!(
            resolve_effective_status(H::Active, C::WaitingForInput),
            C::WaitingForInput
        );
        assert_eq!(resolve_effective_status(H::Idle, C::Running), C::Idle);
        assert_eq!(resolve_effective_status(H::Idle, C::Exited), C::Exited);
        assert_eq!(resolve_effective_status(H::Closed, C::Stuck), C::Stuck);
        assert!(!resolve_effective_prompt_state(H::Active, true));
        assert!(resolve_effective_prompt_state(H::Idle, false));
        assert!(resolve_effective_prompt_state(H::Closed, true));
        let status = |tool: &str, id: &str, seen: f64, state| SessionStatus {
            id: format!("{tool}-{id}"),
            session_id: id.into(),
            tool: tool.into(),
            state,
            last_seen: seen,
        };
        let list = vec![
            status("Claude", "s1", 1.0, H::Active),
            status("claude", "s1", 5.0, H::Idle),
            status("Codex", "s1", 9.0, H::Closed),
        ];
        assert_eq!(
            latest_session_status(&list, " CLAUDE ", "s1").map(|s| s.state),
            Some(H::Idle)
        );
        assert!(latest_session_status(&list, "Claude", "").is_none());
        assert!(latest_session_status(&list, "Claude", "s2").is_none());
    }

    fn entry(
        session: &str,
        summary: &str,
        exit: bool,
        kind: HistoryEntryActivityKind,
    ) -> HistoryEntry {
        HistoryEntry {
            session_id: session.into(),
            timestamp: 0.0,
            summary: summary.into(),
            is_exit: exit,
            activity_kind: kind,
        }
    }

    fn prompt(session: &str, summary: &str) -> HistoryEntry {
        entry(session, summary, false, HistoryEntryActivityKind::Prompt)
    }

    fn states(out: &[TrackerOutput]) -> Vec<HistorySessionState> {
        out.iter()
            .filter_map(|o| match o {
                TrackerOutput::StateChange { state, .. } => Some(*state),
                TrackerOutput::Idle { .. } => None,
            })
            .collect()
    }

    #[test]
    fn settings_text_is_clamped() {
        assert_eq!(idle_seconds("5"), 5.0);
        assert_eq!(idle_seconds("0"), 1.0);
        assert_eq!(idle_seconds("abc"), 5.0);
        assert_eq!(stale_seconds("2", 5.0), 6.0);
        assert_eq!(stale_seconds("", 5.0), 180.0);
        assert_eq!(stale_seconds("300", 5.0), 300.0);
    }

    #[test]
    fn entries_make_sessions_active_and_exit_closes_them() {
        let mut t = HistoryIdleTracker::new();
        let out = t.record(&prompt("s1", "hello"), 100.0);
        assert_eq!(states(&out), [HistorySessionState::Active]);
        assert!(!t.is_empty());
        let out = t.record(
            &entry("s1", "exit", true, HistoryEntryActivityKind::Prompt),
            101.0,
        );
        assert_eq!(states(&out), [HistorySessionState::Closed]);
        assert!(t.is_empty());
        // A later entry reopens it.
        t.record(&prompt("s1", "again"), 200.0);
        assert!(!t.is_empty());
    }

    #[test]
    fn idle_fires_once_until_user_activity() {
        let mut t = HistoryIdleTracker::new();
        t.record(&prompt("s1", "hello"), 100.0);
        assert!(t.check(103.0, 5.0, 180.0).is_empty());
        let out = t.check(106.0, 5.0, 180.0);
        assert_eq!(out.len(), 2);
        assert!(matches!(out[0], TrackerOutput::Idle { .. }));
        assert_eq!(states(&out), [HistorySessionState::Idle]);
        // Quiet: no repeat.
        assert!(t.check(120.0, 5.0, 180.0).is_empty());
        // A heartbeat (no summary) does not re-arm idle.
        t.record(&prompt("s1", ""), 130.0);
        assert!(t.check(140.0, 5.0, 180.0).is_empty());
        // A real prompt does.
        t.record(&prompt("s1", "next task"), 150.0);
        assert_eq!(t.check(160.0, 5.0, 180.0).len(), 2);
    }

    #[test]
    fn stale_sessions_close_and_are_forgotten() {
        let mut t = HistoryIdleTracker::new();
        t.record(&prompt("s1", "hello"), 100.0);
        let out = t.check(300.0, 5.0, 180.0);
        assert_eq!(states(&out), [HistorySessionState::Closed]);
        match &out[0] {
            TrackerOutput::StateChange { idle_for, .. } => assert_eq!(*idle_for, Some(200.0)),
            other => panic!("unexpected {other:?}"),
        }
        assert!(t.is_empty());
        assert_eq!(t.next_check_delay(300.0, 5.0, 180.0), None);
    }

    #[test]
    fn next_check_delay_follows_the_schedule() {
        let mut t = HistoryIdleTracker::new();
        t.record(&prompt("s1", "hello"), 100.0);
        assert_eq!(t.next_check_delay(100.0, 5.0, 180.0), Some(5.0));
        assert_eq!(t.next_check_delay(104.5, 5.0, 180.0), Some(1.0));
    }

    #[test]
    fn finished_fires_once_per_active_to_idle_after_a_response() {
        let mut s = SessionStatuses::new();
        let response = HistoryEntryActivityKind::Response;
        let up = s.update(
            "Claude",
            "abc",
            HistorySessionState::Active,
            10.0,
            response,
            10.0,
        );
        assert!(!up.emits_finished);
        let up = s.update(
            "Claude",
            "abc",
            HistorySessionState::Idle,
            10.0,
            response,
            20.0,
        );
        assert!(up.emits_finished);
        // Idle to closed: not active before, so no second event.
        let up = s.update(
            "Claude",
            "abc",
            HistorySessionState::Closed,
            10.0,
            response,
            25.0,
        );
        assert!(!up.emits_finished);
        // Reactivation after close.
        let up = s.update(
            "Claude",
            "abc",
            HistorySessionState::Active,
            30.0,
            response,
            30.0,
        );
        assert!(up.is_reactivation);
        // Ends again within the cooldown: suppressed.
        let up = s.update(
            "Claude",
            "abc",
            HistorySessionState::Idle,
            30.0,
            response,
            35.0,
        );
        assert!(!up.emits_finished);
        assert_eq!(s.list.len(), 1);
    }

    #[test]
    fn prompts_do_not_finish_and_new_sessions_count() {
        let mut s = SessionStatuses::new();
        let up = s.update(
            "Codex",
            "x",
            HistorySessionState::Idle,
            1.0,
            HistoryEntryActivityKind::Prompt,
            1.0,
        );
        assert!(!up.emits_finished);
        // First sight in a closing state after a response does fire.
        let up = s.update(
            "Codex",
            "y",
            HistorySessionState::Closed,
            1.0,
            HistoryEntryActivityKind::Response,
            1.0,
        );
        assert!(up.emits_finished);
    }

    #[test]
    fn sorted_and_pruned() {
        let mut s = SessionStatuses::new();
        let k = HistoryEntryActivityKind::Unknown;
        s.update("A", "1", HistorySessionState::Active, 10.0, k, 10.0);
        s.update("A", "2", HistorySessionState::Active, 30.0, k, 30.0);
        assert_eq!(s.sorted()[0].session_id, "2");
        s.prune_older_than(20.0);
        assert_eq!(s.list.len(), 1);
        s.clear();
        assert!(s.list.is_empty());
    }

    #[test]
    fn closed_set_is_bounded() {
        let mut set = BoundedSet::default();
        for i in 0..150 {
            set.insert(&format!("s{i}"));
        }
        assert_eq!(set.items.len(), MAX_CLOSED_SESSIONS);
        assert!(!set.items.contains("s0"));
        assert!(set.items.contains("s149"));
    }
}

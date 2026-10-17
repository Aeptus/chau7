//! Ports of `Notifications/NotificationPipeline.swift` (the pure decision
//! engine) and `Notifications/NotificationRateLimiter.swift`.
//!
//! Decision order: trigger lookup (exact, then the source's wildcard),
//! enabled (per-trigger override, group override, default), conditions
//! (per-trigger, then group, then default), actions (per-trigger, then
//! group, then one "show notification"). When the event's tab is selected
//! and the condition says "only when tab inactive", only the tab is styled.
//! A single plain "show notification" uses the default path. Rate limiting
//! is applied by the caller after the decision.

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::actions::{NotificationActionConfig, NotificationActionType};
use super::delivery::style_only_actions;
use super::triggers::{self, NotificationTrigger, NotificationTriggerState, TriggerCondition};
use crate::ai::event::AiEvent;

/// `NotificationPipeline.Decision`.
#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    /// Don't fire: trigger disabled or a condition not met.
    Drop { reason: String },
    /// Fire the default notification (banner plus default tab style).
    FireDefault { trigger_id: Option<String> },
    /// The tab is selected: only style it.
    FireStyleOnly {
        trigger_id: Option<String>,
        actions: Vec<NotificationActionConfig>,
    },
    /// Fire the configured actions.
    FireActions {
        trigger_id: String,
        actions: Vec<NotificationActionConfig>,
    },
}

/// Everything the decision reads (`NotificationPipeline.Input`).
#[derive(Debug, Clone, Copy)]
pub struct PipelineInput<'a> {
    pub event: &'a AiEvent,
    pub trigger_state: &'a NotificationTriggerState,
    pub trigger_conditions: &'a BTreeMap<String, TriggerCondition>,
    pub action_bindings: &'a BTreeMap<String, Vec<NotificationActionConfig>>,
    pub group_conditions: &'a BTreeMap<String, TriggerCondition>,
    pub group_action_bindings: &'a BTreeMap<String, Vec<NotificationActionConfig>>,
    pub is_focus_mode_active: bool,
    pub is_app_active: bool,
    pub is_tool_tab_active: bool,
}

fn group_trigger_id(trigger: &NotificationTrigger) -> Option<String> {
    triggers::group_for(&trigger.source).map(|g| g.group_trigger_id(&trigger.trigger_type))
}

/// Condition for a trigger: per-trigger, then group, then the default.
pub fn resolved_condition(
    trigger: &NotificationTrigger,
    trigger_conditions: &BTreeMap<String, TriggerCondition>,
    group_conditions: &BTreeMap<String, TriggerCondition>,
) -> TriggerCondition {
    if let Some(c) = trigger_conditions.get(&trigger.id) {
        return *c;
    }
    if let Some(c) = group_trigger_id(trigger).and_then(|gid| group_conditions.get(&gid)) {
        return *c;
    }
    TriggerCondition::default()
}

/// Actions for a trigger: per-trigger, then group, then one "show
/// notification".
pub fn resolved_actions(
    trigger: &NotificationTrigger,
    action_bindings: &BTreeMap<String, Vec<NotificationActionConfig>>,
    group_action_bindings: &BTreeMap<String, Vec<NotificationActionConfig>>,
) -> Vec<NotificationActionConfig> {
    if let Some(bound) = action_bindings.get(&trigger.id).filter(|a| !a.is_empty()) {
        return bound.clone();
    }
    if let Some(group) = group_trigger_id(trigger)
        .and_then(|gid| group_action_bindings.get(&gid))
        .filter(|a| !a.is_empty())
    {
        return group.clone();
    }
    vec![NotificationActionConfig::new(
        NotificationActionType::ShowNotification,
    )]
}

/// `NotificationPipeline.evaluate`.
pub fn evaluate(input: &PipelineInput) -> Decision {
    let drop = |reason: String| Decision::Drop { reason };
    if let Some(trigger) = triggers::trigger_for_event(input.event) {
        if !input.trigger_state.is_enabled(trigger) {
            return drop(format!("Trigger {} disabled", trigger.id));
        }
        let condition =
            resolved_condition(trigger, input.trigger_conditions, input.group_conditions);
        if condition.respect_dnd && input.is_focus_mode_active {
            return drop("DND/Focus active".into());
        }
        if condition.only_when_unfocused && input.is_app_active {
            return drop("App is active (onlyWhenUnfocused)".into());
        }
        let actions = resolved_actions(trigger, input.action_bindings, input.group_action_bindings);
        if !actions.iter().any(|a| a.enabled) {
            return drop(format!("All actions disabled for trigger {}", trigger.id));
        }
        if condition.only_when_tab_inactive && input.is_tool_tab_active {
            let style = style_only_actions(input.event, &actions);
            if !style.is_empty() {
                return Decision::FireStyleOnly {
                    trigger_id: Some(trigger.id.clone()),
                    actions: style,
                };
            }
            return drop("Tool tab is active (onlyWhenTabInactive)".into());
        }
        if let [only] = actions.as_slice()
            && only.enabled
            && only.action_type == NotificationActionType::ShowNotification
            && only.config.is_empty()
        {
            return Decision::FireDefault {
                trigger_id: Some(trigger.id.clone()),
            };
        }
        return Decision::FireActions {
            trigger_id: trigger.id.clone(),
            actions,
        };
    }

    // No matching trigger: default conditions, then the default notification.
    let defaults = TriggerCondition::default();
    if defaults.respect_dnd && input.is_focus_mode_active {
        return drop("DND/Focus active (unmatched trigger, default condition)".into());
    }
    if defaults.only_when_unfocused && input.is_app_active {
        return drop("App is active (unmatched trigger, default condition)".into());
    }
    if defaults.only_when_tab_inactive && input.is_tool_tab_active {
        let style = style_only_actions(input.event, &[]);
        if !style.is_empty() {
            return Decision::FireStyleOnly {
                trigger_id: None,
                actions: style,
            };
        }
        return drop("Tool tab is active (unmatched trigger, default condition)".into());
    }
    Decision::FireDefault { trigger_id: None }
}

// MARK: - Rate limiter

/// `NotificationRateLimiter.Config`. JSON keys match the Swift `Codable`
/// output (`maxPerMinute`, `burstAllowance`, `cooldownSeconds`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RateLimitConfig {
    /// Notifications per minute per trigger (token refill rate).
    #[serde(rename = "maxPerMinute")]
    pub max_per_minute: i64,
    /// Extra burst above the per-minute rate.
    #[serde(rename = "burstAllowance")]
    pub burst_allowance: i64,
    /// Minimum seconds between two firings of the same trigger.
    #[serde(rename = "cooldownSeconds")]
    pub cooldown_seconds: f64,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            max_per_minute: 5,
            burst_allowance: 3,
            cooldown_seconds: 10.0,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: f64,
    last_refill: Instant,
    last_fired: Option<Instant>,
}

/// Token bucket per key, with a cooldown (`NotificationRateLimiter`).
#[derive(Debug, Default)]
pub struct RateLimiter {
    pub config: RateLimitConfig,
    buckets: HashMap<String, Bucket>,
}

impl RateLimiter {
    pub fn new(config: RateLimitConfig) -> Self {
        Self {
            config,
            buckets: HashMap::new(),
        }
    }

    /// Whether a notification may fire now; consumes a token when it may.
    pub fn check_and_consume(&mut self, key: &str, now: Instant) -> bool {
        let max_tokens = (self.config.max_per_minute + self.config.burst_allowance) as f64;
        let bucket = self.buckets.entry(key.to_string()).or_insert(Bucket {
            tokens: max_tokens,
            last_refill: now,
            last_fired: None,
        });
        let elapsed = now
            .saturating_duration_since(bucket.last_refill)
            .as_secs_f64();
        let refill_rate = self.config.max_per_minute as f64 / 60.0;
        bucket.tokens = (bucket.tokens + elapsed * refill_rate).min(max_tokens);
        bucket.last_refill = now;
        if let Some(last) = bucket.last_fired
            && now.saturating_duration_since(last)
                < Duration::from_secs_f64(self.config.cooldown_seconds.max(0.0))
        {
            return false;
        }
        if bucket.tokens < 1.0 {
            return false;
        }
        bucket.tokens -= 1.0;
        bucket.last_fired = Some(now);
        true
    }

    /// Forget every bucket (on settings change).
    pub fn reset(&mut self) {
        self.buckets.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;

    struct Fixture {
        state: NotificationTriggerState,
        conditions: BTreeMap<String, TriggerCondition>,
        bindings: BTreeMap<String, Vec<NotificationActionConfig>>,
        group_conditions: BTreeMap<String, TriggerCondition>,
        group_bindings: BTreeMap<String, Vec<NotificationActionConfig>>,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                state: NotificationTriggerState::default(),
                conditions: BTreeMap::new(),
                bindings: BTreeMap::new(),
                group_conditions: BTreeMap::new(),
                group_bindings: BTreeMap::new(),
            }
        }

        fn eval(&self, event: &AiEvent, dnd: bool, app: bool, tab: bool) -> Decision {
            evaluate(&PipelineInput {
                event,
                trigger_state: &self.state,
                trigger_conditions: &self.conditions,
                action_bindings: &self.bindings,
                group_conditions: &self.group_conditions,
                group_action_bindings: &self.group_bindings,
                is_focus_mode_active: dnd,
                is_app_active: app,
                is_tool_tab_active: tab,
            })
        }
    }

    fn unmatched() -> AiEvent {
        AiEvent::new(
            AiEventSource::new("test_uncataloged_source"),
            "some_type",
            "TestTool",
            "test",
            "t",
        )
    }

    fn claude_finished() -> AiEvent {
        AiEvent::new(
            AiEventSource::claude_code(),
            "finished",
            "Claude",
            "done",
            "t",
        )
    }

    fn reason(d: Decision) -> String {
        match d {
            Decision::Drop { reason } => reason,
            other => panic!("expected drop, got {other:?}"),
        }
    }

    #[test]
    fn unmatched_trigger_drops_when_dnd_active() {
        assert!(reason(Fixture::new().eval(&unmatched(), true, false, false)).contains("DND"));
    }

    #[test]
    fn unmatched_trigger_drops_when_tab_active() {
        assert!(reason(Fixture::new().eval(&unmatched(), false, false, true)).contains("tab"));
    }

    #[test]
    fn unmatched_trigger_fires_default_when_all_conditions_met() {
        assert_eq!(
            Fixture::new().eval(&unmatched(), false, false, false),
            Decision::FireDefault { trigger_id: None }
        );
    }

    #[test]
    fn unmatched_trigger_dnd_takes_priority_over_tab_active() {
        assert!(reason(Fixture::new().eval(&unmatched(), true, false, true)).contains("DND"));
    }

    #[test]
    fn unmatched_trigger_app_active_follows_default_condition() {
        assert!(!TriggerCondition::default().only_when_unfocused);
        assert!(matches!(
            Fixture::new().eval(&unmatched(), false, true, false),
            Decision::FireDefault { .. }
        ));
    }

    #[test]
    fn matched_trigger_drops_when_dnd_active() {
        assert!(
            reason(Fixture::new().eval(&claude_finished(), true, false, false)).contains("DND")
        );
    }

    #[test]
    fn matched_trigger_drops_when_only_single_default_notification_action_is_disabled() {
        let mut f = Fixture::new();
        f.bindings.insert(
            "claude_code.finished".into(),
            vec![
                NotificationActionConfig::new(NotificationActionType::ShowNotification)
                    .with_enabled(false),
            ],
        );
        assert!(reason(f.eval(&claude_finished(), false, false, false)).contains("disabled"));
    }

    #[test]
    fn matched_trigger_fires_default_when_single_notification_action_is_enabled() {
        let mut f = Fixture::new();
        f.bindings.insert(
            "claude_code.finished".into(),
            vec![NotificationActionConfig::new(
                NotificationActionType::ShowNotification,
            )],
        );
        assert_eq!(
            f.eval(&claude_finished(), false, false, false),
            Decision::FireDefault {
                trigger_id: Some("claude_code.finished".into())
            }
        );
    }

    #[test]
    fn matched_finished_trigger_styles_selected_tab_when_notification_is_suppressed() {
        match Fixture::new().eval(&claude_finished(), false, false, true) {
            Decision::FireStyleOnly {
                trigger_id,
                actions,
            } => {
                assert_eq!(trigger_id.as_deref(), Some("claude_code.finished"));
                assert_eq!(actions.len(), 1);
                assert_eq!(actions[0].action_type, NotificationActionType::StyleTab);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn group_bindings_and_conditions_apply_to_every_ai_source() {
        let mut f = Fixture::new();
        let actions = vec![
            NotificationActionConfig::new(NotificationActionType::ShowNotification),
            NotificationActionConfig::new(NotificationActionType::DockBounce),
        ];
        f.group_bindings
            .insert("ai_coding.finished".into(), actions.clone());
        let codex = AiEvent::new(AiEventSource::codex(), "finished", "Codex", "", "t");
        assert_eq!(
            f.eval(&codex, false, false, false),
            Decision::FireActions {
                trigger_id: "codex.finished".into(),
                actions
            }
        );
        f.group_conditions.insert(
            "ai_coding.finished".into(),
            TriggerCondition {
                only_when_unfocused: true,
                only_when_tab_inactive: false,
                respect_dnd: false,
            },
        );
        assert!(reason(f.eval(&codex, true, true, false)).contains("onlyWhenUnfocused"));
        // A per-trigger condition beats the group one.
        f.conditions
            .insert("codex.finished".into(), TriggerCondition::default());
        assert!(matches!(
            f.eval(&codex, false, true, false),
            Decision::FireActions { .. }
        ));
    }

    #[test]
    fn disabled_trigger_and_tab_active_without_style() {
        let mut f = Fixture::new();
        let trigger = triggers::trigger_for_event(&claude_finished()).unwrap();
        f.state.set_enabled(false, trigger);
        assert!(reason(f.eval(&claude_finished(), false, false, false)).contains("disabled"));
        let mut f = Fixture::new();
        f.bindings.insert(
            "claude_code.finished".into(),
            vec![
                NotificationActionConfig::new(NotificationActionType::StyleTab).with_enabled(false),
                NotificationActionConfig::new(NotificationActionType::ShowNotification),
            ],
        );
        assert!(
            reason(f.eval(&claude_finished(), false, false, true)).contains("onlyWhenTabInactive")
        );
    }

    // NotificationRateLimiter

    #[test]
    fn rate_limiter_cooldown_and_burst() {
        let mut limiter = RateLimiter::new(RateLimitConfig::default());
        let t0 = Instant::now();
        assert!(limiter.check_and_consume("a", t0));
        // Cooldown 10 s.
        assert!(!limiter.check_and_consume("a", t0 + Duration::from_secs(5)));
        // Independent keys.
        assert!(limiter.check_and_consume("b", t0));
        let mut limiter = RateLimiter::new(RateLimitConfig {
            max_per_minute: 1,
            burst_allowance: 1,
            cooldown_seconds: 0.0,
        });
        assert!(limiter.check_and_consume("k", t0));
        assert!(limiter.check_and_consume("k", t0));
        assert!(!limiter.check_and_consume("k", t0));
        // One token per minute refills.
        assert!(limiter.check_and_consume("k", t0 + Duration::from_secs(60)));
        limiter.reset();
        assert!(limiter.check_and_consume("k", t0 + Duration::from_secs(60)));
    }

    #[test]
    fn rate_limit_config_json_keys() {
        let json = serde_json::to_string(&RateLimitConfig::default()).unwrap();
        assert_eq!(
            json,
            r#"{"maxPerMinute":5,"burstAllowance":3,"cooldownSeconds":10.0}"#
        );
        let parsed: RateLimitConfig =
            serde_json::from_str(r#"{"maxPerMinute":2,"burstAllowance":0,"cooldownSeconds":3}"#)
                .unwrap();
        assert_eq!(parsed.max_per_minute, 2);
        assert_eq!(parsed.cooldown_seconds, 3.0);
    }
}

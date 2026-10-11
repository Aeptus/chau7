//! Shared per-tool token buckets matching current Swift MCP limits.
use std::collections::HashMap;
use std::time::Duration;

#[derive(Clone, Copy, Debug)]
pub struct Limit {
    pub per_minute: u32,
    pub burst: u32,
}
impl Limit {
    fn capacity(self) -> f64 {
        f64::from(self.per_minute) + f64::from(self.burst)
    }
    fn refill(self) -> f64 {
        f64::from(self.per_minute) / 60.0
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Decision {
    Allowed,
    Limited { retry_after_seconds: Option<f64> },
}
struct Bucket {
    tokens: f64,
    last_refill: Duration,
}
#[derive(Default)]
pub struct ToolRateLimiter {
    buckets: HashMap<String, Bucket>,
}
pub fn tool_limit(name: &str) -> Limit {
    match name {
        "chau7_state_snapshot"
        | "chau7_runtime_events"
        | "tab_output"
        | "tab_status"
        | "tab_wait_ready"
        | "session_current" => Limit {
            per_minute: 240,
            burst: 120,
        },
        "chau7_subscribe" => Limit {
            per_minute: 30,
            burst: 10,
        },
        "chau7_unsubscribe" => Limit {
            per_minute: 60,
            burst: 20,
        },
        _ => Limit {
            per_minute: 120,
            burst: 30,
        },
    }
}
impl ToolRateLimiter {
    /// Call only after validating the tool name, so the bucket set is bounded by
    /// the published catalog. `now` is elapsed monotonic time from server start.
    pub fn evaluate(&mut self, tool: &str, now: Duration) -> Decision {
        self.evaluate_with_limit(tool, now, tool_limit(tool))
    }
    fn evaluate_with_limit(&mut self, tool: &str, now: Duration, limit: Limit) -> Decision {
        let bucket = self.buckets.entry(tool.into()).or_insert(Bucket {
            tokens: limit.capacity(),
            last_refill: now,
        });
        let elapsed = now.saturating_sub(bucket.last_refill).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * limit.refill()).min(limit.capacity());
        bucket.last_refill = bucket.last_refill.max(now);
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            Decision::Allowed
        } else {
            Decision::Limited {
                retry_after_seconds: (limit.per_minute > 0)
                    .then(|| (1.0 - bucket.tokens) / limit.refill()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_swift_budgets_are_independent_and_refill() {
        let mut limiter = ToolRateLimiter::default();
        for _ in 0..40 {
            assert_eq!(
                limiter.evaluate("chau7_subscribe", Duration::ZERO),
                Decision::Allowed
            );
        }
        assert_eq!(
            limiter.evaluate("chau7_subscribe", Duration::ZERO),
            Decision::Limited {
                retry_after_seconds: Some(2.0)
            }
        );
        assert_eq!(
            limiter.evaluate("tab_status", Duration::ZERO),
            Decision::Allowed
        );
        assert_eq!(
            limiter.evaluate("chau7_subscribe", Duration::from_secs(1)),
            Decision::Limited {
                retry_after_seconds: Some(1.0)
            }
        );
        assert_eq!(
            limiter.evaluate("chau7_subscribe", Duration::from_secs(2)),
            Decision::Allowed
        );
        for _ in 0..150 {
            assert_eq!(
                limiter.evaluate("tab_create", Duration::ZERO),
                Decision::Allowed
            );
        }
        assert_eq!(
            limiter.evaluate("tab_create", Duration::ZERO),
            Decision::Limited {
                retry_after_seconds: Some(0.5)
            }
        );
    }
    #[test]
    fn refills_cap_at_capacity_and_time_cannot_go_backwards() {
        let mut limiter = ToolRateLimiter::default();
        let limit = Limit {
            per_minute: 60,
            burst: 0,
        };
        for _ in 0..60 {
            assert_eq!(
                limiter.evaluate_with_limit("tool", Duration::from_secs(100), limit),
                Decision::Allowed
            );
        }
        assert!(matches!(
            limiter.evaluate_with_limit("tool", Duration::from_secs(90), limit),
            Decision::Limited { .. }
        ));
        assert_eq!(
            limiter.evaluate_with_limit("tool", Duration::from_secs(100), limit),
            Decision::Limited {
                retry_after_seconds: Some(1.0)
            }
        );
        assert_eq!(
            limiter.evaluate_with_limit("tool", Duration::from_secs(10_000), limit),
            Decision::Allowed
        );
        for _ in 0..59 {
            assert_eq!(
                limiter.evaluate_with_limit("tool", Duration::from_secs(10_000), limit),
                Decision::Allowed
            );
        }
        assert!(matches!(
            limiter.evaluate_with_limit("tool", Duration::from_secs(10_000), limit),
            Decision::Limited { .. }
        ));
    }
    #[test]
    fn disabled_limit_never_divides_by_zero() {
        let mut limiter = ToolRateLimiter::default();
        assert_eq!(
            limiter.evaluate_with_limit(
                "tool",
                Duration::ZERO,
                Limit {
                    per_minute: 0,
                    burst: 0
                }
            ),
            Decision::Limited {
                retry_after_seconds: None
            }
        );
    }
    #[test]
    fn polling_and_unsubscribe_have_the_current_catalog_budgets() {
        let mut limiter = ToolRateLimiter::default();
        for name in [
            "chau7_state_snapshot",
            "chau7_runtime_events",
            "tab_output",
            "tab_status",
            "tab_wait_ready",
            "session_current",
            "chau7_unsubscribe",
        ] {
            let budget = if name == "chau7_unsubscribe" { 80 } else { 360 };
            for _ in 0..budget {
                assert_eq!(limiter.evaluate(name, Duration::ZERO), Decision::Allowed);
            }
            assert!(matches!(
                limiter.evaluate(name, Duration::ZERO),
                Decision::Limited { .. }
            ));
        }
    }
}

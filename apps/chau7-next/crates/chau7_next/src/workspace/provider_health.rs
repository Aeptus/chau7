//! Focused terminal service-health border. Reads the official monitor's cached
//! observations only; painting never requests a feed or accesses the filesystem.
use chau7_next_core::telemetry::provider_health::{HealthSnapshot, Severity};
use chrono::{DateTime, Utc};
use gpui::{AnyElement, App, Bounds, Role, canvas, div, point, prelude::*, px, size};

use super::Workspace;
use crate::settings::Settings;

fn provider_key(raw: &str) -> String {
    let value = raw.trim().to_lowercase();
    if value.contains("anthropic") || value.contains("claude") {
        "anthropic".into()
    } else if value.contains("openai") || value.contains("chatgpt") || value.contains("codex") {
        "openai".into()
    } else if value == "google" || value.contains("gemini") || value.contains("google ai") {
        "google".into()
    } else if value.contains("github") || value.contains("copilot") {
        "github".into()
    } else {
        value
    }
}

fn focused_alert<'a>(
    enabled: bool,
    key_window: bool,
    provider: Option<&str>,
    snapshots: &'a [HealthSnapshot],
    now: DateTime<Utc>,
) -> Option<&'a HealthSnapshot> {
    if !enabled || !key_window {
        return None;
    }
    let provider = provider_key(provider?);
    snapshots
        .iter()
        .find(|s| s.provider == provider && s.active_alert(now).is_some())
}

impl Workspace {
    pub(super) fn provider_health_border(&self, cx: &App) -> Option<AnyElement> {
        let tab = self.state.selected()?;
        let session = self.entries.get(&tab)?.panes.read(cx).focused_session(cx)?;
        let provider = session.read(cx).shell().effective_provider();
        let snapshots = crate::telemetry::usage::provider_health(cx);
        let snapshot = focused_alert(
            Settings::get(cx).tabs.show_provider_health_border,
            self.window_active,
            provider.as_deref(),
            &snapshots,
            Utc::now(),
        )?;
        let (width, color, state) = match snapshot.severity {
            Severity::Degraded => (
                1.0,
                crate::theme::rgb_tuple((255, 149, 0)),
                crate::l10n::l("providerHealth.degraded", "degraded performance"),
            ),
            Severity::Outage => (
                2.0,
                crate::theme::rgb_tuple((255, 59, 48)),
                crate::l10n::l("providerHealth.outage", "service outage"),
            ),
            _ => return None,
        };
        let name = match snapshot.provider.as_str() {
            "anthropic" => "Anthropic",
            "openai" => "OpenAI",
            "google" => "Google",
            "github" => "GitHub",
            other => other,
        };
        let label = crate::l10n::lf(
            "providerHealth.accessibilityLabel",
            "%@ provider status",
            &[name.into()],
        );
        // No mouse handlers, background, focus target or occlusion: this paint
        // overlay leaves the underlying terminal's pointer input intact.
        Some(
            div()
                .id("focused-provider-health-border")
                .absolute()
                .size_full()
                .role(Role::Label)
                .aria_label(format!("{label}. {state}. {}", snapshot.summary))
                .child(
                    canvas(
                        |bounds, _, _| bounds,
                        move |_, bounds, window, _| {
                            let x = bounds.origin.x;
                            let y = bounds.origin.y;
                            let w = bounds.size.width;
                            let h = bounds.size.height;
                            let stroke = px(width).min(w / 2.0).min(h / 2.0);
                            for edge in [
                                Bounds::new(point(x, y), size(w, stroke)),
                                Bounds::new(point(x, y + h - stroke), size(w, stroke)),
                                Bounds::new(point(x, y + stroke), size(stroke, h - stroke * 2.0)),
                                Bounds::new(
                                    point(x + w - stroke, y + stroke),
                                    size(stroke, h - stroke * 2.0),
                                ),
                            ] {
                                window.paint_quad(gpui::fill(edge, color));
                            }
                        },
                    )
                    .size_full(),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn focused_provider_and_setting_control_actual_alert() {
        let now = Utc::now();
        let snapshots = [HealthSnapshot {
            provider: "openai".into(),
            severity: Severity::Outage,
            summary: "Observed Responses outage".into(),
            source_url: "https://status.openai.com".into(),
            checked_at: now,
        }];
        assert!(focused_alert(true, true, Some("Codex"), &snapshots, now).is_some());
        assert!(focused_alert(false, true, Some("codex"), &snapshots, now).is_none());
        assert!(focused_alert(true, false, Some("codex"), &snapshots, now).is_none());
        assert!(focused_alert(true, true, None, &snapshots, now).is_none());
        assert!(focused_alert(true, true, Some("claude"), &snapshots, now).is_none());
        assert!(
            focused_alert(
                true,
                true,
                Some("codex"),
                &snapshots,
                now + Duration::seconds(301)
            )
            .is_none()
        );
        assert!(
            focused_alert(
                true,
                true,
                Some("codex"),
                &snapshots,
                now - Duration::seconds(1)
            )
            .is_none()
        );
        for severity in [Severity::Unknown, Severity::Operational] {
            let mut snapshots = snapshots.clone();
            snapshots[0].severity = severity;
            assert!(focused_alert(true, true, Some("codex"), &snapshots, now).is_none());
        }
    }

    #[test]
    fn tool_names_match_the_current_official_vendor_sources() {
        for (raw, expected) in [
            ("Claude Code", "anthropic"),
            (" CODEX ", "openai"),
            ("ChatGPT", "openai"),
            ("Gemini", "google"),
            ("GitHub Copilot", "github"),
            ("unobserved", "unobserved"),
        ] {
            assert_eq!(provider_key(raw), expected);
        }
    }
}

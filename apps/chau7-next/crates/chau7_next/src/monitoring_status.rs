//! What Settings > General > Status shows (`AppModel.notificationStatus`,
//! `isMonitoring`, `isIdleMonitoring`, `isTerminalMonitoring`).
//!
//! Each monitor sets its flag when it starts or stops; nothing here starts
//! anything. A monitor that is not ported yet leaves its flag off, so the
//! row reads "Paused".

use gpui::{App, Global};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MonitoringStatus {
    /// Notification permission, as text ("Authorized", "Denied", ...).
    pub notifications: String,
    /// AI event log tailing (`events.log`).
    pub events: bool,
    /// Shell history watching (idle detection).
    pub history: bool,
    /// Terminal output log tailing.
    pub terminal: bool,
}

impl Default for MonitoringStatus {
    fn default() -> Self {
        Self {
            notifications: "Unknown".into(),
            events: false,
            history: false,
            terminal: false,
        }
    }
}

impl Global for MonitoringStatus {}

impl MonitoringStatus {
    /// The current status; the default when no monitor reported yet.
    pub fn get(cx: &App) -> MonitoringStatus {
        cx.try_global::<MonitoringStatus>()
            .cloned()
            .unwrap_or_default()
    }

    /// Change the status; open windows redraw. The monitors call this when
    /// they start or stop.
    #[allow(dead_code)]
    pub fn update(cx: &mut App, change: impl FnOnce(&mut MonitoringStatus)) {
        let mut status = Self::get(cx);
        change(&mut status);
        cx.set_global(status);
        cx.refresh_windows();
    }
}

impl MonitoringStatus {
    /// Like [`MonitoringStatus::update`], redrawing only when something changed.
    pub fn update_if_changed(cx: &mut App, change: impl FnOnce(&mut MonitoringStatus)) {
        let before = Self::get(cx);
        let mut status = before.clone();
        change(&mut status);
        if status != before {
            cx.set_global(status);
            cx.refresh_windows();
        }
    }
}

/// "Active" or "Paused" for a monitor flag.
pub fn state_label(active: bool) -> &'static str {
    if active { "Active" } else { "Paused" }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(state_label(true), "Active");
        assert_eq!(state_label(false), "Paused");
        assert!(!MonitoringStatus::default().events);
    }
}

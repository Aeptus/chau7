//! The pure half of the notification engine (the app half is
//! `chau7_next::notifications`).
//!
//! | Module | Swift |
//! |---|---|
//! | [`triggers`] | `NotificationTriggerCatalog.swift` |
//! | [`actions`] | `NotificationActionCatalog.swift` |
//! | [`action_requirements`] | `NotificationActionRequirements.swift` |
//! | [`schedule`] | `MonitoringSchedule.swift` (coalescing and rate limit keys) |
//! | [`canonical`] | `Notifications/CanonicalNotificationModel.swift`, `CanonicalNotificationMapping.swift` |
//! | [`adapters`] | `Notifications/NotificationProviderAdapterRegistry.swift`, `NotificationIngress.swift` |
//! | [`delivery`] | `NotificationDeliverySemantics.swift`, `NotificationEventPreparation.swift`, `NotificationStylePlanner.swift` |
//! | [`pipeline`] | `Notifications/NotificationPipeline.swift`, `NotificationRateLimiter.swift` (app target in Swift) |
//! | [`history`] | `Notifications/NotificationHistory.swift` |
//! | [`tab_resolver`] | `Notifications/TabResolver.swift` |
//! | [`action_support`] | pure parts of `Notifications/NotificationActionExecutor.swift` |
//! | [`settings`] | `NotificationSettings`, `ShellEventConfig`, `AppEventConfig` in `FeatureSettings.swift` |
//! | [`app_events`] | timing rules of `Events/AppEventEmitter.swift` |
//! | [`shell_events`] | `Monitoring/ShellEventDetector.swift` (`commandFinished`) |
//!
//! Events are the shared [`AiEvent`] from `crate::ai::event`.

pub mod action_requirements;
pub mod action_support;
pub mod actions;
pub mod adapters;
pub mod app_events;
pub mod canonical;
pub mod delivery;
pub mod history;
pub mod hooks;
pub mod pipeline;
pub mod repo_muting;
pub mod schedule;
pub mod settings;
pub mod shell_events;
pub mod tab_resolver;
pub mod triggers;

pub use crate::ai::event::{AiEvent, AiEventReliability, AiEventSource};

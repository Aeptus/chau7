//! Per-tab monitoring glue (Swift `Monitoring/`): shell events and dev
//! server detection for a terminal session ([`session::SessionMonitor`]),
//! and the process sampling of the tab hover card ([`processes`]). The
//! logic lives in `chau7_next_core::monitoring`; app-wide monitors (event
//! logs, Claude hooks, history idle) are in `crate::ai::hub`.

pub mod aethyme_delivery;
pub mod file_monitor;
pub mod processes;
pub mod session;

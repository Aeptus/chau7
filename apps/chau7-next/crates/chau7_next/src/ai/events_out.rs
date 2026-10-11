//! The unified AI event feed (`AppModel.recordEvent` / `publishUnifiedEvent`):
//! every monitor (event logs, Claude Code hooks, history idle detection,
//! terminal sessions, shell events, file conflicts) publishes here.
//!
//! The notification engine subscribes with [`subscribe`]; each event comes
//! with `notify` (false for events that only go to the timeline, such as
//! tailed `terminal_session` lines). Events raised by a tab carry the tab in
//! `tab_id`, encoded with [`tab_uuid`] (decode with [`tab_from_uuid`]).

use std::collections::VecDeque;
use std::rc::Rc;

use chau7_next_core::ai::event::AiEvent;
use chau7_next_core::escape_sanitizer;
use gpui::{App, Global};
use uuid::Uuid;

use crate::tab_bar::TabId;

/// Events kept for the timeline (`recentEvents`).
pub const MAX_RECENT_EVENTS: usize = 200;

/// The `tab_id` of events raised by tab `tab`: the notification engine's
/// encoding (`notifications::tab_resolver::tab_uuid`), so it routes them
/// back to the tab.
pub fn tab_uuid(tab: TabId) -> Uuid {
    chau7_next_core::notifications::tab_resolver::tab_uuid(tab)
}

/// The tab of an event's `tab_id`, when it was set by [`tab_uuid`].
#[allow(dead_code)]
pub fn tab_from_uuid(id: Uuid) -> Option<TabId> {
    chau7_next_core::notifications::tab_resolver::tab_id_from_uuid(id)
}

type Sink = Rc<dyn Fn(&AiEvent, bool, &mut App)>;

#[derive(Default)]
struct Sinks(Vec<Sink>);
impl Global for Sinks {}

/// The last events, newest last.
#[derive(Default)]
pub struct RecentEvents(pub VecDeque<AiEvent>);
impl Global for RecentEvents {}

/// Receive every published event (notification engine, event timeline).
pub fn subscribe(cx: &mut App, sink: impl Fn(&AiEvent, bool, &mut App) + 'static) {
    cx.default_global::<Sinks>().0.push(Rc::new(sink));
}

/// Publish one event: sanitize its message, log it, keep it in
/// [`RecentEvents`] and hand it to the subscribers.
pub fn publish(mut event: AiEvent, notify: bool, cx: &mut App) {
    event.message = escape_sanitizer::sanitize_for_logging(
        &event.message,
        escape_sanitizer::DEFAULT_LOG_MAX_LENGTH,
    );
    if matches!(
        event.event_type.as_str(),
        "process_started" | "process_ended"
    ) {
        log::trace!(
            "Recorded event: type={} tool={} message=\"{}\"",
            event.event_type,
            event.tool,
            event.message
        );
    } else {
        log::info!(
            "Recorded event: type={} tool={} message=\"{}\"",
            event.event_type,
            event.tool,
            event.message
        );
    }
    {
        let recent = &mut cx.default_global::<RecentEvents>().0;
        recent.push_back(event.clone());
        while recent.len() > MAX_RECENT_EVENTS {
            recent.pop_front();
        }
    }
    let sinks: Vec<Sink> = cx.default_global::<Sinks>().0.clone();
    for sink in sinks {
        sink(&event, notify, cx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tab_ids_round_trip() {
        let id = tab_uuid(42);
        assert_eq!(tab_from_uuid(id), Some(42));
        assert_eq!(tab_from_uuid(Uuid::new_v4()), None);
        // Same encoding as the notification engine, which routes by it.
        assert_eq!(
            id,
            chau7_next_core::notifications::tab_resolver::tab_uuid(42)
        );
    }
}

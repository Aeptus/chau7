//! One app deadline for terminal housekeeping, retaining sessions weakly.
use super::TerminalSession;
use chau7_next_core::work_profiler::{self, Key, Queue};
use gpui::{App, Global, WeakEntity};
use std::time::Duration;

#[derive(Default)]
struct Scheduler {
    sessions: Vec<WeakEntity<TerminalSession>>,
    running: bool,
    #[cfg(test)]
    batches: usize,
}
impl Global for Scheduler {}

pub(super) fn register(session: WeakEntity<TerminalSession>, cx: &mut App) {
    if !cx.has_global::<Scheduler>() {
        cx.set_global(Scheduler::default());
    }
    let state = cx.global_mut::<Scheduler>();
    state.sessions.push(session);
    if state.running {
        return;
    }
    state.running = true;
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            if !cx.update(tick_all) {
                break;
            }
        }
    })
    .detach();
}

fn tick_all(cx: &mut App) -> bool {
    let mut sessions = std::mem::take(&mut cx.global_mut::<Scheduler>().sessions);
    let mut wake =
        work_profiler::begin(Key::wakeup("session_maintenance_timer", "app", Queue::Main));
    wake.items(sessions.len());
    sessions.retain(|session| session.update(cx, |session, cx| session.tick(cx)).is_ok());
    let state = cx.global_mut::<Scheduler>();
    // An update can register a new terminal. Keep those admissions too.
    sessions.append(&mut state.sessions);
    state.sessions = sessions;
    state.running = !state.sessions.is_empty();
    #[cfg(test)]
    {
        state.batches += 1;
    }
    state.running
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{settings::Settings, workspace::AppData};
    use chau7_next_core::data_root::DataRoot;
    use chau7_terminal::Chau7Terminal;
    use gpui::{AppContext, TestAppContext};

    #[gpui::test]
    fn one_timer_serves_surviving_sessions_and_parks_until_restarted(cx: &mut TestAppContext) {
        let home = std::env::temp_dir().join(format!("chau7-shared-tick-{}", uuid::Uuid::new_v4()));
        cx.on_quit({
            let home = home.clone();
            move || {
                let _ = std::fs::remove_dir_all(home);
            }
        });
        cx.update(|cx| {
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(DataRoot::with_home(home, true)));
        });
        let mut create = || {
            cx.new(|cx| {
                TerminalSession::from_terminal_manually_driven(
                    Chau7Terminal::new_headless(20, 4).unwrap(),
                    None,
                    cx,
                )
            })
        };
        let first = create();
        let second = create();
        cx.executor().run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.executor().run_until_parked();
        cx.update(|cx| {
            assert_eq!(cx.global::<Scheduler>().batches, 1);
            assert_eq!(first.read(cx).maintenance_ticks, 1);
            assert_eq!(second.read(cx).maintenance_ticks, 1);
        });
        drop(first);
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.executor().run_until_parked();
        cx.update(|cx| {
            assert_eq!(cx.global::<Scheduler>().sessions.len(), 1);
            assert_eq!(second.read(cx).maintenance_ticks, 2);
        });
        drop(second);
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.executor().run_until_parked();
        cx.update(|cx| {
            assert!(!cx.global::<Scheduler>().running);
            assert!(cx.global::<Scheduler>().sessions.is_empty());
            assert_eq!(cx.global::<Scheduler>().batches, 3);
        });
        cx.executor().advance_clock(Duration::from_secs(5));
        cx.executor().run_until_parked();
        cx.update(|cx| assert_eq!(cx.global::<Scheduler>().batches, 3));
        let restarted = cx.new(|cx| {
            TerminalSession::from_terminal_manually_driven(
                Chau7Terminal::new_headless(20, 4).unwrap(),
                None,
                cx,
            )
        });
        cx.executor().run_until_parked();
        cx.executor().advance_clock(Duration::from_secs(1));
        cx.executor().run_until_parked();
        cx.update(|cx| {
            assert_eq!(cx.global::<Scheduler>().batches, 4);
            assert_eq!(restarted.read(cx).maintenance_ticks, 1);
        });
    }
}

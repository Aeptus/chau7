//! Accepted reads belong to the background executor before a UI observer is queued.
use futures::channel::oneshot;
use gpui::App;
use std::future::Future;

/// Dropping the publication receiver never cancels an accepted read. Its guard
/// is released by real completion/drop on the background executor, so quit can
/// drain reads while the foreground thread is blocked and cannot publish UI.
pub(super) fn background_observation<R: Send + 'static>(
    cx: &App,
    observation: impl Future<Output = R> + Send + 'static,
) -> oneshot::Receiver<R> {
    let (publish, observed) = oneshot::channel();
    cx.background_executor()
        .spawn(async move {
            let result = observation.await;
            let _ = publish.send(result);
        })
        .detach();
    observed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::cache::Cache;
    use std::{
        cell::Cell,
        rc::Rc,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        thread,
    };

    #[gpui::test]
    fn admitted_read_drains_without_polling_its_foreground_observer(cx: &mut gpui::TestAppContext) {
        cx.background_executor.allow_parking();
        let cache = Arc::new(Cache::<(), u64>::new());
        let (_, ticket) = cache.begin(());
        let published = Rc::new(Cell::new(false));
        let ui_published = published.clone();
        let worker_finished = Arc::new(AtomicBool::new(false));
        let finished = worker_finished.clone();
        cx.update(|app| {
            let observed = background_observation(app, async move {
                finished.store(true, Ordering::Release);
                ticket.unwrap().apply(Ok(42));
            });
            app.spawn(async move |_| {
                if observed.await.is_ok() {
                    ui_published.set(true);
                }
            })
            .detach();
            let drain = cache.stop();
            let (done, drained) = oneshot::channel();
            let drainer = thread::spawn(move || {
                drain.finish();
                done.send(()).unwrap();
            });
            // The real native completion policy uses this same foreground
            // block. A queued UI observer cannot start a reader during it.
            app.foreground_executor().block_on(drained).unwrap();
            drainer.join().unwrap();
        });
        assert!(worker_finished.load(Ordering::Acquire));
        assert!(!published.get());
        assert_eq!(cache.diagnostics()["activity"]["in_flight"], 0);
        assert!(cache.begin(()).1.is_none(), "closed admission reopened");
    }

    #[gpui::test]
    fn held_read_retains_its_guard_when_ui_publication_is_dropped(cx: &mut gpui::TestAppContext) {
        cx.background_executor.allow_parking();
        let path = std::env::temp_dir().join(format!("chau7-read-drain-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"owned read").unwrap();
        let input = path.clone();
        let cache = Arc::new(Cache::<(), usize>::new());
        let (_, ticket) = cache.begin(());
        let (start, started) = oneshot::channel();
        let (release, held) = oneshot::channel();
        let actual_read = Arc::new(AtomicBool::new(false));
        let read_completed = actual_read.clone();
        let observed = cx.update(|app| {
            background_observation(app, async move {
                start.send(()).unwrap();
                held.await.unwrap();
                let bytes = std::fs::read(input).unwrap();
                read_completed.store(true, Ordering::Release);
                ticket.unwrap().apply(Ok(bytes.len()));
            })
        });
        cx.update(|app| app.foreground_executor().block_on(started))
            .unwrap();
        drop(observed);
        let drain = cache.stop();
        assert!(cache.begin(()).1.is_none());
        let (entered, waiting) = std::sync::mpsc::channel();
        let (done, drained) = oneshot::channel();
        let completed = Arc::new(AtomicBool::new(false));
        let worker_completed = completed.clone();
        let drainer = thread::spawn(move || {
            entered.send(()).unwrap();
            drain.finish();
            worker_completed.store(true, Ordering::Release);
            done.send(()).unwrap();
        });
        waiting
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        assert!(!completed.load(Ordering::Acquire));
        assert_eq!(cache.diagnostics()["activity"]["in_flight"], 1);
        release.send(()).unwrap();
        cx.update(|app| app.foreground_executor().block_on(drained))
            .unwrap();
        drainer.join().unwrap();
        assert!(actual_read.load(Ordering::Acquire));
        assert_eq!(cache.diagnostics()["activity"]["in_flight"], 0);
        let (snapshot, next) = cache.begin(());
        assert!(next.is_none());
        assert!(
            snapshot.value.is_none(),
            "late read published into a closed cache"
        );
        assert!(!snapshot.pending);
        std::fs::remove_file(path).unwrap();
    }

    #[gpui::test]
    fn unwinding_background_read_releases_guard_before_failed_publication(
        cx: &mut gpui::TestAppContext,
    ) {
        use futures::FutureExt;
        use std::panic::AssertUnwindSafe;
        cx.background_executor.allow_parking();
        let cache = Arc::new(Cache::<(), u64>::new());
        let (_, ticket) = cache.begin(());
        let observed = cx.update(|app| {
            background_observation(
                app,
                AssertUnwindSafe(async move {
                    let _ticket = ticket.unwrap();
                    panic!("owned background read failure");
                })
                .catch_unwind(),
            )
        });
        let failed = cx
            .update(|app| app.foreground_executor().block_on(observed))
            .unwrap();
        assert!(failed.is_err(), "the injected panic was not observed");
        // Catching the panic belongs only to this fixture; production never
        // turns a worker panic into a successful observation.
        assert_eq!(cache.diagnostics()["activity"]["in_flight"], 0);
        let snapshot = cache.begin(()).0;
        assert!(snapshot.error);
        assert!(!snapshot.pending);
        assert!(snapshot.value.is_none());
        cache.stop().finish();
    }

    #[test]
    fn all_ui_observed_read_sites_admit_background_work_first() {
        for (source, call, boundaries) in [
            (
                include_str!("../telemetry.rs"),
                "admission::background_observation(",
                &[
                    "let initializing =",
                    "pub fn hover_summary",
                    "fn analytics_data",
                ][..],
            ),
            (
                include_str!("../usage.rs"),
                "super::admission::background_observation(",
                &[
                    "pub fn refresh(",
                    "pub fn set_capture",
                    "pub fn refresh_latency(",
                    "pub fn preview_retention",
                    "pub fn compact_confirmed",
                ][..],
            ),
        ] {
            assert_eq!(source.matches(call).count(), boundaries.len());
            for boundary in boundaries {
                let source = &source[source.find(boundary).unwrap()..];
                assert!(source.find(call).unwrap() < source.find("cx.spawn(").unwrap());
            }
        }
    }
}

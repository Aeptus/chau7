//! Public native quit policy exercised through the actual vendored GPUI dependency.
use std::{cell::Cell, rc::Rc, time::Duration};

#[gpui::test]
fn shutdown_timeout_preserves_upstream_default(cx: &mut gpui::TestAppContext) {
    cx.update(|cx| {
        assert_eq!(cx.shutdown_timeout(), Some(gpui::SHUTDOWN_TIMEOUT));
        assert_eq!(gpui::SHUTDOWN_TIMEOUT, Duration::from_millis(200));
        cx.set_shutdown_timeout(Some(Duration::ZERO));
        assert_eq!(cx.shutdown_timeout(), Some(Duration::ZERO));
    });
}

#[gpui::test]
fn shutdown_completion_policy_waits_for_observers(cx: &mut gpui::TestAppContext) {
    let completed = Rc::new(Cell::new(false));
    cx.update(|cx| {
        cx.set_shutdown_timeout(None);
        assert_eq!(cx.shutdown_timeout(), None);
        let completed = completed.clone();
        cx.on_app_quit(move |cx| {
            let timer = cx
                .background_executor()
                .timer(gpui::SHUTDOWN_TIMEOUT + Duration::from_millis(100));
            let completed = completed.clone();
            async move {
                timer.await;
                completed.set(true);
            }
        })
        .detach();
        cx.shutdown();
    });
    assert!(
        completed.get(),
        "quit returned before the slow observer completed"
    );
}

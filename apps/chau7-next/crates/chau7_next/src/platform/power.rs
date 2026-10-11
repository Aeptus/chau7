//! App Nap. macOS slows down apps it thinks are idle, which delays the first
//! keystroke after a pause. A terminal opts out for as long as it runs
//! (`AppDelegate.applicationDidFinishLaunching`: `beginActivity` with
//! `userInitiatedAllowingIdleSystemSleep` and `latencyCritical`).
//!
//! Main thread only. Other OSes have no App Nap: the calls do nothing.

/// Start the latency critical activity; it lasts until [`end_latency_critical`]
/// or the end of the process. Calling it twice keeps the first one.
pub fn begin_latency_critical(reason: &str) -> bool {
    imp::begin(reason)
}

/// End the activity started by [`begin_latency_critical`].
pub fn end_latency_critical() {
    imp::end()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::cell::RefCell;

    use objc2::rc::Retained;
    use objc2::runtime::ProtocolObject;
    use objc2_foundation::{NSActivityOptions, NSObjectProtocol, NSProcessInfo, NSString};

    thread_local! {
        static ACTIVITY: RefCell<Option<Retained<ProtocolObject<dyn NSObjectProtocol>>>> =
            const { RefCell::new(None) };
    }

    pub fn begin(reason: &str) -> bool {
        ACTIVITY.with(|slot| {
            let mut slot = slot.borrow_mut();
            if slot.is_some() {
                return true;
            }
            let options = NSActivityOptions::UserInitiatedAllowingIdleSystemSleep
                | NSActivityOptions::LatencyCritical;
            let reason = NSString::from_str(reason);
            *slot = Some(
                NSProcessInfo::processInfo().beginActivityWithOptions_reason(options, &reason),
            );
            true
        })
    }

    pub fn end() {
        ACTIVITY.with(|slot| {
            if let Some(activity) = slot.borrow_mut().take() {
                // SAFETY: the object came from `beginActivityWithOptions:reason:`.
                unsafe { NSProcessInfo::processInfo().endActivity(&activity) };
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn begin(_reason: &str) -> bool {
        false
    }

    pub fn end() {}
}

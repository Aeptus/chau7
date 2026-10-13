//! Bounded termination for helper processes owned by this app.
//!
//! Signals always target the `Child` PID we spawned. This module never signals
//! a process group or discovers/signals unrelated PIDs.

use std::process::Child;
use std::thread;
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(25);

#[cfg(not(unix))]
const REMOTE_NON_UNIX_GRACE: Duration = Duration::from_millis(1500);

#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Signal {
    Term,
    Interrupt,
}

#[cfg(unix)]
impl Signal {
    fn as_raw(self) -> libc::c_int {
        match self {
            Self::Term => libc::SIGTERM,
            Self::Interrupt => libc::SIGINT,
        }
    }
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GracefulStage {
    signal: Signal,
    grace: Duration,
}

#[cfg(unix)]
const GRACEFUL_STAGES: [GracefulStage; 2] = [
    GracefulStage {
        signal: Signal::Term,
        grace: Duration::from_secs(1),
    },
    GracefulStage {
        signal: Signal::Interrupt,
        grace: Duration::from_millis(500),
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RemoteStopStart {
    AlreadyExited,
    NeedsGrace,
    #[cfg(unix)]
    TermSent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WaitOutcome {
    Exited,
    TimedOut,
    Unknown,
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SignalOutcome {
    Sent,
    Exited,
    Failed,
}

/// Proxy shutdown remains synchronous, as it was before this helper existed.
pub(crate) fn terminate_proxy_child(mut child: Child) {
    #[cfg(unix)]
    if terminate_unix(&mut child) {
        return;
    }
    kill_and_reap(&mut child);
}

/// Send the remote helper's initial SIGTERM before creating its reaper thread.
/// The send is nonblocking; all waits, escalation, and reaping stay off the UI.
pub(crate) fn begin_remote_stop(child: &mut Child) -> RemoteStopStart {
    match child.try_wait() {
        Ok(Some(_)) => RemoteStopStart::AlreadyExited,
        Ok(None) => {
            #[cfg(unix)]
            {
                match send_signal_if_running(child, Signal::Term) {
                    SignalOutcome::Sent => RemoteStopStart::TermSent,
                    SignalOutcome::Exited => RemoteStopStart::AlreadyExited,
                    SignalOutcome::Failed => RemoteStopStart::NeedsGrace,
                }
            }
            #[cfg(not(unix))]
            {
                RemoteStopStart::NeedsGrace
            }
        }
        Err(error) => {
            log::warn!("Cannot inspect remote helper before termination: {error}");
            RemoteStopStart::NeedsGrace
        }
    }
}

/// Continue remote escalation and reaping on its existing background thread.
pub(crate) fn finish_remote_stop(mut child: Child, start: RemoteStopStart) {
    #[cfg(unix)]
    {
        let graceful_finished = match start {
            RemoteStopStart::AlreadyExited => true,
            RemoteStopStart::NeedsGrace => terminate_unix(&mut child),
            RemoteStopStart::TermSent => terminate_after_term(&mut child),
        };
        if graceful_finished {
            return;
        }
    }
    #[cfg(not(unix))]
    {
        if start == RemoteStopStart::AlreadyExited {
            return;
        }
        if wait_for_exit(&mut child, REMOTE_NON_UNIX_GRACE) == WaitOutcome::Exited {
            return;
        }
    }
    kill_and_reap(&mut child);
}

/// On non-Unix targets the caller's `Child` handle is the only termination
/// authority. Unix callers run the shared TERM/INT stages before this fallback.
fn kill_and_reap(child: &mut Child) {
    if let Err(error) = child.kill() {
        log::warn!("Failed to kill owned helper process: {error}");
    }
    if let Err(error) = child.wait() {
        log::warn!("Failed to reap owned helper process: {error}");
    }
}

#[cfg(unix)]
fn terminate_unix(child: &mut Child) -> bool {
    match child.try_wait() {
        Ok(Some(_)) => return true,
        Ok(None) => {}
        Err(error) => {
            log::warn!("Cannot inspect owned helper before termination: {error}");
            return false;
        }
    }

    for stage in GRACEFUL_STAGES {
        match send_signal_if_running(child, stage.signal) {
            SignalOutcome::Sent => {}
            SignalOutcome::Exited => return true,
            SignalOutcome::Failed => return false,
        }
        match wait_for_exit(child, stage.grace) {
            WaitOutcome::Exited => return true,
            WaitOutcome::TimedOut => {}
            WaitOutcome::Unknown => return false,
        }
    }
    false
}

#[cfg(unix)]
fn terminate_after_term(child: &mut Child) -> bool {
    match wait_for_exit(child, GRACEFUL_STAGES[0].grace) {
        WaitOutcome::Exited => return true,
        WaitOutcome::Unknown => return false,
        WaitOutcome::TimedOut => {}
    }
    match send_signal_if_running(child, GRACEFUL_STAGES[1].signal) {
        SignalOutcome::Sent => {}
        SignalOutcome::Exited => return true,
        SignalOutcome::Failed => return false,
    }
    match wait_for_exit(child, GRACEFUL_STAGES[1].grace) {
        WaitOutcome::Exited => true,
        WaitOutcome::TimedOut | WaitOutcome::Unknown => false,
    }
}

/// Check the owned Child again before every Unix signal. An uncertain
/// `try_wait` result suppresses SIGINT and uses the owned Child kill fallback.
#[cfg(unix)]
fn send_signal_if_running(child: &mut Child, signal: Signal) -> SignalOutcome {
    match child.try_wait() {
        Ok(Some(_)) => SignalOutcome::Exited,
        Ok(None) => {
            // SAFETY: this is the PID of the still-owned `Child` we spawned.
            let result = unsafe { libc::kill(child.id() as libc::pid_t, signal.as_raw()) };
            if result == 0 {
                SignalOutcome::Sent
            } else {
                let error = std::io::Error::last_os_error();
                log::warn!(
                    "Failed to send {signal:?} to owned helper process {}: {error}",
                    child.id()
                );
                SignalOutcome::Failed
            }
        }
        Err(error) => {
            log::warn!("Cannot inspect owned helper before {signal:?}: {error}");
            SignalOutcome::Failed
        }
    }
}

fn wait_for_exit(child: &mut Child, grace: Duration) -> WaitOutcome {
    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return WaitOutcome::Exited,
            Ok(None) if Instant::now() >= deadline => return WaitOutcome::TimedOut,
            Ok(None) => thread::sleep(POLL_INTERVAL),
            Err(error) => {
                log::warn!("Cannot inspect owned helper while stopping it: {error}");
                return WaitOutcome::Unknown;
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::{GRACEFUL_STAGES, GracefulStage, Signal};
    use std::time::Duration;

    #[test]
    fn graceful_schedule_matches_managed_process_termination() {
        assert_eq!(
            GRACEFUL_STAGES,
            [
                GracefulStage {
                    signal: Signal::Term,
                    grace: Duration::from_secs(1),
                },
                GracefulStage {
                    signal: Signal::Interrupt,
                    grace: Duration::from_millis(500),
                },
            ]
        );
    }
}

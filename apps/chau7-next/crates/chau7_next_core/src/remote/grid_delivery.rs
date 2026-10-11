//! Current Swift delivery guard for asynchronous viewport captures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GridCaptureScope {
    pub epoch: u64,
    pub tab: u32,
    pub session: u64,
}

pub fn should_deliver(
    captured: GridCaptureScope,
    current_epoch: u64,
    selected_tab: Option<u32>,
    current_session: Option<u64>,
    connected: bool,
    streams_terminal: bool,
) -> bool {
    connected
        && streams_terminal
        && captured.epoch == current_epoch
        && Some(captured.tab) == selected_tab
        && Some(captured.session) == current_session
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_connections_tabs_and_pane_sessions_cannot_receive_stale_frames() {
        let scope = GridCaptureScope {
            epoch: 1,
            tab: 2,
            session: 3,
        };
        assert!(should_deliver(scope, 1, Some(2), Some(3), true, true));
        assert!(!should_deliver(scope, 2, Some(2), Some(3), true, true));
        assert!(!should_deliver(scope, 1, Some(9), Some(3), true, true));
        assert!(!should_deliver(scope, 1, Some(2), Some(9), true, true));
        assert!(!should_deliver(scope, 1, Some(2), Some(3), false, true));
        assert!(!should_deliver(scope, 1, Some(2), Some(3), true, false));
        assert!(!should_deliver(scope, 1, None, Some(3), true, true));
        assert!(!should_deliver(scope, 1, Some(2), None, true, true));
    }
}

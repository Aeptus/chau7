//! Restore background work prepares tab identity without constructing hidden PTYs.
use super::*;
use chau7_next_core::session_restore::lifecycle::{DeferredDecision, deferred_decision};

#[derive(Default)]
pub(super) struct RestoreLifecycle {
    pub startup: bool,
    pub pending_identity: Vec<TabId>,
    pub selected: Option<TabId>,
    pub last_selection: Option<Instant>,
    task: Option<Task<()>>,
}
impl Workspace {
    pub(super) fn record_restore_selection(&mut self) {
        let selected = self.state.selected();
        if self.restore_lifecycle.selected != selected {
            self.restore_lifecycle.selected = selected;
            self.restore_lifecycle.last_selection = Some(Instant::now());
        }
        if let Some(selected) = selected {
            self.restore_lifecycle
                .pending_identity
                .retain(|id| *id != selected);
        }
    }
    pub(super) fn start_deferred_identity_restore(&mut self, cx: &mut Context<Self>) {
        if self.restore_lifecycle.pending_identity.is_empty() {
            return;
        }
        self.restore_lifecycle.task = Some(cx.spawn(async move |this, cx| {
            let mut delay = Duration::from_millis(10);
            loop {
                cx.background_executor().timer(delay).await;
                let Ok(next) = this.update(cx, |this, cx| {
                    this.restore_lifecycle
                        .pending_identity
                        .retain(|id| this.entries.contains_key(id));
                    let order: Vec<_> = this.state.tabs().iter().map(|t| t.id).collect();
                    let elapsed = this.restore_lifecycle.last_selection.map(|at| at.elapsed());
                    match deferred_decision(
                        &this.restore_lifecycle.pending_identity,
                        &order,
                        this.state.selected(),
                        elapsed,
                    ) {
                        DeferredDecision::Idle => None,
                        DeferredDecision::Wait(delay) => Some(delay),
                        DeferredDecision::Restore(id, _) => {
                            // The full SavedTab stays parked in PaneTree. Only cached
                            // directory/root identity is hydrated; no terminal, editor,
                            // transcript lookup or protected path I/O runs here.
                            if let Some(entry) = this.entries.get(&id) {
                                let directory = entry.panes.read(cx).cwd(cx);
                                this.state.setup_repo_group_in_directory(
                                    id,
                                    directory.as_deref(),
                                    &this.known_repo_roots,
                                );
                            }
                            this.restore_lifecycle.pending_identity.retain(|p| *p != id);
                            cx.notify();
                            Some(Duration::from_millis(10))
                        }
                    }
                }) else {
                    break;
                };
                match next {
                    Some(next) => delay = next,
                    None => break,
                }
            }
        }));
    }
}

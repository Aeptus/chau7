//! Restore background work prepares tab identity without constructing hidden PTYs.
use super::*;
use chau7_next_core::session_restore::lifecycle::{
    DeferredDecision, REACTIVATION_COALESCING_DELAY, RevealTrigger, SurfaceEvents,
    deferred_decision, retain_snapshot,
};

enum IdentityStep {
    Idle,
    Wait(Duration),
    Prepare(TabId, Option<futures::channel::oneshot::Receiver<bool>>),
}

#[derive(Default)]
pub(super) struct RestoreLifecycle {
    pub startup: bool,
    pub pending_identity: Vec<TabId>,
    pub selected: Option<TabId>,
    pub last_selection: Option<Instant>,
    task: Option<Task<()>>,
    surface_events: SurfaceEvents,
    surface_task: Option<Task<()>>,
}
impl Workspace {
    /// All split panes follow real tab/window ownership, including stationary
    /// surfaces. Far CPU frame caches can be reclaimed without touching history.
    pub(super) fn sync_restore_surfaces(&self, window: &Window, cx: &mut App) {
        let selected = self.state.selected();
        let index = selected.and_then(|id| self.state.index_of(id));
        for (position, meta) in self.state.tabs().iter().enumerate() {
            let Some(entry) = self.entries.get(&meta.id) else {
                continue;
            };
            entry.panes.read(cx).set_restore_surface(
                selected == Some(meta.id),
                window.is_visible(),
                cx,
            );
            let preview = entry.panes.read(cx).is_deferred();
            let retain = index.is_some_and(|index| retain_snapshot(position, index, preview));
            if !retain {
                for view in entry.panes.read(cx).views() {
                    if view.read(cx).overlays.cache_bytes() > 0 {
                        view.update(cx, |view, cx| {
                            view.overlays.reclaim_cache(cx);
                        });
                    }
                }
            }
        }
    }
    pub(super) fn reveal_selected_surface(
        &self,
        trigger: RevealTrigger,
        window: &Window,
        cx: &mut App,
    ) {
        if !window.is_visible() {
            return;
        }
        let Some(panes) = self.selected_panes() else {
            return;
        };
        for view in panes.read(cx).views() {
            view.update(cx, |view, cx| view.reveal_surface(trigger, window, cx));
        }
    }
    pub(super) fn queue_surface_reactivation(
        &mut self,
        events: SurfaceEvents,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.restore_lifecycle.surface_events.merge(events);
        if self.restore_lifecycle.surface_task.is_some() {
            return;
        }
        self.restore_lifecycle.surface_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(REACTIVATION_COALESCING_DELAY)
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                let events = std::mem::take(&mut this.restore_lifecycle.surface_events);
                this.restore_lifecycle.surface_task = None;
                this.sync_restore_surfaces(window, cx);
                let terminal = this
                    .selected_panes()
                    .is_some_and(|panes| panes.read(cx).has_terminal());
                // GPUI is_visible includes occlusion, minimization and sleeping displays.
                if events.requests_reveal(
                    terminal,
                    window.is_visible(),
                    !window.is_visible(),
                    window.is_visible(),
                ) {
                    this.reveal_selected_surface(RevealTrigger::Reactivation, window, cx);
                    cx.notify();
                }
            });
        }));
    }

    pub(super) fn record_restore_selection(&mut self, cx: &App) {
        let selected = self.state.selected();
        if self.restore_lifecycle.selected != selected {
            self.restore_lifecycle.selected = selected;
            self.restore_lifecycle.last_selection = Some(cx.background_executor().now());
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
                    // Use the timer dispatcher's monotonic clock for both the
                    // selection stamp and its deadline, including virtual time.
                    let now = cx.background_executor().now();
                    let elapsed = this
                        .restore_lifecycle
                        .last_selection
                        .map(|at| now.saturating_duration_since(at));
                    match deferred_decision(
                        &this.restore_lifecycle.pending_identity,
                        &order,
                        this.state.selected(),
                        elapsed,
                    ) {
                        DeferredDecision::Idle => IdentityStep::Idle,
                        DeferredDecision::Wait(delay) => IdentityStep::Wait(delay),
                        DeferredDecision::Restore(id, _) => {
                            let prepared = this.entries.get(&id).and_then(|entry| {
                                entry
                                    .panes
                                    .update(cx, |panes, cx| panes.hydrate_deferred_identity(cx))
                            });
                            IdentityStep::Prepare(id, prepared)
                        }
                    }
                }) else {
                    break;
                };
                match next {
                    IdentityStep::Wait(next) => delay = next,
                    IdentityStep::Idle => break,
                    IdentityStep::Prepare(id, prepared) => {
                        let admitted = match prepared {
                            Some(prepared) => prepared.await.unwrap_or(false),
                            None => true, // Already selected/closed/full activation owns it.
                        };
                        let _ = this.update(cx, |this, cx| {
                            if admitted {
                                this.restore_lifecycle
                                    .pending_identity
                                    .retain(|pending| *pending != id);
                            }
                            if let Some(entry) = this.entries.get(&id) {
                                let directory = entry.panes.read(cx).cwd(cx);
                                this.state.setup_repo_group_in_directory(
                                    id,
                                    directory.as_deref(),
                                    &this.known_repo_roots,
                                );
                            }
                            cx.notify();
                        });
                        delay = Duration::from_millis(if admitted { 10 } else { 50 });
                    }
                }
            }
        }));
    }
}

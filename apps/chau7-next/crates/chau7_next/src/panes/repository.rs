//! Current Swift repository pane: all Git subprocesses and draft IO run off the UI thread.
use super::{SidePaneEvent, header, header_button};
use crate::{theme::Chrome, workspace::AppData};
use chau7_next_core::{
    command_block::CommandBlock,
    dashboard::FilesTracker,
    repository_pane::{self as repo, Operation, Snapshot},
    runtime::session::RuntimeSession,
};
use gpui::{
    App, ClipboardItem, Context, Entity, EventEmitter, FocusHandle, Focusable, Render,
    Subscription, Task, Window, actions, div, prelude::*, px,
};
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};
use std::{path::PathBuf, sync::Arc, time::Duration};

actions!(chau7_repository, [CommitChanges]);
const CONTEXT: &str = "Chau7Repository";
pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([gpui::KeyBinding::new(
        if cfg!(target_os = "macos") {
            "cmd-enter"
        } else {
            "ctrl-enter"
        },
        CommitChanges,
        Some(CONTEXT),
    )]);
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Section {
    Session,
    Git,
    Branches,
    History,
    Stashes,
}
type SessionProvider = Box<
    dyn Fn(
        &App,
    ) -> (
        Option<Arc<RuntimeSession>>,
        Vec<CommandBlock>,
        Option<PathBuf>,
    ),
>;

pub struct RepositoryPane {
    directory: Option<PathBuf>,
    snapshot: Snapshot,
    section: Section,
    error: Option<String>,
    busy: bool,
    generation: u64,
    draft: Entity<TextareaState>,
    search: Entity<InputState>,
    branch: Entity<InputState>,
    stash_message: Entity<InputState>,
    amend: bool,
    limit: usize,
    tracker: FilesTracker,
    tracked_session: Option<String>,
    session: Option<Arc<RuntimeSession>>,
    provider: Option<SessionProvider>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
    task: Option<Task<()>>,
    draft_writer: repo::DraftWriter,
    draft_revision: u64,
    _refresh_task: Task<()>,
    programmatic: bool,
}
impl EventEmitter<SidePaneEvent> for RepositoryPane {}
impl Focusable for RepositoryPane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}
impl RepositoryPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let draft = cx.new(|cx| TextareaState::new(window, cx));
        let search =
            cx.new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Search commits")));
        let branch = cx
            .new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("New branch name")));
        let stash_message = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Stash message (optional)"))
        });
        let subscriptions = vec![
            cx.subscribe(&draft, |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && !this.programmatic {
                    this.draft_revision += 1;
                    this.persist_draft(cx);
                    cx.notify();
                }
            }),
            cx.subscribe(&search, |_, _, _: &InputEvent, cx| cx.notify()),
        ];
        let timer = crate::observability::register_timer(
            cx,
            &format!("repository.pane.{}", cx.entity_id()),
            "Repository pane refresh",
            "repository",
            2000,
        );
        let refresh_task = cx.spawn_in(window, async move |this, cx| {
            let _timer = timer;
            loop {
                cx.background_executor().timer(Duration::from_secs(2)).await;
                let result = this.update_in(cx, |this, window, cx| {
                    this.update_session(window, cx);
                    this.refresh(window, cx);
                });
                if result.is_err() {
                    break;
                }
            }
        });
        Self {
            directory: None,
            snapshot: Snapshot::default(),
            section: Section::Session,
            error: None,
            busy: false,
            generation: 0,
            draft,
            search,
            branch,
            stash_message,
            amend: false,
            limit: 50,
            tracker: FilesTracker::default(),
            tracked_session: None,
            session: None,
            provider: None,
            focus: cx.focus_handle(),
            _subscriptions: subscriptions,
            task: None,
            draft_writer: repo::DraftWriter::new(cx.global::<AppData>().root.clone()),
            draft_revision: 0,
            _refresh_task: refresh_task,
            programmatic: false,
        }
    }
    pub fn set_session_provider(
        &mut self,
        provider: impl Fn(
            &App,
        ) -> (
            Option<Arc<RuntimeSession>>,
            Vec<CommandBlock>,
            Option<PathBuf>,
        ) + 'static,
    ) {
        self.provider = Some(Box::new(provider));
    }
    pub fn directory(&self) -> Option<&PathBuf> {
        self.directory.as_ref()
    }
    pub fn load(&mut self, directory: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        if self.directory.as_ref() == Some(&directory) {
            return;
        }
        self.generation += 1;
        self.task = None;
        self.busy = false;
        self.limit = 50;
        self.snapshot = Snapshot::default();
        self.tracker = FilesTracker::default();
        self.tracked_session = None;
        self.directory = Some(directory.clone());
        let generation = self.generation;
        let revision = self.draft_revision;
        let root = cx.global::<AppData>().root.clone();
        let task = cx.background_spawn(async move { repo::load_draft(&root, &directory) });
        cx.spawn_in(window, async move |this, cx| {
            let message = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.generation == generation && this.draft_revision == revision {
                    this.programmatic = true;
                    this.draft
                        .update(cx, |d, cx| d.set_value(message, window, cx));
                    this.programmatic = false;
                    cx.notify();
                }
            });
        })
        .detach();
        self.update_session(window, cx);
        self.refresh(window, cx);
        cx.emit(SidePaneEvent::Changed);
    }
    fn persist_draft(&mut self, cx: &mut Context<Self>) {
        let Some(directory) = self.directory.clone() else {
            return;
        };
        let message = self.draft.read(cx).value().to_string();
        if let Err(error) = self.draft_writer.save(directory, message) {
            self.error = Some(error);
            cx.notify();
        }
    }
    fn update_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(provider) = self.provider.as_ref() else {
            return;
        };
        let (session, blocks, directory) = provider(cx);
        if let Some(directory) = directory.filter(|p| self.directory.as_ref() != Some(p)) {
            self.load(directory, window, cx);
            return;
        }
        let identity = session.as_ref().map(|s| s.id.clone());
        if identity != self.tracked_session {
            self.tracker = FilesTracker::default();
            self.tracked_session = identity;
        }
        let root = self
            .directory
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        self.tracker
            .update(session.as_ref().map(|s| &s.journal), &blocks, &root);
        self.session = session;
    }
    fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(error) = self.draft_writer.take_error() {
            self.error = Some(error);
        }
        if self.busy {
            return;
        }
        let Some(directory) = self.directory.clone() else {
            return;
        };
        if crate::protected_paths::should_skip(&directory) {
            self.error = Some(
                crate::l10n::tr("Allow protected folder access in Settings to use Git here.")
                    .to_string(),
            );
            cx.notify();
            return;
        }
        self.busy = true;
        let generation = self.generation;
        let limit = self.limit;
        let task = cx.background_spawn(async move { repo::snapshot(&directory, limit) });
        self.task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, _, cx| {
                if generation != this.generation {
                    return;
                }
                this.busy = false;
                match result {
                    Ok(snapshot) => {
                        this.snapshot = snapshot;
                    }
                    Err(error) => this.error = Some(error),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }
    fn perform(&mut self, operation: Operation, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(directory) = self.directory.clone() else {
            return;
        };
        if crate::protected_paths::should_skip(&directory) {
            self.error = Some(
                crate::l10n::tr("Allow protected folder access in Settings to use Git here.")
                    .to_string(),
            );
            cx.notify();
            return;
        }
        self.busy = true;
        self.error = None;
        let generation = self.generation;
        let committed = matches!(operation, Operation::Commit { .. });
        let pushed = matches!(operation, Operation::Push);
        let writer = self.draft_writer.clone();
        let task = cx.background_spawn(async move {
            if crate::protected_paths::should_skip(&directory) {
                return Err("Protected folder access changed".into());
            }
            repo::perform(&directory, &operation)?;
            if committed {
                writer.save(directory.clone(), String::new())?;
            }
            Ok(())
        });
        self.task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if generation != this.generation {
                    return;
                }
                this.busy = false;
                match result {
                    Ok(()) => {
                        if committed {
                            this.programmatic = true;
                            this.draft.update(cx, |d, cx| d.set_value("", window, cx));
                            this.programmatic = false;
                            this.amend = false;
                        }
                        if pushed {
                            this.tracker.clear_committed_files();
                        }
                        this.refresh(window, cx);
                    }
                    Err(error) => this.error = Some(error),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }
    fn commit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.perform(
            Operation::Commit {
                message: self.draft.read(cx).value().to_string(),
                amend: self.amend,
            },
            window,
            cx,
        );
    }
    fn file_row(
        &self,
        path: String,
        staged: bool,
        untracked: bool,
        conflict: bool,
        key: String,
        cx: &mut Context<Self>,
    ) -> gpui::Div {
        let chrome = Chrome::get(cx);
        let directory = self.directory.clone().unwrap_or_default();
        let diff_file = path.clone();
        let preview = directory.join(&path);
        let copy = preview.to_string_lossy().into_owned();
        let action = path.clone();
        let stat = self
            .snapshot
            .stats
            .get(&path)
            .map(|s| format!(" +{} -{}", s.added, s.deleted))
            .unwrap_or_default();
        let mut row = div()
            .flex()
            .items_center()
            .gap_1()
            .py_1()
            .text_size(px(11.))
            .child(
                header_button(format!("file-{key}"), format!("{path}{stat}"), chrome, true)
                    .flex_1()
                    .on_click(cx.listener(move |_, _, _, cx| {
                        cx.emit(SidePaneEvent::OpenDiff {
                            file: diff_file.clone(),
                            directory: directory.clone(),
                            staged,
                        })
                    })),
            )
            .child(
                header_button(
                    format!("preview-{key}"),
                    crate::l10n::tr("Preview"),
                    chrome,
                    true,
                )
                .on_click(cx.listener(move |_, _, _, cx| {
                    cx.emit(SidePaneEvent::PreviewFile(preview.clone()))
                })),
            )
            .child(
                header_button(format!("copy-{key}"), crate::l10n::tr("Copy"), chrome, true)
                    .on_click(cx.listener(move |_, _, _, cx| {
                        cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()))
                    })),
            );
        if conflict {
            let theirs = path;
            row = row
                .child(
                    header_button(
                        format!("ours-{key}"),
                        crate::l10n::tr("Ours"),
                        chrome,
                        !self.busy,
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.perform(
                            Operation::Resolve {
                                file: action.clone(),
                                ours: true,
                            },
                            window,
                            cx,
                        )
                    })),
                )
                .child(
                    header_button(
                        format!("theirs-{key}"),
                        crate::l10n::tr("Theirs"),
                        chrome,
                        !self.busy,
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.perform(
                            Operation::Resolve {
                                file: theirs.clone(),
                                ours: false,
                            },
                            window,
                            cx,
                        )
                    })),
                );
        } else {
            row = row.child(
                header_button(
                    format!("stage-{key}"),
                    crate::l10n::tr(if staged { "Unstage" } else { "Stage" }),
                    chrome,
                    !self.busy,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.perform(
                        if staged {
                            Operation::Unstage(vec![action.clone()])
                        } else {
                            Operation::Stage(vec![action.clone()])
                        },
                        window,
                        cx,
                    )
                })),
            );
        }
        let _ = untracked;
        row
    }
    fn changes(&self, session_only: Option<bool>, cx: &mut Context<Self>) -> gpui::Div {
        let chrome = Chrome::get(cx);
        let filter =
            |p: &String| session_only.is_none_or(|wanted| self.tracker.files.contains(p) == wanted);
        let mut body = div().flex().flex_col().gap_1();
        for (label, staged, files) in [
            ("Staged", true, &self.snapshot.status.staged),
            ("Modified", false, &self.snapshot.status.modified),
        ] {
            let rows: Vec<_> = files.iter().filter(|f| filter(&f.path)).collect();
            if !rows.is_empty() {
                body = body.child(
                    div()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr(label)),
                );
                for (i, f) in rows.into_iter().enumerate() {
                    body = body.child(self.file_row(
                        f.path.clone(),
                        staged,
                        false,
                        false,
                        format!("{label}-{i}-{:?}", session_only),
                        cx,
                    ));
                }
            }
        }
        for (label, conflict, files) in [
            ("Untracked", false, &self.snapshot.status.untracked),
            ("Conflicts", true, &self.snapshot.status.conflicted),
        ] {
            let rows: Vec<_> = files.iter().filter(|p| filter(p)).collect();
            if !rows.is_empty() {
                body = body.child(
                    div()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr(label)),
                );
                for (i, p) in rows.into_iter().enumerate() {
                    body = body.child(self.file_row(
                        p.clone(),
                        false,
                        !conflict,
                        conflict,
                        format!("{label}-{i}-{:?}", session_only),
                        cx,
                    ));
                }
            }
        }
        body
    }
    fn composer(&self, cx: &mut Context<Self>) -> gpui::Div {
        let chrome = Chrome::get(cx);
        div().flex().flex_col().gap_1().child(div().flex().gap_1().children(repo::PREFIXES.iter().map(|prefix|{let p=*prefix;header_button(format!("prefix-{p}"),p,chrome,true).on_click(cx.listener(move|this,_,window,cx|{let message=repo::apply_prefix(p,&this.draft.read(cx).value());this.draft.update(cx,|d,cx|d.set_value(message,window,cx));this.persist_draft(cx);} ))})))
  .child(Textarea::new(&self.draft).h(px(86.))).child(div().flex().gap_2().child(header_button("amend",if self.amend{"✓ Amend"}else{"Amend"},chrome,true).on_click(cx.listener(|this,_,_,cx|{this.amend = !this.amend;cx.notify();})))
  .child(header_button("commit","Commit (⌘↵)",chrome,!self.busy).on_click(cx.listener(|this,_,window,cx|this.commit(window,cx))))
  .child(header_button("ask-agent",crate::l10n::tr("Ask Agent"),chrome,self.session.is_some()).on_click(cx.listener(|_,_,_,cx|cx.emit(SidePaneEvent::RunCommand("Suggest a concise commit message for the changes you made. Just output the message, nothing else.\n".into()))))))
    }
    fn section_body(&self, cx: &mut Context<Self>) -> gpui::Div {
        let chrome = Chrome::get(cx);
        let mut body = div().flex().flex_col().gap_2().p_2().text_size(px(11.));
        match self.section {
            Section::Git => {
                body = body
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                header_button(
                                    "stage-all",
                                    crate::l10n::tr("Stage All"),
                                    chrome,
                                    !self.busy,
                                )
                                .on_click(cx.listener(
                                    |this, _, w, cx| this.perform(Operation::StageAll, w, cx),
                                )),
                            )
                            .child(
                                header_button(
                                    "unstage-all",
                                    crate::l10n::tr("Unstage All"),
                                    chrome,
                                    !self.busy,
                                )
                                .on_click(cx.listener(
                                    |this, _, w, cx| this.perform(Operation::UnstageAll, w, cx),
                                )),
                            ),
                    )
                    .child(self.changes(None, cx))
                    .child(self.composer(cx));
            }
            Section::Session => {
                if let Some(session) = &self.session {
                    let stats = session.current_turn_stats();
                    let known = session.has_token_usage_evidence() || stats.total_tokens() > 0;
                    let usage = if known {
                        format!(
                            "{} input · {} output · {} cache creation · {} cache read",
                            stats.input_tokens(),
                            stats.output_tokens(),
                            stats.cache_creation_tokens(),
                            stats.cache_read_tokens()
                        )
                    } else {
                        crate::l10n::tr("Token usage unavailable").to_string()
                    };
                    body = body
                        .child(format!(
                            "{} · {} · {} turns",
                            session.backend.name(),
                            session.state().raw_value(),
                            session.turn_count()
                        ))
                        .child(usage);
                    let mut tools: Vec<_> = stats
                        .tool_tallies()
                        .iter()
                        .map(|(name, t)| format!("{name} ×{}", t.count))
                        .collect();
                    tools.sort();
                    body = body.child(tools.join(" · "));
                    if let Some(reason) = session.last_exit_reason() {
                        body = body.child(format!("Exit: {}", reason.raw_value()));
                    }
                    if let (Some(start), Some(end)) = (
                        session.last_turn_submitted_at(),
                        session.last_turn_completed_at(),
                    ) {
                        body = body.child(format!(
                            "Duration: {:.1}s",
                            (end - start).num_milliseconds().max(0) as f64 / 1000.
                        ));
                    }
                } else {
                    body = body.child(crate::l10n::tr("No runtime session for this tab"));
                }
                body = body
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                header_button(
                                    "stage-session",
                                    crate::l10n::tr("Stage Session Changes"),
                                    chrome,
                                    !self.busy,
                                )
                                .on_click(cx.listener(
                                    |this, _, w, cx| {
                                        let files = this
                                            .snapshot
                                            .status
                                            .modified
                                            .iter()
                                            .map(|f| f.path.clone())
                                            .chain(this.snapshot.status.untracked.clone())
                                            .filter(|p| this.tracker.files.contains(p))
                                            .collect::<Vec<_>>();
                                        if !files.is_empty() {
                                            this.perform(Operation::Stage(files), w, cx);
                                        }
                                    },
                                )),
                            )
                            .child(
                                header_button(
                                    "reset-session",
                                    crate::l10n::tr("Reset Tracking"),
                                    chrome,
                                    true,
                                )
                                .on_click(cx.listener(
                                    |this, _, _, cx| {
                                        this.tracker.clear_committed_files();
                                        cx.notify();
                                    },
                                )),
                            ),
                    )
                    .child(crate::l10n::tr("Session Changes"))
                    .child(self.changes(Some(true), cx))
                    .child(crate::l10n::tr("Other Changes"))
                    .child(self.changes(Some(false), cx))
                    .child(self.composer(cx));
            }
            Section::Branches => {
                body = body.child(Input::new(&self.branch)).child(
                    header_button(
                        "create-branch",
                        crate::l10n::tr("Create and Switch"),
                        chrome,
                        !self.busy,
                    )
                    .on_click(cx.listener(|this, _, w, cx| {
                        this.perform(
                            Operation::Create(this.branch.read(cx).value().to_string()),
                            w,
                            cx,
                        )
                    })),
                );
                for (i, b) in self.snapshot.branches.iter().enumerate() {
                    let name = b.name.clone();
                    let delete = name.clone();
                    body = body.child(
                        div()
                            .flex()
                            .gap_1()
                            .child(
                                header_button(
                                    format!("branch-{i}"),
                                    format!(
                                        "{}{} · {} {}",
                                        if b.current { "✓ " } else { "" },
                                        b.name,
                                        b.hash,
                                        b.message
                                    ),
                                    chrome,
                                    !self.busy && !b.current,
                                )
                                .flex_1()
                                .on_click(cx.listener(
                                    move |this, _, w, cx| {
                                        this.perform(Operation::Switch(name.clone()), w, cx)
                                    },
                                )),
                            )
                            .when(!b.remote && !b.current, |d| {
                                d.child(
                                    header_button(
                                        format!("delete-branch-{i}"),
                                        crate::l10n::tr("Delete"),
                                        chrome,
                                        !self.busy,
                                    )
                                    .on_click(cx.listener(
                                        move |this, _, w, cx| {
                                            this.perform(Operation::Delete(delete.clone()), w, cx)
                                        },
                                    )),
                                )
                            }),
                    );
                }
            }
            Section::History => {
                body = body.child(Input::new(&self.search));
                let search = self.search.read(cx).value().to_lowercase();
                for (i, c) in self.snapshot.commits.iter().enumerate().filter(|(_, c)| {
                    search.is_empty() || c.message.to_lowercase().contains(&search)
                }) {
                    let hash = c.hash.clone();
                    let message = c.message.clone();
                    let entry = c.full_entry();
                    body = body.child(
                        div()
                            .flex()
                            .flex_col()
                            .border_b_1()
                            .border_color(chrome.border)
                            .py_1()
                            .child(format!("{} {}", c.short_hash, c.message))
                            .child(
                                div()
                                    .text_color(chrome.text_muted)
                                    .child(format!("{} · {}", c.author, c.date)),
                            )
                            .child(
                                div()
                                    .flex()
                                    .gap_1()
                                    .child(
                                        header_button(
                                            format!("hash-{i}"),
                                            crate::l10n::tr("Copy Hash"),
                                            chrome,
                                            true,
                                        )
                                        .on_click(
                                            cx.listener(move |_, _, _, cx| {
                                                cx.write_to_clipboard(ClipboardItem::new_string(
                                                    hash.clone(),
                                                ))
                                            }),
                                        ),
                                    )
                                    .child(
                                        header_button(
                                            format!("message-{i}"),
                                            crate::l10n::tr("Copy Message"),
                                            chrome,
                                            true,
                                        )
                                        .on_click(
                                            cx.listener(move |_, _, _, cx| {
                                                cx.write_to_clipboard(ClipboardItem::new_string(
                                                    message.clone(),
                                                ))
                                            }),
                                        ),
                                    )
                                    .child(
                                        header_button(
                                            format!("entry-{i}"),
                                            crate::l10n::tr("Copy Entry"),
                                            chrome,
                                            true,
                                        )
                                        .on_click(
                                            cx.listener(move |_, _, _, cx| {
                                                cx.write_to_clipboard(ClipboardItem::new_string(
                                                    entry.clone(),
                                                ))
                                            }),
                                        ),
                                    ),
                            ),
                    );
                }
                body = body.child(
                    header_button(
                        "load-more",
                        crate::l10n::tr("Load More"),
                        chrome,
                        !self.busy && self.limit < 5000,
                    )
                    .on_click(cx.listener(|this, _, w, cx| {
                        this.limit = (this.limit + 50).min(5000);
                        this.refresh(w, cx);
                    })),
                );
            }
            Section::Stashes => {
                body = body.child(Input::new(&self.stash_message)).child(
                    header_button(
                        "save-stash",
                        crate::l10n::tr("Save Stash"),
                        chrome,
                        !self.busy,
                    )
                    .on_click(cx.listener(|this, _, w, cx| {
                        this.perform(
                            Operation::StashSave(this.stash_message.read(cx).value().to_string()),
                            w,
                            cx,
                        )
                    })),
                );
                for s in &self.snapshot.stashes {
                    let index = s.index;
                    let pop = s.hash.clone();
                    let drop_hash = s.hash.clone();
                    body = body.child(
                        div()
                            .flex()
                            .gap_1()
                            .child(
                                div()
                                    .flex_1()
                                    .child(format!("stash@{{{index}}}: {}", s.description)),
                            )
                            .child(
                                header_button(
                                    format!("pop-{index}"),
                                    crate::l10n::tr("Pop"),
                                    chrome,
                                    !self.busy,
                                )
                                .on_click(cx.listener(
                                    move |this, _, w, cx| {
                                        this.perform(
                                            Operation::StashPop {
                                                index,
                                                hash: pop.clone(),
                                            },
                                            w,
                                            cx,
                                        )
                                    },
                                )),
                            )
                            .child(
                                header_button(
                                    format!("drop-{index}"),
                                    crate::l10n::tr("Drop"),
                                    chrome,
                                    !self.busy,
                                )
                                .on_click(cx.listener(
                                    move |this, _, w, cx| {
                                        this.perform(
                                            Operation::StashDrop {
                                                index,
                                                hash: drop_hash.clone(),
                                            },
                                            w,
                                            cx,
                                        )
                                    },
                                )),
                            ),
                    );
                }
            }
        }
        body
    }
}
impl Render for RepositoryPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let branch = if let Some((a, b)) = self.snapshot.ahead_behind {
            format!("{} ↑{a} ↓{b}", self.snapshot.current_branch)
        } else {
            self.snapshot.current_branch.clone()
        };
        let body = self.section_body(cx).when(self.directory.is_none(), |d| {
            d.child(crate::l10n::tr("No Git repository for this tab"))
        });
        div()
            .id("repository-pane")
            .key_context(CONTEXT)
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .size_full()
            .bg(chrome.tab_bg)
            .text_color(chrome.text)
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Focused)),
            )
            .on_action(cx.listener(|this, _: &CommitChanges, w, cx| this.commit(w, cx)))
            .child(
                header(chrome)
                    .child(div().flex_1().child(format!("Repository · {branch}")))
                    .child(
                        header_button(
                            "repo-refresh",
                            crate::l10n::tr("Refresh"),
                            chrome,
                            !self.busy,
                        )
                        .on_click(cx.listener(|this, _, w, cx| {
                            this.error = None;
                            this.update_session(w, cx);
                            this.refresh(w, cx);
                        })),
                    )
                    .child(
                        header_button("repo-push", crate::l10n::tr("Push"), chrome, !self.busy)
                            .on_click(
                                cx.listener(|this, _, w, cx| this.perform(Operation::Push, w, cx)),
                            ),
                    )
                    .child(
                        header_button("repo-pull", crate::l10n::tr("Pull"), chrome, !self.busy)
                            .on_click(
                                cx.listener(|this, _, w, cx| this.perform(Operation::Pull, w, cx)),
                            ),
                    )
                    .child(
                        header_button("repo-close", "×", chrome, true)
                            .on_click(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Close))),
                    ),
            )
            .child(
                div().flex().gap_1().p_1().children(
                    [
                        (Section::Session, "Session"),
                        (Section::Git, "Git"),
                        (Section::Branches, "Branches"),
                        (Section::History, "History"),
                        (Section::Stashes, "Stashes"),
                    ]
                    .into_iter()
                    .map(|(section, label)| {
                        header_button(
                            format!("repo-section-{label}"),
                            crate::l10n::tr(label),
                            chrome,
                            true,
                        )
                        .when(self.section == section, |d| d.bg(chrome.tab_hover_bg))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.section = section;
                            cx.notify();
                        }))
                    }),
                ),
            )
            .children(self.error.clone().map(|e| {
                div()
                    .p_2()
                    .text_size(px(11.))
                    .text_color(chrome.accent)
                    .child(e)
            }))
            .when(self.busy, |d| {
                d.child(
                    div()
                        .px_2()
                        .text_size(px(11.))
                        .child(crate::l10n::tr("Working…")),
                )
            })
            .child(
                div()
                    .id("repository-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(body),
            )
    }
}

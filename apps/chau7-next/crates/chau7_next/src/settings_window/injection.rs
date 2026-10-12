//! AI Context settings. Global changes persist live; named/local edits use Save.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chau7_next_core::injection_rules::{
    self as rules, LocalRule, Position, Rule, RulesFile, Trigger, Writer,
};
use gpui::{
    App, Context, Entity, Global, SharedString, Subscription, Task, Window, div, prelude::*, px,
};
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};

use super::widgets::{button, chip, description, row, section as titled};
use super::{SectionContext, SettingsView, set_message};
use crate::workspace::AppData;

/// One model/writer per app: closing/reopening Settings cannot race two writers.
struct RuleCache {
    file: RulesFile,
    locals: BTreeMap<String, LocalRule>,
    loaded: bool,
    revision: u64,
    writer: Writer,
}
impl Global for RuleCache {}

#[derive(Clone)]
enum Target {
    Named(uuid::Uuid),
    Local(String),
}

pub(super) struct InjectionState {
    file: RulesFile,
    locals: BTreeMap<String, LocalRule>,
    loading: bool,
    enabled: bool,
    position: Position,
    triggers: std::collections::BTreeSet<Trigger>,
    global: Entity<TextareaState>,
    pattern: Entity<InputState>,
    content: Entity<TextareaState>,
    editing: Option<Target>,
    edit_position: Position,
    edit_triggers: std::collections::BTreeSet<Trigger>,
    _subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}
impl InjectionState {
    pub(super) fn summary_counts(&self) -> Option<(bool, usize, usize)> {
        (!self.loading).then(|| {
            (
                self.file.global().is_some(),
                self.file
                    .rules
                    .iter()
                    .filter(|rule| rule.repository != "*")
                    .count(),
                self.locals
                    .values()
                    .filter(|rule| rule.rule.is_some())
                    .count(),
            )
        })
    }

    pub(super) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let root = cx.global::<AppData>().root.clone();
        if cx.try_global::<RuleCache>().is_none() {
            cx.set_global(RuleCache {
                file: RulesFile::default(),
                locals: BTreeMap::new(),
                loaded: false,
                revision: 0,
                writer: Writer::new(root.clone()),
            });
        }
        let cache = cx.global::<RuleCache>();
        let file = cache.file.clone();
        let locals = cache.locals.clone();
        let loading = !cache.loaded;
        let global_rule = file.global().cloned().unwrap_or_else(|| Rule::new("*"));
        let global = cx.new(|cx| TextareaState::new(window, cx));
        global.update(cx, |input, cx| {
            input.set_value(global_rule.content.clone(), window, cx)
        });
        let pattern = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::l10n::tr("Repository name or absolute path"))
        });
        let content = cx.new(|cx| TextareaState::new(window, cx));
        let subscription = cx.subscribe(&global, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) && !this.injection.loading {
                this.injection.persist_global(cx);
            }
        });
        let mut tasks = Vec::new();
        let known_roots = crate::repository::known_roots(cx);
        if loading {
            let root = root.clone();
            let load = cx.background_spawn(async move {
                let file = rules::load(&root);
                let mut locals = BTreeMap::new();
                let mut errors = Vec::new();
                for repo in known_roots {
                    let path = Path::new(&repo);
                    if crate::protected_paths::should_skip(path) {
                        continue;
                    }
                    match rules::load_local(&root, path) {
                        Ok(local) if local.rule.is_some() || local.overridden => {
                            locals.insert(repo, local);
                        }
                        Ok(_) => {}
                        Err(error) => errors.push(error),
                    }
                }
                (file, locals, errors)
            });
            tasks.push(cx.spawn_in(window, async move |this, cx| {
                let (file, locals, mut errors) = load.await;
                let _ = this.update_in(cx, |this, window, cx| {
                    let state = &mut this.injection;
                    match file {
                        Ok(file) => state.file = file,
                        Err(error) => errors.push(error),
                    }
                    state.locals = locals;
                    let global = state
                        .file
                        .global()
                        .cloned()
                        .unwrap_or_else(|| Rule::new("*"));
                    state.enabled = state.file.global().is_some();
                    state.position = global.position;
                    state.triggers = global.triggers;
                    state
                        .global
                        .update(cx, |input, cx| input.set_value(global.content, window, cx));
                    state.loading = false;
                    state.cache(cx);
                    if !errors.is_empty() {
                        set_message(cx, errors.join("\n"), true);
                    }
                    cx.notify();
                });
            }));
        }
        let timer = crate::observability::register_timer(
            cx,
            &format!("context.rules.{}", cx.entity_id()),
            "Context rule persistence errors",
            "settings",
            1000,
        );
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            let _timer = timer;
            let mut ticks = 0;
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                let Ok(catalog) = this.update_in(cx, |_, _, cx| {
                    let cache = cx.global::<RuleCache>();
                    let catalog = cache.loaded.then(|| {
                        (
                            cache.revision,
                            cache
                                .locals
                                .keys()
                                .cloned()
                                .collect::<std::collections::BTreeSet<_>>(),
                            crate::repository::known_roots(cx),
                        )
                    });
                    if let Some(error) = cache.writer.take_error() {
                        set_message(cx, error, true);
                    }
                    catalog
                }) else {
                    break;
                };
                ticks += 1;
                if ticks % 5 != 0 {
                    continue;
                }
                let Some((revision, known, roots)) = catalog else {
                    continue;
                };
                let root = root.clone();
                let found = cx
                    .background_executor()
                    .spawn(async move {
                        let mut found = BTreeMap::new();
                        for repo in roots {
                            if known.contains(&repo)
                                || crate::protected_paths::should_skip(Path::new(&repo))
                            {
                                continue;
                            }
                            match rules::load_local(&root, Path::new(&repo)) {
                                Ok(local) if local.rule.is_some() || local.overridden => {
                                    found.insert(repo, local);
                                }
                                Ok(_) => {}
                                Err(error) => log::warn!("Context repository discovery: {error}"),
                            }
                        }
                        found
                    })
                    .await;
                if this
                    .update_in(cx, |this, _, cx| {
                        // An edit while disk reads ran wins over that older snapshot.
                        if !merge_catalog(
                            &mut this.injection.locals,
                            found,
                            revision,
                            cx.global::<RuleCache>().revision,
                        ) {
                            return;
                        }
                        this.injection.cache(cx);
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
        Self {
            enabled: file.global().is_some(),
            file,
            locals,
            loading,
            position: global_rule.position,
            triggers: global_rule.triggers,
            global,
            pattern,
            content,
            editing: None,
            edit_position: Position::Prepend,
            edit_triggers: [Trigger::EveryPrompt].into(),
            _subscriptions: vec![subscription],
            _tasks: tasks,
        }
    }
    fn cache(&self, cx: &mut App) {
        let cache = cx.global_mut::<RuleCache>();
        cache.file = self.file.clone();
        cache.locals = self.locals.clone();
        cache.loaded = !self.loading;
        cache.revision = cache.revision.wrapping_add(1);
    }
    fn persist_global(&mut self, cx: &mut Context<SettingsView>) {
        if self.loading {
            return;
        }
        let rule = if self.enabled {
            let mut rule = Rule::new("*");
            rule.content = self.global.read(cx).value().to_string();
            rule.position = self.position;
            rule.triggers = self.triggers.clone();
            Some(rule)
        } else {
            None
        };
        self.file.set_global(rule);
        self.persist(cx);
    }
    fn persist(&self, cx: &mut App) {
        self.cache(cx);
        cx.global::<RuleCache>().writer.save(self.file.clone());
    }
    fn edit(&mut self, target: Target, window: &mut Window, cx: &mut Context<SettingsView>) {
        let rule = match &target {
            Target::Named(id) => self
                .file
                .rules
                .iter()
                .find(|r| r.id == *id)
                .cloned()
                .unwrap_or_else(|| {
                    let mut r = Rule::new("");
                    r.id = *id;
                    r
                }),
            Target::Local(repo) => self
                .locals
                .get(repo)
                .and_then(|r| r.rule.clone())
                .unwrap_or_else(|| Rule::new(repo.clone())),
        };
        self.pattern
            .update(cx, |input, cx| input.set_value(rule.repository, window, cx));
        self.content
            .update(cx, |input, cx| input.set_value(rule.content, window, cx));
        self.edit_position = rule.position;
        self.edit_triggers = rule.triggers;
        self.editing = Some(target);
        cx.notify();
    }
    fn save_editor(&mut self, cx: &mut Context<SettingsView>) {
        let Some(target) = self.editing.clone() else {
            return;
        };
        let pattern = self.pattern.read(cx).value().trim().to_string();
        let mut rule = Rule::new(pattern.clone());
        rule.content = self.content.read(cx).value().to_string();
        rule.position = self.edit_position;
        rule.triggers = self.edit_triggers.clone();
        match target {
            Target::Named(id) => {
                rule.id = id;
                if let Err(error) = self.file.upsert(rule) {
                    set_message(cx, error, true);
                    return;
                }
                self.persist(cx);
            }
            Target::Local(repo) => {
                let pattern = if repo.is_empty() { pattern } else { repo };
                let path = PathBuf::from(&pattern);
                if !path.is_absolute() {
                    set_message(cx, "Enter an absolute repository directory.".into(), true);
                    return;
                }
                if crate::protected_paths::should_skip(&path) {
                    set_message(
                        cx,
                        "Allow protected folder access before editing this repository rule.".into(),
                        true,
                    );
                    return;
                }
                if let Err(error) = cx
                    .global::<RuleCache>()
                    .writer
                    .save_local(path, Some(rule.clone()))
                {
                    set_message(cx, error, true);
                    return;
                }
                self.locals.insert(
                    pattern,
                    LocalRule {
                        rule: Some(rule),
                        overridden: true,
                    },
                );
                self.cache(cx);
            }
        }
        self.editing = None;
        cx.notify();
    }
    fn remove(&mut self, target: Target, cx: &mut Context<SettingsView>) {
        match target {
            Target::Named(id) => {
                self.file.remove(id);
                self.persist(cx);
            }
            Target::Local(repo) => {
                if crate::protected_paths::should_skip(Path::new(&repo)) {
                    set_message(
                        cx,
                        "Allow protected folder access before editing this repository rule.".into(),
                        true,
                    );
                    return;
                }
                if let Err(error) = cx
                    .global::<RuleCache>()
                    .writer
                    .save_local(PathBuf::from(&repo), None)
                {
                    set_message(cx, error, true);
                    return;
                }
                self.locals.insert(
                    repo,
                    LocalRule {
                        rule: None,
                        overridden: true,
                    },
                );
                self.cache(cx);
            }
        }
        self.editing = None;
        cx.notify();
    }
}
/// Merge discovery without overwriting edited/deleted state or existing rules.
fn merge_catalog(
    locals: &mut BTreeMap<String, LocalRule>,
    found: BTreeMap<String, LocalRule>,
    snapshot_revision: u64,
    current_revision: u64,
) -> bool {
    if found.is_empty() || snapshot_revision != current_revision {
        return false;
    }
    let before = locals.len();
    for (repo, local) in found {
        locals.entry(repo).or_insert(local);
    }
    locals.len() != before
}

fn toggle_trigger(set: &mut std::collections::BTreeSet<Trigger>, trigger: Trigger) {
    if !set.remove(&trigger) {
        set.insert(trigger);
    }
    if set.is_empty() {
        set.insert(Trigger::EveryPrompt);
    }
}
fn controls(ctx: &SectionContext, global: bool) -> gpui::Div {
    let state = &ctx.view.injection;
    let position = if global {
        state.position
    } else {
        state.edit_position
    };
    let selected = if global {
        &state.triggers
    } else {
        &state.edit_triggers
    };
    let positions = Position::ALL.into_iter().map(|p| {
        let view = ctx.view.entity.clone();
        chip(
            SharedString::from(format!("context-position-{global}-{p:?}")),
            p.label(),
            position == p,
            ctx.chrome,
        )
        .on_click(move |_, _, cx| {
            let _ = view.update(cx, |this, cx| {
                if global {
                    this.injection.position = p;
                    this.injection.persist_global(cx);
                } else {
                    this.injection.edit_position = p;
                }
                cx.notify();
            });
        })
    });
    let triggers = Trigger::ALL.into_iter().map(|t| {
        let view = ctx.view.entity.clone();
        chip(
            SharedString::from(format!("context-trigger-{global}-{t:?}")),
            t.label(),
            selected.contains(&t),
            ctx.chrome,
        )
        .on_click(move |_, _, cx| {
            let _ = view.update(cx, |this, cx| {
                if global {
                    toggle_trigger(&mut this.injection.triggers, t);
                    this.injection.persist_global(cx);
                } else {
                    toggle_trigger(&mut this.injection.edit_triggers, t);
                }
                cx.notify();
            });
        })
    });
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(row(
            "Position",
            div().flex().flex_wrap().gap_1().children(positions),
            ctx.chrome,
        ))
        .child(row(
            "When to inject",
            div().flex().flex_wrap().gap_1().children(triggers),
            ctx.chrome,
        ))
}
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let state = &ctx.view.injection;
    let chrome = ctx.chrome;
    if state.loading {
        return titled("AI Context", chrome).child(description("Loading context rules...", chrome));
    }
    let view = ctx.view.entity.clone();
    let mut all = titled("All Repositories", chrome)
        .child(description("Add context to matching AI requests. Repository rules take precedence. Global changes are saved automatically.", chrome))
        .child(row("Enable global injection", chip("context-enabled", if state.enabled { "Enabled" } else { "Disabled" }, state.enabled, chrome).on_click(move |_, _, cx| {
            let _ = view.update(cx, |this, cx| { this.injection.enabled = !this.injection.enabled; this.injection.persist_global(cx); cx.notify(); });
        }), chrome));
    if state.enabled {
        all = all
            .child(controls(ctx, true))
            .child(Textarea::new(&state.global).h(px(140.)));
    }
    let mut specific = titled("Per Repository", chrome).child(description("Target a repository by name or absolute path. Local overrides are saved in Chau7 Next's own storage.", chrome));
    for rule in state.file.rules.iter().filter(|r| r.repository != "*") {
        specific = specific.child(rule_row(rule, Target::Named(rule.id), false, ctx));
    }
    for (repo, local) in &state.locals {
        if let Some(rule) = &local.rule {
            specific = specific.child(rule_row(
                rule,
                Target::Local(repo.clone()),
                local.overridden,
                ctx,
            ));
        }
    }
    let add = ctx.view.entity.clone();
    let local = ctx.view.entity.clone();
    specific = specific.child(
        div()
            .flex()
            .gap_2()
            .child(
                button("context-add-rule", "Add Repository Rule", chrome).on_click(
                    move |_, window, cx| {
                        let _ = add.update(cx, |this, cx| {
                            this.injection
                                .edit(Target::Named(uuid::Uuid::new_v4()), window, cx)
                        });
                    },
                ),
            )
            .child(
                button("context-add-local", "Add Local Override", chrome).on_click(
                    move |_, window, cx| {
                        let _ = local.update(cx, |this, cx| {
                            this.injection
                                .edit(Target::Local(String::new()), window, cx)
                        });
                    },
                ),
            ),
    );
    if state.editing.is_some() {
        let save = ctx.view.entity.clone();
        let cancel = ctx.view.entity.clone();
        specific = specific.child(
            div()
                .flex()
                .flex_col()
                .gap_2()
                .pt_3()
                .child(match state.editing.as_ref() {
                    Some(Target::Local(repo)) if !repo.is_empty() => {
                        description(repo.clone(), chrome)
                    }
                    _ => div().child(Input::new(&state.pattern)),
                })
                .child(controls(ctx, false))
                .child(Textarea::new(&state.content).h(px(140.)))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(button("context-save-rule", "Save", chrome).on_click(
                            move |_, _, cx| {
                                let _ = save.update(cx, |this, cx| this.injection.save_editor(cx));
                            },
                        ))
                        .child(button("context-cancel-rule", "Cancel", chrome).on_click(
                            move |_, _, cx| {
                                let _ = cancel.update(cx, |this, cx| {
                                    this.injection.editing = None;
                                    cx.notify();
                                });
                            },
                        )),
                ),
        );
    }
    div().flex().flex_col().gap_4().child(all).child(specific)
        .child(titled("How It Works", chrome)
            .child(description("Priority: local rule, repository rule, global rule. Next overrides affect only Next; original repository rules remain available to Chau7. Proxy rules refresh within 30 seconds.", chrome))
            .child(description("Injection applies to requests routed through API Analytics. Automatic injection directly into an AI terminal is currently unavailable.", chrome)))
}
fn rule_row(rule: &Rule, target: Target, owned: bool, ctx: &SectionContext) -> gpui::Div {
    let edit = ctx.view.entity.clone();
    let delete = ctx.view.entity.clone();
    let edit_target = target.clone();
    let local = matches!(target, Target::Local(_));
    let detail = format!(
        "{} · {}{}",
        rule.position.label(),
        rule.triggers
            .iter()
            .map(|t| t.label())
            .collect::<Vec<_>>()
            .join(", "),
        if local {
            if owned {
                " · Next override"
            } else {
                " · Repository file"
            }
        } else {
            ""
        }
    );
    let label = match &target {
        Target::Local(repo) => repo.clone(),
        Target::Named(_) => rule.repository.clone(),
    };
    row(
        label,
        div()
            .flex()
            .gap_2()
            .child(
                button(
                    SharedString::from(format!("context-edit-{}", rule.id)),
                    "Edit",
                    ctx.chrome,
                )
                .on_click(move |_, window, cx| {
                    let _ = edit.update(cx, |this, cx| {
                        this.injection.edit(edit_target.clone(), window, cx)
                    });
                }),
            )
            .child(
                button(
                    SharedString::from(format!("context-delete-{}", rule.id)),
                    "Delete",
                    ctx.chrome,
                )
                .on_click(move |_, _, cx| {
                    let _ = delete.update(cx, |this, cx| this.injection.remove(target.clone(), cx));
                }),
            ),
        ctx.chrome,
    )
    .child(description(detail, ctx.chrome))
    .child(description(
        rule.content.chars().take(80).collect::<String>(),
        ctx.chrome,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn live_discovery_preserves_edits_and_rejects_stale_reads() {
        let local = |content: &str| {
            let mut rule = Rule::new("/repo");
            rule.content = content.into();
            LocalRule {
                rule: Some(rule),
                overridden: true,
            }
        };
        let mut locals = BTreeMap::from([("/repo".into(), local("edited"))]);
        assert!(!merge_catalog(
            &mut locals,
            BTreeMap::from([("/new".into(), local("stale"))]),
            1,
            2
        ));
        assert!(!locals.contains_key("/new"));
        assert!(merge_catalog(
            &mut locals,
            BTreeMap::from([
                ("/repo".into(), local("old")),
                ("/new".into(), local("new"))
            ]),
            2,
            2
        ));
        assert_eq!(locals["/repo"].rule.as_ref().unwrap().content, "edited");
        assert_eq!(locals["/new"].rule.as_ref().unwrap().content, "new");
    }
    #[test]
    fn trigger_editor_never_persists_an_empty_selection() {
        let mut triggers = [Trigger::EveryPrompt].into();
        toggle_trigger(&mut triggers, Trigger::AfterClear);
        toggle_trigger(&mut triggers, Trigger::EveryPrompt);
        assert_eq!(triggers, [Trigger::AfterClear].into());
        toggle_trigger(&mut triggers, Trigger::AfterClear);
        assert_eq!(triggers, [Trigger::EveryPrompt].into());
    }
}

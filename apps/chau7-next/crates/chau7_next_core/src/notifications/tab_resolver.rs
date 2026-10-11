//! Port of `Notifications/TabResolver.swift`: which tab an event belongs to,
//! across every window.
//!
//! The app passes a snapshot of its tabs ([`TabRoute`], one [`SessionRoute`]
//! per terminal pane). Order: exact tab id, exact AI session id, then the
//! tool name on the focused session, on the tab title, on any pane, and last
//! the most recently active tab whose directory a registered tool monitor
//! knows ([`register_cwd_resolver`]). Several matches are narrowed by session
//! id, then directory, then most recent activity.
//!
//! Tab ids are `Uuid`s here like in Swift; the app maps its numeric tab ids
//! with [`tab_uuid`] and [`tab_id_from_uuid`], which use each tab's stable
//! UUID ([`register_tab_uuid`]).

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

use uuid::Uuid;

use crate::ai::resume::normalize_provider_name;
use crate::ai::tool_registry::AI_TOOLS;
use crate::path_rank::bidirectional_prefix_rank;
use crate::tab_target::TabTarget;

/// One terminal pane of a tab, as the resolver sees it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SessionRoute {
    /// `aiDisplayAppName`: the AI tool shown for the pane.
    pub ai_display_app_name: Option<String>,
    /// `activeAppName`: the detected foreground app.
    pub active_app_name: Option<String>,
    /// `lastAIProvider`.
    pub last_ai_provider: Option<String>,
    /// `effectiveAIProvider`.
    pub effective_ai_provider: Option<String>,
    /// `effectiveAISessionId`: the AI session running in the pane.
    pub effective_ai_session_id: Option<String>,
    pub current_directory: String,
    /// Last activity, in seconds on any monotonic clock.
    pub last_activity: f64,
}

/// One tab, as the resolver sees it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TabRoute {
    pub id: Uuid,
    /// `displaySession?.aiDisplayAppName`: the focused pane's AI tool.
    pub display_app_name: Option<String>,
    /// `displayTitle`.
    pub display_title: String,
    pub sessions: Vec<SessionRoute>,
    /// Creation time, same clock as [`SessionRoute::last_activity`].
    pub created_at: f64,
}

impl TabRoute {
    fn last_activity(&self) -> f64 {
        self.sessions
            .iter()
            .map(|s| s.last_activity)
            .fold(None, |acc: Option<f64>, v| {
                Some(acc.map_or(v, |a| a.max(v)))
            })
            .unwrap_or(self.created_at)
    }
}

/// The stable identity of each open tab (`TabMeta::uuid`, kept across
/// relaunch by session restore), by numeric tab id, and back.
#[derive(Default)]
struct TabUuids {
    by_id: HashMap<u64, Uuid>,
    by_uuid: HashMap<Uuid, u64>,
}

fn tab_uuids() -> &'static Mutex<TabUuids> {
    static UUIDS: OnceLock<Mutex<TabUuids>> = OnceLock::new();
    UUIDS.get_or_init(Default::default)
}

/// Record the stable UUID of a tab (called by `TabMeta`), so MCP, events,
/// notifications, remote control and restore all use the same tab identity.
pub fn register_tab_uuid(tab_id: u64, uuid: Uuid) {
    if let Ok(mut map) = tab_uuids().lock() {
        if let Some(old) = map.by_id.insert(tab_id, uuid)
            && old != uuid
        {
            map.by_uuid.remove(&old);
        }
        map.by_uuid.insert(uuid, tab_id);
    }
}

/// Encoding used for a numeric tab id that has no registered UUID.
const FALLBACK_HIGH: u64 = 0x6368_6175_375f_7461;

/// The `Uuid` events use for a numeric tab id: the tab's stable UUID
/// ([`register_tab_uuid`]), else an encoding of the number.
pub fn tab_uuid(tab_id: u64) -> Uuid {
    if let Ok(map) = tab_uuids().lock()
        && let Some(uuid) = map.by_id.get(&tab_id)
    {
        return *uuid;
    }
    Uuid::from_u64_pair(FALLBACK_HIGH, tab_id)
}

/// The numeric tab id behind [`tab_uuid`], if `uuid` is one.
pub fn tab_id_from_uuid(uuid: Uuid) -> Option<u64> {
    if let Ok(map) = tab_uuids().lock()
        && let Some(id) = map.by_uuid.get(&uuid)
    {
        return Some(*id);
    }
    let (high, low) = uuid.as_u64_pair();
    (high == FALLBACK_HIGH).then_some(low)
}

/// Given a directory, the last session activity a tool monitor saw there.
pub type CwdResolver = Box<dyn Fn(&str) -> Option<f64> + Send + Sync>;

fn cwd_resolvers() -> &'static Mutex<HashMap<String, CwdResolver>> {
    static RESOLVERS: OnceLock<Mutex<HashMap<String, CwdResolver>>> = OnceLock::new();
    RESOLVERS.get_or_init(Default::default)
}

/// Called by tool monitors (keyed by provider key, for example `claude` or
/// `codex`) so routing can fall back on the directory
/// (`TabResolver.registerCWDResolver`).
pub fn register_cwd_resolver(provider_key: &str, resolver: CwdResolver) {
    if let Ok(mut map) = cwd_resolvers().lock() {
        map.insert(provider_key.to_string(), resolver);
    }
}

/// Lower-cased label, mapped to its provider key when it names a known tool.
pub fn normalized_tool_label(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim().to_lowercase();
    if trimmed.is_empty() {
        return None;
    }
    Some(normalize_provider_name(&trimmed).unwrap_or(trimmed))
}

fn find_tool(candidate: &str) -> Option<&'static crate::ai::tool_registry::AiToolEntry> {
    AI_TOOLS.iter().find(|def| {
        def.display_name.to_lowercase() == candidate
            || def.command_names.contains(&candidate)
            || def.resume_provider_key == Some(candidate)
    })
}

/// Every name a tool goes by (`toolMatchCandidates`).
pub fn tool_match_candidates(tool: &str) -> Vec<String> {
    let Some(normalized) = normalized_tool_label(Some(tool)) else {
        return Vec::new();
    };
    let mut candidates = vec![normalized.clone()];
    let mut seen: HashSet<String> = candidates.iter().cloned().collect();
    let mut append = |value: &str| {
        let lowered = value.to_lowercase();
        if seen.insert(lowered.clone()) {
            candidates.push(lowered);
        }
    };
    if let Some(def) = find_tool(&normalized) {
        append(def.display_name);
        if let Some(key) = def.resume_provider_key {
            append(key);
        }
        for cmd in def.command_names {
            append(cmd);
        }
        for pattern in def.output_patterns {
            append(pattern);
        }
    }
    candidates
}

fn matches_candidate(raw: Option<&str>, candidates: &[String]) -> bool {
    normalized_tool_label(raw).is_some_and(|n| candidates.contains(&n))
}

/// `TabResolver.resolve` with the registered directory resolvers.
pub fn resolve(target: &TabTarget, tabs: &[TabRoute]) -> Option<Uuid> {
    resolve_with(target, tabs, &|candidates: &[String], dir: &str| {
        let key = candidates
            .iter()
            .find_map(|c| find_tool(c).and_then(|d| d.resume_provider_key))?;
        let map = cwd_resolvers().lock().ok()?;
        map.get(key).and_then(|r| r(dir))
    })
}

/// [`resolve`] with an explicit directory fallback (tests).
pub fn resolve_with(
    target: &TabTarget,
    tabs: &[TabRoute],
    cwd_activity: &dyn Fn(&[String], &str) -> Option<f64>,
) -> Option<Uuid> {
    if let Some(id) = target.tab_id
        && tabs.iter().any(|t| t.id == id)
    {
        return Some(id);
    }
    let candidates = tool_match_candidates(&target.tool);
    if let Some(tab) = exact_session_match(target, &candidates, tabs) {
        return Some(tab.id);
    }
    if candidates.is_empty() {
        return None;
    }
    let pick = |matches: Vec<&TabRoute>| disambiguate(&matches, target).map(|t| t.id);

    let brand: Vec<_> = tabs
        .iter()
        .filter(|t| matches_candidate(t.display_app_name.as_deref(), &candidates))
        .collect();
    if !brand.is_empty() {
        return pick(brand);
    }
    let titles: Vec<_> = tabs
        .iter()
        .filter(|t| matches_candidate(Some(&t.display_title), &candidates))
        .collect();
    if !titles.is_empty() {
        return pick(titles);
    }
    let deep: Vec<_> = tabs
        .iter()
        .filter(|t| {
            t.sessions.iter().any(|s| {
                matches_candidate(s.ai_display_app_name.as_deref(), &candidates)
                    || matches_candidate(s.active_app_name.as_deref(), &candidates)
                    || s.last_ai_provider
                        .as_deref()
                        .and_then(normalize_provider_name)
                        .is_some_and(|p| candidates.contains(&p))
            })
        })
        .collect();
    if !deep.is_empty() {
        return pick(deep);
    }

    // Directory fallback: the tab whose directory saw the latest session.
    let mut best: Option<(&TabRoute, f64)> = None;
    for tab in tabs {
        let activity = tab
            .sessions
            .iter()
            .filter_map(|s| {
                let dir = s.current_directory.trim();
                if dir.is_empty() {
                    None
                } else {
                    cwd_activity(&candidates, dir)
                }
            })
            .fold(None, |acc: Option<f64>, v| {
                Some(acc.map_or(v, |a| a.max(v)))
            });
        if let Some(a) = activity
            && best.is_none_or(|(_, b)| a > b)
        {
            best = Some((tab, a));
        }
    }
    if let Some((tab, _)) = best {
        log::info!(
            "TabResolver: resolved '{}' via cwd fallback to tab={}",
            target.tool,
            tab.id
        );
        return Some(tab.id);
    }
    None
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|s| !s.is_empty())
}

fn session_matches_candidates(session: &SessionRoute, candidates: &[String]) -> bool {
    if candidates.is_empty() {
        return true;
    }
    [
        session.ai_display_app_name.as_deref(),
        session.active_app_name.as_deref(),
        session.effective_ai_provider.as_deref(),
        session.last_ai_provider.as_deref(),
    ]
    .into_iter()
    .filter_map(normalized_tool_label)
    .any(|label| candidates.contains(&label))
}

fn most_recent<'a>(tabs: &[&'a TabRoute]) -> Option<&'a TabRoute> {
    // Swift `max(by:)` keeps the last of equal elements.
    tabs.iter()
        .copied()
        .fold(None, |best: Option<&TabRoute>, t| match best {
            Some(b) if b.last_activity() > t.last_activity() => Some(b),
            _ => Some(t),
        })
}

/// Tabs ranked by how closely a pane's directory matches `dir`, best rank
/// only.
fn best_by_directory<'a>(tabs: &[&'a TabRoute], dir: &str) -> Option<(u8, Vec<&'a TabRoute>)> {
    let ranked: Vec<(&TabRoute, u8)> = tabs
        .iter()
        .filter_map(|tab| {
            tab.sessions
                .iter()
                .filter_map(|s| bidirectional_prefix_rank(dir, &s.current_directory))
                .min()
                .map(|r| (*tab, r))
        })
        .collect();
    let best = ranked.iter().map(|(_, r)| *r).min()?;
    Some((
        best,
        ranked
            .into_iter()
            .filter(|(_, r)| *r == best)
            .map(|(t, _)| t)
            .collect(),
    ))
}

fn exact_session_match<'a>(
    target: &TabTarget,
    candidates: &[String],
    tabs: &'a [TabRoute],
) -> Option<&'a TabRoute> {
    let session_id = trimmed(target.session_id.as_deref())?;
    let ranked: Vec<(&TabRoute, u8)> = tabs
        .iter()
        .filter_map(|tab| {
            let matching: Vec<_> = tab
                .sessions
                .iter()
                .filter(|s| s.effective_ai_session_id.as_deref() == Some(session_id))
                .collect();
            if matching.is_empty() {
                return None;
            }
            let provider_matches = matching
                .iter()
                .any(|s| session_matches_candidates(s, candidates));
            Some((tab, if provider_matches { 0 } else { 1 }))
        })
        .collect();
    let best_rank = ranked.iter().map(|(_, r)| *r).min()?;
    let best: Vec<&TabRoute> = ranked
        .into_iter()
        .filter(|(_, r)| *r == best_rank)
        .map(|(t, _)| t)
        .collect();
    if best.len() == 1 {
        return Some(best[0]);
    }
    if let Some(dir) = trimmed(target.directory.as_deref())
        && let Some((_, dir_matches)) = best_by_directory(&best, dir)
    {
        if dir_matches.len() == 1 {
            return Some(dir_matches[0]);
        }
        if let Some(t) = most_recent(&dir_matches) {
            return Some(t);
        }
    }
    most_recent(&best)
}

fn disambiguate<'a>(matches: &[&'a TabRoute], target: &TabTarget) -> Option<&'a TabRoute> {
    if matches.len() <= 1 {
        return matches.first().copied();
    }
    if let Some(session_id) = trimmed(target.session_id.as_deref())
        && let Some(tab) = matches.iter().find(|t| {
            t.sessions
                .iter()
                .any(|s| s.effective_ai_session_id.as_deref() == Some(session_id))
        })
    {
        return Some(tab);
    }
    if let Some(dir) = trimmed(target.directory.as_deref())
        && let Some((_, dir_matches)) = best_by_directory(matches, dir)
    {
        if dir_matches.len() == 1 {
            return Some(dir_matches[0]);
        }
        if let Some(t) = most_recent(&dir_matches) {
            return Some(t);
        }
    }
    log::info!(
        "TabResolver: {} ambiguous matches, using most recently active tab",
        matches.len()
    );
    most_recent(matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(provider: &str, session_id: &str, dir: &str, activity: f64) -> SessionRoute {
        SessionRoute {
            last_ai_provider: Some(provider.into()),
            effective_ai_provider: Some(provider.into()),
            effective_ai_session_id: Some(session_id.into()),
            current_directory: dir.into(),
            last_activity: activity,
            ..Default::default()
        }
    }

    fn tab(n: u64, sessions: Vec<SessionRoute>) -> TabRoute {
        TabRoute {
            id: tab_uuid(n),
            display_title: "Shell".into(),
            sessions,
            created_at: n as f64,
            ..Default::default()
        }
    }

    fn target(tool: &str) -> TabTarget {
        TabTarget::new(tool)
    }

    #[test]
    fn tab_uuid_round_trips() {
        assert_eq!(tab_id_from_uuid(tab_uuid(42)), Some(42));
        assert_eq!(tab_id_from_uuid(Uuid::new_v4()), None);
    }

    #[test]
    fn registered_tab_uuid_is_used_both_ways() {
        let stable = Uuid::new_v4();
        let id = 9_000_001;
        register_tab_uuid(id, stable);
        assert_eq!(tab_uuid(id), stable);
        assert_eq!(tab_id_from_uuid(stable), Some(id));
        // Restored with its saved UUID: the old one no longer resolves.
        let saved = Uuid::new_v4();
        register_tab_uuid(id, saved);
        assert_eq!(tab_uuid(id), saved);
        assert_eq!(tab_id_from_uuid(saved), Some(id));
        assert_eq!(tab_id_from_uuid(stable), None);
    }

    // TabResolverTests

    #[test]
    fn resolve_uses_exact_session_id_even_when_tool_label_has_no_candidates() {
        let id = "019d25d0-d0bd-7501-99ba-1f937c17b29b";
        let tabs = vec![
            tab(1, vec![session("codex", id, "/a", 1.0)]),
            tab(
                2,
                vec![session(
                    "codex",
                    "019d33c3-5f8e-7a21-809d-61b4c04fcbba",
                    "/a",
                    2.0,
                )],
            ),
        ];
        let mut t = target("UnknownTool");
        t.session_id = Some(id.into());
        assert_eq!(resolve(&t, &tabs), Some(tab_uuid(1)));
    }

    #[test]
    fn resolve_uses_session_id_before_broader_most_recent_fallback() {
        let wanted = "019d1e81-b43e-7552-bd90-03baf5a80330";
        let tabs = vec![
            tab(
                1,
                vec![session(
                    "codex",
                    "019d33cd-6084-78c1-a0c4-8de2a6142049",
                    "/a",
                    100.0,
                )],
            ),
            tab(2, vec![session("codex", wanted, "/a", 1.0)]),
        ];
        let mut t = target("Codex");
        t.session_id = Some(wanted.into());
        assert_eq!(resolve(&t, &tabs), Some(tab_uuid(2)));
    }

    #[test]
    fn explicit_tab_id_wins_when_it_exists() {
        let tabs = vec![tab(1, vec![]), tab(2, vec![])];
        let mut t = target("Codex");
        t.tab_id = Some(tab_uuid(2));
        assert_eq!(resolve(&t, &tabs), Some(tab_uuid(2)));
        t.tab_id = Some(tab_uuid(9));
        assert_eq!(resolve(&t, &tabs), None);
    }

    #[test]
    fn brand_then_title_then_deep_scan() {
        let mut a = tab(1, vec![SessionRoute::default()]);
        let mut b = tab(2, vec![SessionRoute::default()]);
        b.display_title = "Claude".into();
        // Title match.
        assert_eq!(
            resolve(&target("claude"), &[a.clone(), b.clone()]),
            Some(tab_uuid(2))
        );
        // Brand beats title.
        a.display_app_name = Some("Claude".into());
        assert_eq!(
            resolve(&target("Claude Code"), &[a.clone(), b.clone()]),
            Some(tab_uuid(1))
        );
        // Deep scan on another pane.
        let c = tab(
            3,
            vec![
                SessionRoute::default(),
                SessionRoute {
                    active_app_name: Some("Codex".into()),
                    ..Default::default()
                },
            ],
        );
        assert_eq!(resolve(&target("codex"), &[a, b, c]), Some(tab_uuid(3)));
    }

    #[test]
    fn ambiguous_matches_narrow_by_directory_then_activity() {
        let mut a = tab(1, vec![session("claude", "s1", "/work/a", 5.0)]);
        let mut b = tab(2, vec![session("claude", "s2", "/work/b", 1.0)]);
        a.display_app_name = Some("Claude".into());
        b.display_app_name = Some("Claude".into());
        let mut t = target("Claude");
        t.directory = Some("/work/b/src".into());
        assert_eq!(resolve(&t, &[a.clone(), b.clone()]), Some(tab_uuid(2)));
        t.directory = None;
        assert_eq!(resolve(&t, &[a.clone(), b.clone()]), Some(tab_uuid(1)));
        t.session_id = Some("s2".into());
        assert_eq!(resolve(&t, &[a, b]), Some(tab_uuid(2)));
    }

    #[test]
    fn cwd_fallback_picks_latest_activity() {
        let a = tab(
            1,
            vec![SessionRoute {
                current_directory: "/x".into(),
                ..Default::default()
            }],
        );
        let b = tab(
            2,
            vec![SessionRoute {
                current_directory: "/y".into(),
                ..Default::default()
            }],
        );
        let lookup = |c: &[String], dir: &str| {
            assert!(c.contains(&"claude".to_string()));
            match dir {
                "/x" => Some(10.0),
                "/y" => Some(20.0),
                _ => None,
            }
        };
        assert_eq!(
            resolve_with(&target("Claude"), &[a.clone(), b.clone()], &lookup),
            Some(tab_uuid(2))
        );
        assert_eq!(resolve_with(&target("Claude"), &[a, b], &|_, _| None), None);
    }

    #[test]
    fn candidates_include_registry_aliases() {
        let c = tool_match_candidates("Claude Code");
        assert_eq!(c[0], "claude");
        assert!(c.iter().any(|x| x == "claude"));
        assert!(tool_match_candidates("  ").is_empty());
        assert_eq!(tool_match_candidates("MyTool"), ["mytool"]);
    }
}

//! Ports of `Telemetry/Providers/ClaudeCodeContentProvider.swift` and
//! `CodexContentProvider.swift`: read a finished run's transcript from the
//! files the AI CLI writes (TEL-004, TEL-005).
//!
//! Both only read. Paths come from the user's home: `~/.claude/projects`,
//! `~/.codex/sessions` and `~/.codex/state_5.sqlite` belong to the CLIs,
//! not to either Chau7 app.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Duration, Local, Utc};
use rusqlite::{Connection, OpenFlags, OptionalExtension};

use super::run_content::{ExtractedRunContent, RunContentProvider};
use super::token_metrics::{CostSource, TelemetryMetricState, TokenUsage, TokenUsageSource};
use super::turn::{TelemetryTurn, TurnRole};
use super::{claude_transcript, codex_rollout};

fn positive(value: i64) -> Option<i64> {
    (value > 0).then_some(value)
}

fn transcript_content(
    provider: &str,
    model: Option<String>,
    turns: Vec<TelemetryTurn>,
    usage: TokenUsage,
    tool_calls: Vec<super::turn::TelemetryToolCall>,
    raw_ref: String,
    truncated: bool,
) -> ExtractedRunContent {
    let estimated_cost = usage
        .has_any_tokens()
        .then(|| super::pricing::pricing(model.as_deref(), Some(provider)))
        .flatten()
        .map(|p| p.estimate(&usage));
    ExtractedRunContent {
        model,
        turns,
        total_input_tokens: positive(usage.input_tokens),
        total_cached_input_tokens: positive(usage.cached_input_tokens),
        total_cache_creation_input_tokens: positive(usage.cache_creation_input_tokens),
        total_cache_read_input_tokens: positive(usage.cache_read_input_tokens),
        total_output_tokens: positive(usage.output_tokens),
        total_reasoning_output_tokens: positive(usage.reasoning_output_tokens),
        cost_usd: estimated_cost,
        token_usage_source: Some(TokenUsageSource::TranscriptDelta),
        token_usage_state: if truncated {
            TelemetryMetricState::Estimated
        } else {
            TelemetryMetricState::Complete
        },
        cost_source: Some(if estimated_cost.is_some() {
            CostSource::Estimated
        } else {
            CostSource::Unavailable
        }),
        cost_state: if estimated_cost.is_some() {
            TelemetryMetricState::Estimated
        } else {
            TelemetryMetricState::Missing
        },
        raw_transcript_ref: Some(raw_ref),
        tool_calls,
    }
}

fn entries(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.path()).collect())
        .unwrap_or_default()
}

fn jsonl_files(dir: &Path) -> Vec<PathBuf> {
    entries(dir)
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
        .collect()
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Claude Code: `~/.claude/projects/<cwd with / as ->/<session id>/`.
pub struct ClaudeCodeContentProvider {
    projects_dir: PathBuf,
}

impl ClaudeCodeContentProvider {
    /// `home` is the user's home folder.
    pub fn new(home: &Path) -> Self {
        Self {
            projects_dir: home.join(".claude").join("projects"),
        }
    }

    /// Resolve only the exact encoded CWD folder written by Claude Code.
    /// A suffix or last-components match can select a different project when
    /// multiple checkouts share a name.
    fn resolve_project_dir(&self, cwd: &str) -> Option<PathBuf> {
        let entries = entries(&self.projects_dir);
        if entries.is_empty() {
            return None;
        }
        let normalized = crate::session_restore::claude_project_dir_name(cwd);
        let exact = entries.into_iter().filter(|entry| {
            let name = file_name(entry);
            name == normalized || name == normalized.trim_start_matches('-')
        });
        let mut exact = exact;
        let candidate = exact.next()?;
        exact.next().is_none().then_some(candidate)
    }

    pub fn transcript_files(&self, cwd: &str, session: &str) -> Vec<PathBuf> {
        let Some(project) = self.resolve_project_dir(cwd) else {
            return vec![];
        };
        let flat = project.join(format!("{session}.jsonl"));
        if flat.is_file() {
            return vec![flat];
        }
        let Some(dir) = Self::find_session_dir(&project, session) else {
            return vec![];
        };
        let mut files = jsonl_files(&dir);
        files.extend(jsonl_files(&dir.join("subagents")));
        files.truncate(64);
        files
    }

    fn find_session_dir(project: &Path, session_id: &str) -> Option<PathBuf> {
        let candidate = project.join(session_id);
        if candidate.is_dir() {
            return Some(candidate);
        }
        if session_id.chars().count() < 8 {
            return None;
        }
        let prefix: String = session_id.chars().take(8).collect();
        let mut matches = entries(project)
            .into_iter()
            .filter(|entry| entry.is_dir() && file_name(entry).starts_with(&prefix));
        let candidate = matches.next()?;
        matches.next().is_none().then_some(candidate)
    }
}

impl RunContentProvider for ClaudeCodeContentProvider {
    fn provider_name(&self) -> &str {
        "claude"
    }

    fn can_handle(&self, provider: &str) -> bool {
        let lower = provider.to_lowercase();
        lower.contains("claude") || lower == "anthropic"
    }

    fn extract_content(
        &self,
        run_id: &str,
        session_id: Option<&str>,
        cwd: &str,
        started_at: DateTime<Utc>,
    ) -> Option<ExtractedRunContent> {
        let session_id = session_id.filter(|s| !s.is_empty())?;
        let project = self.resolve_project_dir(cwd)?;
        let session_dir = Self::find_session_dir(&project, session_id)
            .unwrap_or_else(|| project.join(format!("{session_id}.jsonl")));
        let mut files = self.transcript_files(cwd, session_id);
        if files.is_empty() {
            return None;
        }
        let mut truncated = false;
        files.sort_by_key(|p| file_name(p));
        let mut state = claude_transcript::State::new();
        for file in files {
            if let Ok((text, partial)) = bounded_transcript(&file) {
                truncated |= partial;
                claude_transcript::ingest(&text, run_id, started_at, &mut state);
            }
        }
        if state.turns.is_empty() {
            return None;
        }
        Some(transcript_content(
            "claude",
            state.model,
            state.turns,
            state.token_usage,
            state.tool_calls,
            session_dir.to_string_lossy().into_owned(),
            truncated,
        ))
    }
}

/// Codex: `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<ts>-<id>.jsonl`,
/// else the `threads` table of `~/.codex/state_5.sqlite`.
pub struct CodexContentProvider {
    sessions_dir: PathBuf,
    state_db: PathBuf,
}

impl CodexContentProvider {
    pub fn new(home: &Path) -> Self {
        let codex = home.join(".codex");
        Self {
            sessions_dir: codex.join("sessions"),
            state_db: codex.join("state_5.sqlite"),
        }
    }

    fn day_dir(&self, date: DateTime<Local>) -> PathBuf {
        self.sessions_dir
            .join(format!("{:04}", date.year()))
            .join(format!("{:02}", date.month()))
            .join(format!("{:02}", date.day()))
    }

    /// The rollout of `session_id` on the run's day or the day before, else
    /// the path Codex recorded for it.
    pub fn find_rollout(&self, session_id: &str, started_at: DateTime<Utc>) -> Option<PathBuf> {
        let local = started_at.with_timezone(&Local);
        let suffix = format!("-{session_id}.jsonl");
        let mut matches = Vec::new();
        for day in [local, local - Duration::days(1)] {
            matches.extend(
                jsonl_files(&self.day_dir(day))
                    .into_iter()
                    .filter(|file| file_name(file).ends_with(&suffix)),
            );
        }
        match matches.len() {
            1 => Some(matches.remove(0)),
            0 => self.recorded_rollout(session_id, &suffix),
            _ => None,
        }
    }

    /// `codex resume` keeps appending to the rollout of the day the session
    /// was created, which Codex records in its `threads` table.
    fn recorded_rollout(&self, session_id: &str, suffix: &str) -> Option<PathBuf> {
        if !self.state_db.is_file() {
            return None;
        }
        let conn =
            Connection::open_with_flags(&self.state_db, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
        let path = conn
            .query_row(
                "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
                [session_id],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
            .map(PathBuf::from)?;
        (path.is_file() && file_name(&path).ends_with(suffix)).then_some(path)
    }

    fn read_jsonl(
        &self,
        run_id: &str,
        session_id: &str,
        started_at: DateTime<Utc>,
    ) -> Option<ExtractedRunContent> {
        let file = self.find_rollout(session_id, started_at)?;
        let (text, truncated) = bounded_transcript(&file).ok()?;
        let parsed = codex_rollout::parse(&text, run_id, started_at);
        if parsed.turns.is_empty() {
            return None;
        }
        Some(transcript_content(
            "codex",
            parsed.model,
            parsed.turns,
            parsed.token_usage,
            parsed.tool_calls,
            file.to_string_lossy().into_owned(),
            truncated,
        ))
    }

    fn read_sqlite(&self, run_id: &str, session_id: &str) -> Option<ExtractedRunContent> {
        if !self.state_db.is_file() {
            return None;
        }
        let conn =
            Connection::open_with_flags(&self.state_db, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
        let row = conn
            .query_row(
                "SELECT * FROM threads WHERE id = ? LIMIT 1",
                [session_id],
                |r| {
                    let tokens = r.get::<_, Option<i64>>("tokens_used").ok().flatten();
                    let first = r
                        .get::<_, Option<String>>("first_user_message")
                        .ok()
                        .flatten();
                    let rollout = r.get::<_, Option<String>>("rollout_path").ok().flatten();
                    Ok((tokens.unwrap_or(0), first, rollout))
                },
            )
            .optional()
            .ok()
            .flatten()?;
        drop(conn);
        // `read_jsonl` already tried the recorded rollout path.
        let (tokens_used, first_message, rollout_path) = row;
        let mut turns = Vec::new();
        if let Some(message) = first_message.filter(|m| !m.is_empty()) {
            let mut turn = TelemetryTurn::new(run_id, 0, TurnRole::Human);
            turn.id = format!("{run_id}-t0");
            turn.content = Some(message);
            turns.push(turn);
        }
        let has_tokens = tokens_used > 0;
        Some(ExtractedRunContent {
            turns,
            total_input_tokens: positive(tokens_used),
            token_usage_source: has_tokens.then_some(TokenUsageSource::TranscriptSnapshot),
            token_usage_state: if has_tokens {
                TelemetryMetricState::Estimated
            } else {
                TelemetryMetricState::Missing
            },
            cost_source: Some(CostSource::Unavailable),
            cost_state: TelemetryMetricState::Missing,
            raw_transcript_ref: rollout_path,
            ..Default::default()
        })
    }
}

impl RunContentProvider for CodexContentProvider {
    fn provider_name(&self) -> &str {
        "codex"
    }

    fn can_handle(&self, provider: &str) -> bool {
        let lower = provider.to_lowercase();
        lower.contains("codex") || lower.contains("openai") || lower == "gpt"
    }

    fn extract_content(
        &self,
        run_id: &str,
        session_id: Option<&str>,
        _cwd: &str,
        started_at: DateTime<Utc>,
    ) -> Option<ExtractedRunContent> {
        let session_id = session_id?;
        self.read_jsonl(run_id, session_id, started_at)
            .or_else(|| self.read_sqlite(run_id, session_id))
    }
}

/// The providers Swift registers, in order.
pub fn default_providers(home: &Path) -> Vec<Box<dyn RunContentProvider>> {
    vec![
        Box::new(ClaudeCodeContentProvider::new(home)),
        Box::new(CodexContentProvider::new(home)),
    ]
}

/// Never allocate an entire multi-GB transcript. Partial usage stays estimated.
fn bounded_transcript(path: &Path) -> std::io::Result<(String, bool)> {
    use std::io::{Read, Seek, SeekFrom};
    const MAX: u64 = 48 * 1024 * 1024;
    let mut file = std::fs::File::open(path)?;
    let size = file.metadata()?.len();
    let start = size.saturating_sub(MAX);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    file.take(size.min(MAX)).read_to_end(&mut bytes)?;
    if start > 0 {
        if let Some(i) = bytes.iter().position(|b| *b == b'\n') {
            bytes.drain(..=i);
        } else {
            bytes.clear();
        }
    }
    Ok((String::from_utf8_lossy(&bytes).into_owned(), start > 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-providers-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const CLAUDE_LINE: &str = r#"{"type":"assistant","sessionId":"abc","timestamp":"2026-10-10T10:00:01.000Z","requestId":"req1","message":{"id":"m1","role":"assistant","model":"claude-opus","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"x"}}],"usage":{"input_tokens":10,"output_tokens":5}}}"#;

    #[test]
    fn claude_transcript_is_found_by_project_and_session() {
        let home = temp_home("claude");
        let session = home
            .join(".claude/projects/-Users-me-dev-app")
            .join("abcdef12-0000");
        std::fs::create_dir_all(session.join("subagents")).unwrap();
        std::fs::write(session.join("subagents/agent-1.jsonl"), CLAUDE_LINE).unwrap();
        let provider = ClaudeCodeContentProvider::new(&home);
        assert!(provider.can_handle("Claude Code"));
        assert!(provider.can_handle("anthropic"));
        assert!(!provider.can_handle("codex"));
        let started =
            crate::telemetry::date_codec::parse_iso8601(Some("2026-10-10T09:00:00Z")).unwrap();
        // Partial session id (first 8 characters).
        let content = provider
            .extract_content("RUN", Some("abcdef12"), "/Users/me/dev/app", started)
            .expect("content");
        assert_eq!(content.model.as_deref(), Some("claude-opus"));
        assert!(!content.turns.is_empty());
        assert_eq!(content.total_input_tokens, Some(10));
        assert_eq!(content.cost_state, TelemetryMetricState::Estimated);
        assert_eq!(content.cost_source, Some(CostSource::Estimated));
        assert!(content.cost_usd.unwrap() > 0.0);
        assert!(
            content
                .raw_transcript_ref
                .unwrap()
                .ends_with("abcdef12-0000")
        );
        // No session id, nothing.
        assert!(
            provider
                .extract_content("RUN", None, "/Users/me/dev/app", started)
                .is_none()
        );
        // A checkout with the same trailing components is a different project.
        assert!(provider.resolve_project_dir("/Volumes/x/dev/app").is_none());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn claude_project_resolution_encodes_spaces_and_punctuation_exactly() {
        let home = temp_home("claude-project-encoding");
        let cwd = "/Volumes/T7 repositories/Application Support/Chau7_3.0";
        let encoded = crate::session_restore::claude_project_dir_name(cwd);
        let project = home.join(".claude/projects").join(encoded);
        std::fs::create_dir_all(&project).unwrap();
        let provider = ClaudeCodeContentProvider::new(&home);

        assert_eq!(provider.resolve_project_dir(cwd), Some(project));
        assert!(
            provider
                .resolve_project_dir("/Volumes/other/Application Support/Chau7_3.0")
                .is_none()
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn claude_session_prefix_must_resolve_to_one_directory() {
        let home = temp_home("claude-prefix");
        let project = home.join(".claude/projects/-Users-me-dev-app");
        std::fs::create_dir_all(project.join("abcdef12-0000")).unwrap();
        std::fs::create_dir_all(project.join("abcdef12-0001")).unwrap();
        assert!(ClaudeCodeContentProvider::find_session_dir(&project, "abcdef12").is_none());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn codex_rollout_then_sqlite_fallback() {
        let home = temp_home("codex");
        let started =
            crate::telemetry::date_codec::parse_iso8601(Some("2026-10-10T09:00:00Z")).unwrap();
        let provider = CodexContentProvider::new(&home);
        assert!(provider.can_handle("codex"));
        assert!(provider.can_handle("OpenAI"));
        assert!(provider.can_handle("gpt"));
        let day = provider.day_dir(started.with_timezone(&Local));
        std::fs::create_dir_all(&day).unwrap();
        let rollout = r#"{"type":"turn_context","timestamp":"2026-10-10T10:00:00Z","payload":{"model":"gpt-5"}}
{"type":"response_item","timestamp":"2026-10-10T10:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"do it"}]}}
{"type":"event_msg","timestamp":"2026-10-10T10:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":3,"reasoning_output_tokens":1}}}}"#;
        let rollout_path = day.join("rollout-2026-10-10T10-00-00-SESS1.jsonl");
        std::fs::write(&rollout_path, rollout).unwrap();
        std::fs::write(day.join("rollout-2026-10-10T10-00-01-SESS10.jsonl"), "{}").unwrap();
        assert_eq!(
            provider.find_rollout("SESS1", started),
            Some(rollout_path.clone())
        );
        let content = provider
            .extract_content("RUN", Some("SESS1"), "/x", started)
            .expect("rollout");
        assert_eq!(content.model.as_deref(), Some("gpt-5"));
        assert!(content.raw_transcript_ref.unwrap().contains("SESS1"));

        // SQLite fallback: one human turn and estimated tokens.
        let db = home.join(".codex/state_5.sqlite");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (id TEXT, tokens_used INTEGER, first_user_message TEXT, rollout_path TEXT);
             INSERT INTO threads VALUES ('S2', 1234, 'hello', '/nowhere.jsonl');",
        )
        .unwrap();
        drop(conn);
        let content = provider
            .extract_content("RUN", Some("S2"), "/x", started)
            .expect("sqlite");
        assert_eq!(content.turns.len(), 1);
        assert_eq!(content.turns[0].id, "RUN-t0");
        assert_eq!(content.turns[0].role, TurnRole::Human);
        assert_eq!(content.total_input_tokens, Some(1234));
        assert_eq!(content.token_usage_state, TelemetryMetricState::Estimated);
        assert_eq!(
            content.token_usage_source,
            Some(TokenUsageSource::TranscriptSnapshot)
        );
        assert!(
            provider
                .extract_content("RUN", None, "/x", started)
                .is_none()
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn codex_resumed_rollout_is_found_through_the_recorded_path() {
        let home = temp_home("codex-resumed");
        let started =
            crate::telemetry::date_codec::parse_iso8601(Some("2026-10-29T09:00:00Z")).unwrap();
        let provider = CodexContentProvider::new(&home);
        // Created three weeks before this run, and still written by `codex resume`.
        let created = home.join(".codex/sessions/2026/10/08");
        std::fs::create_dir_all(&created).unwrap();
        let rollout = created.join("rollout-2026-10-08T06-57-39-OLD1.jsonl");
        std::fs::write(
            &rollout,
            r#"{"type":"turn_context","timestamp":"2026-10-29T10:00:00Z","payload":{"model":"gpt-5"}}
{"type":"response_item","timestamp":"2026-10-29T10:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"again"}]}}"#,
        )
        .unwrap();
        assert_eq!(provider.find_rollout("OLD1", started), None);

        let conn = Connection::open(home.join(".codex/state_5.sqlite")).unwrap();
        conn.execute(
            "CREATE TABLE threads (id TEXT, tokens_used INTEGER, first_user_message TEXT, rollout_path TEXT)",
            [],
        )
        .unwrap();
        for (id, path) in [
            ("OLD1", rollout.to_string_lossy().into_owned()),
            ("GONE", "/nowhere/rollout-GONE.jsonl".into()),
            ("OTHER", rollout.to_string_lossy().into_owned()),
        ] {
            conn.execute(
                "INSERT INTO threads VALUES (?, 0, 'hello', ?)",
                [id, path.as_str()],
            )
            .unwrap();
        }
        drop(conn);

        assert_eq!(
            provider.find_rollout("OLD1", started),
            Some(rollout.clone())
        );
        assert_eq!(provider.find_rollout("GONE", started), None);
        // A recorded path must name the session it is recorded for.
        assert_eq!(provider.find_rollout("OTHER", started), None);
        let content = provider
            .extract_content("RUN", Some("OLD1"), "/x", started)
            .expect("rollout");
        assert_eq!(content.model.as_deref(), Some("gpt-5"));
        // The SQLite fallback no longer re-reads with an out-of-range date.
        let fallback = provider
            .extract_content("RUN", Some("OTHER"), "/x", started)
            .expect("sqlite");
        assert_eq!(fallback.turns.len(), 1);
        let _ = std::fs::remove_dir_all(home);
    }
}

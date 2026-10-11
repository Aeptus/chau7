//! Port of `Runtime/IncrementalTranscriptReader.swift`: token usage read
//! incrementally from Claude Code transcripts (`~/.claude/projects/`), one
//! byte offset per file, complete lines only, each request counted once.
//!
//! Read only on `~/.claude`.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::telemetry::claude_transcript::request_usage_key;

/// Token deltas of one read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TokenDelta {
    pub input: i64,
    pub output: i64,
    pub cache_creation: i64,
    pub cache_read: i64,
}

impl TokenDelta {
    pub fn is_empty(&self) -> bool {
        self.input == 0 && self.output == 0 && self.cache_creation == 0 && self.cache_read == 0
    }
}

/// Reads one Claude session's transcripts as they grow.
#[derive(Debug)]
pub struct IncrementalTranscriptReader {
    session_dir: PathBuf,
    offsets: HashMap<PathBuf, u64>,
    seen: HashSet<String>,
    pub cumulative: TokenDelta,
}

fn entries(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default()
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// `resolveProjectDir`: the folder of `projects_dir` for `cwd` (`/` turned
/// into `-`; exact, suffix either way, without the leading `-`, then the
/// last two path parts).
pub fn resolve_project_dir(projects_dir: &Path, cwd: &str) -> Option<PathBuf> {
    let list = entries(projects_dir);
    let normalized = cwd.replace('/', "-");
    let strip = |s: &str| s.strip_prefix('-').unwrap_or(s).to_string();
    for entry in &list {
        let name = file_name(entry);
        if normalized.ends_with(&name) || name.ends_with(&normalized) || name == normalized {
            return Some(entry.clone());
        }
        if strip(&name) == strip(&normalized) {
            return Some(entry.clone());
        }
    }
    let cwd_parts: Vec<&str> = cwd.split('/').filter(|p| !p.is_empty()).collect();
    let cwd_last_two = cwd_parts[cwd_parts.len().saturating_sub(2)..].join("-");
    for entry in &list {
        let name = file_name(entry);
        let parts: Vec<&str> = name.split('-').filter(|p| !p.is_empty()).collect();
        if parts.len() >= 2 && parts[parts.len() - 2..].join("-") == cwd_last_two {
            return Some(entry.clone());
        }
    }
    None
}

/// `findSessionDir`: `<project>/<id>`, else the entry starting with the
/// id's first 8 characters.
pub fn find_session_dir(project_dir: &Path, session_id: &str) -> Option<PathBuf> {
    let candidate = project_dir.join(session_id);
    if candidate.exists() {
        return Some(candidate);
    }
    let prefix: String = session_id.chars().take(8).collect();
    entries(project_dir)
        .into_iter()
        .find(|e| file_name(e).starts_with(&prefix))
}

fn int(usage: &Map<String, Value>, key: &str) -> i64 {
    let Some(value) = usage.get(key) else {
        return 0;
    };
    value
        .as_i64()
        .or_else(|| {
            value
                .as_f64()
                .filter(|f| f.fract() == 0.0)
                .map(|f| f as i64)
        })
        .unwrap_or(0)
}

impl IncrementalTranscriptReader {
    /// `None` without a session id or when the session folder is not found.
    pub fn new(projects_dir: &Path, cwd: &str, session_id: Option<&str>) -> Option<Self> {
        let session_id = session_id.filter(|s| !s.is_empty())?;
        let project = resolve_project_dir(projects_dir, cwd)?;
        let session_dir = find_session_dir(&project, session_id)?;
        Some(Self {
            session_dir,
            offsets: HashMap::new(),
            seen: HashSet::new(),
            cumulative: TokenDelta::default(),
        })
    }

    /// Lines appended since the last call, as token deltas.
    pub fn read_new_tokens(&mut self) -> TokenDelta {
        let mut delta = TokenDelta::default();
        let files: Vec<PathBuf> = entries(&self.session_dir.join("subagents"))
            .into_iter()
            .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
            .collect();
        for file in files {
            let offset = self.offsets.get(&file).copied().unwrap_or(0);
            let Ok(mut handle) = std::fs::File::open(&file) else {
                continue;
            };
            if handle.seek(SeekFrom::Start(offset)).is_err() {
                continue;
            }
            let mut data = Vec::new();
            if handle.read_to_end(&mut data).is_err() || data.is_empty() {
                continue;
            }
            let Some(last_newline) = data.iter().rposition(|b| *b == b'\n') else {
                continue;
            };
            let safe = last_newline + 1;
            self.offsets.insert(file.clone(), offset + safe as u64);
            let Ok(text) = std::str::from_utf8(&data[..safe]) else {
                continue;
            };
            for line in text.split('\n').filter(|l| !l.is_empty()) {
                let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                let Some(message) = obj.get("message").and_then(Value::as_object) else {
                    continue;
                };
                let Some(usage) = message.get("usage").and_then(Value::as_object) else {
                    continue;
                };
                let role = message
                    .get("role")
                    .and_then(Value::as_str)
                    .or_else(|| obj.get("type").and_then(Value::as_str))
                    .unwrap_or_default();
                if role != "assistant" {
                    continue;
                }
                if let Some(key) = request_usage_key(&obj, message)
                    && !self.seen.insert(key)
                {
                    continue;
                }
                delta.input += int(usage, "input_tokens");
                delta.output += int(usage, "output_tokens");
                delta.cache_creation += int(usage, "cache_creation_input_tokens");
                delta.cache_read += int(usage, "cache_read_input_tokens");
            }
        }
        self.cumulative.input += delta.input;
        self.cumulative.output += delta.output;
        self.cumulative.cache_creation += delta.cache_creation;
        self.cumulative.cache_read += delta.cache_read;
        delta
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-transcript-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn line(request: &str, input: i64, output: i64) -> String {
        format!(
            "{{\"type\":\"assistant\",\"requestId\":\"{request}\",\"message\":{{\"role\":\"assistant\",\"usage\":{{\"input_tokens\":{input},\"output_tokens\":{output},\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":2}}}}}}\n"
        )
    }

    #[test]
    fn project_and_session_dirs_resolve_like_swift() {
        let projects = temp("resolve");
        std::fs::create_dir_all(projects.join("-Users-me-work-app/abcdef12-rest")).unwrap();
        std::fs::create_dir_all(projects.join("-other-x-lib")).unwrap();
        let project = resolve_project_dir(&projects, "/Users/me/work/app").unwrap();
        assert!(project.ends_with("-Users-me-work-app"));
        // Last two parts match.
        let lib = resolve_project_dir(&projects, "/elsewhere/x/lib").unwrap();
        assert!(lib.ends_with("-other-x-lib"));
        assert!(resolve_project_dir(&projects, "/nothing/here/zz").is_none());
        let session = find_session_dir(&project, "abcdef12-9999").unwrap();
        assert!(session.ends_with("abcdef12-rest"));
        assert!(find_session_dir(&project, "zzzzzzzz").is_none());
        let _ = std::fs::remove_dir_all(&projects);
    }

    #[test]
    fn reads_complete_new_lines_once() {
        let projects = temp("read");
        let sub = projects.join("-w-app/sess-1/subagents");
        std::fs::create_dir_all(&sub).unwrap();
        let file = sub.join("a.jsonl");
        std::fs::write(&file, line("r1", 10, 5)).unwrap();
        assert!(IncrementalTranscriptReader::new(&projects, "/w/app", None).is_none());
        let mut reader =
            IncrementalTranscriptReader::new(&projects, "/w/app", Some("sess-1")).unwrap();
        let d = reader.read_new_tokens();
        assert_eq!(
            d,
            TokenDelta {
                input: 10,
                output: 5,
                cache_creation: 1,
                cache_read: 2
            }
        );
        // Nothing new; then a duplicate request, a user line and a partial line.
        assert!(reader.read_new_tokens().is_empty());
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&file)
            .unwrap();
        f.write_all(line("r1", 10, 5).as_bytes()).unwrap();
        f.write_all(b"{\"message\":{\"role\":\"user\",\"usage\":{\"input_tokens\":99}}}\n")
            .unwrap();
        let partial = line("r2", 7, 3);
        f.write_all(&partial.as_bytes()[..20]).unwrap();
        assert!(reader.read_new_tokens().is_empty());
        f.write_all(&partial.as_bytes()[20..]).unwrap();
        assert_eq!(reader.read_new_tokens().input, 7);
        assert_eq!(reader.cumulative.output, 8);
        let _ = std::fs::remove_dir_all(&projects);
    }
}

//! Structured Codex feedback, bounded rollout tailing and optional App Server ingestion.
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub const MAX_READ_BYTES: u64 = 4 * 1024 * 1024;
pub const CATCH_UP_LINES: usize = 2000;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prompt {
    pub call_id: String,
    pub message: String,
    pub options: Vec<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub enum Record {
    Prompt(Prompt),
    Completed(String),
    Started(String),
    TurnCompleted(Option<String>),
    Usage {
        input: i64,
        output: i64,
        cached: i64,
        reasoning: i64,
    },
}
fn text(v: &Value) -> Option<String> {
    v.as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}
pub fn prompt(questions: &Value, call_id: String) -> Option<Prompt> {
    let questions = questions.as_array()?;
    let messages: Vec<_> = questions
        .iter()
        .filter_map(|q| text(&q["question"]))
        .collect();
    if messages.is_empty() {
        return None;
    }
    let options = questions
        .iter()
        .flat_map(|q| q["options"].as_array().into_iter().flatten())
        .filter_map(|o| text(&o["label"]))
        .collect();
    Some(Prompt {
        call_id,
        message: messages.join("\n"),
        options,
    })
}
pub fn parse(line: &str) -> Option<Record> {
    let value: Value = serde_json::from_str(line).ok()?;
    let p = &value["payload"];
    match (value["type"].as_str()?, p["type"].as_str()?) {
        ("response_item", "function_call") if p["name"] == "request_user_input" => {
            let args: Value = serde_json::from_str(p["arguments"].as_str()?).ok()?;
            prompt(&args["questions"], text(&p["call_id"])?).map(Record::Prompt)
        }
        ("response_item", "function_call_output") => Some(Record::Completed(text(&p["call_id"])?)),
        ("event_msg", "task_started") => Some(Record::Started(String::new())),
        ("event_msg", "task_complete") => {
            Some(Record::TurnCompleted(text(&p["last_agent_message"])))
        }
        ("event_msg", "token_count") => {
            let usage = &p["info"]["total_token_usage"];
            if usage["input_tokens"].as_i64().is_none() && usage["output_tokens"].as_i64().is_none()
            {
                return None;
            }
            Some(Record::Usage {
                input: usage["input_tokens"].as_i64().unwrap_or(0).max(0),
                output: usage["output_tokens"].as_i64().unwrap_or(0).max(0),
                cached: usage["cached_input_tokens"].as_i64().unwrap_or(0).max(0),
                reasoning: usage["reasoning_output_tokens"]
                    .as_i64()
                    .unwrap_or(0)
                    .max(0),
            })
        }
        _ => None,
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Prompt(Prompt),
    Resolved {
        call_id: String,
        has_other_pending: bool,
    },
}
#[derive(Debug, Clone)]
enum Call {
    Pending(Prompt, u64),
    Announced,
    Completed,
}
#[derive(Debug, Default)]
pub struct Tracker {
    calls: BTreeMap<String, Call>,
    order: VecDeque<String>,
    pub lines_observed: u64,
    pub structured_records_observed: u64,
}
impl Tracker {
    pub fn pending_count(&self) -> usize {
        self.calls
            .values()
            .filter(|c| !matches!(c, Call::Completed))
            .count()
    }
    pub fn consume(&mut self, record: Record, now_ms: u64) -> Vec<Action> {
        let mut actions = Vec::new();
        match record {
            Record::Prompt(prompt) if !self.calls.contains_key(&prompt.call_id) => {
                self.structured_records_observed += 1;
                self.order.push_back(prompt.call_id.clone());
                self.calls.insert(
                    prompt.call_id.clone(),
                    Call::Pending(prompt, now_ms.saturating_add(250)),
                );
            }
            Record::Completed(id) if !matches!(self.calls.get(&id), Some(Call::Completed)) => {
                self.structured_records_observed += 1;
                let announced = matches!(self.calls.get(&id), Some(Call::Announced));
                if !self.calls.contains_key(&id) {
                    self.order.push_back(id.clone());
                }
                self.calls.insert(id.clone(), Call::Completed);
                if announced {
                    actions.push(Action::Resolved {
                        call_id: id,
                        has_other_pending: self.pending_count() > 0,
                    });
                }
            }
            _ => (),
        }
        while self.order.len() > 1024 {
            let removable = self
                .order
                .iter()
                .position(|id| matches!(self.calls.get(id), Some(Call::Completed)));
            let Some(index) = removable else {
                break;
            };
            if let Some(id) = self.order.remove(index) {
                self.calls.remove(&id);
            }
        }
        actions
    }
    pub fn announce(&mut self, now_ms: u64) -> Vec<Action> {
        let mut actions = Vec::new();
        for call in self.calls.values_mut() {
            if let Call::Pending(prompt, at) = call
                && now_ms >= *at
            {
                actions.push(Action::Prompt(prompt.clone()));
                *call = Call::Announced;
            }
        }
        actions
    }
}

/// Retains byte offset and incomplete line; replacement/truncation restarts bounded catch-up.
#[derive(Debug)]
pub struct Reader {
    path: PathBuf,
    offset: u64,
    identity: Option<(u64, u64)>,
    partial: Vec<u8>,
    initialized: bool,
    skip_partial: bool,
    pub lines_observed: u64,
}
impl Reader {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            offset: 0,
            identity: None,
            partial: Vec::new(),
            initialized: false,
            skip_partial: false,
            lines_observed: 0,
        }
    }
    pub fn poll(&mut self) -> std::io::Result<Vec<(Record, bool)>> {
        let mut file = File::open(&self.path)?;
        let meta = file.metadata()?;
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::MetadataExt;
            (meta.dev(), meta.ino())
        };
        #[cfg(not(unix))]
        let identity = (
            meta.created()
                .ok()
                .and_then(|v| v.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos() as u64),
            0,
        );
        let catch_up =
            !self.initialized || self.identity != Some(identity) || meta.len() < self.offset;
        if catch_up {
            self.offset = meta.len().saturating_sub(MAX_READ_BYTES);
            self.skip_partial = self.offset > 0;
            self.partial.clear();
            self.initialized = true;
            self.identity = Some(identity);
        }
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = Vec::new();
        file.take(MAX_READ_BYTES).read_to_end(&mut bytes)?;
        self.offset += bytes.len() as u64;
        self.partial.extend(bytes);
        let mut lines = Vec::new();
        let mut start = 0;
        for (index, byte) in self.partial.iter().enumerate() {
            if *byte == b'\n' {
                if self.skip_partial {
                    self.skip_partial = false;
                } else if let Ok(line) = std::str::from_utf8(&self.partial[start..index]) {
                    lines.push(line.to_owned());
                }
                start = index + 1;
            }
        }
        self.partial.drain(..start);
        if self.partial.len() as u64 >= MAX_READ_BYTES {
            self.partial.clear();
            self.skip_partial = true;
        }
        self.lines_observed = self.lines_observed.saturating_add(lines.len() as u64);
        if catch_up && lines.len() > CATCH_UP_LINES {
            lines.drain(..lines.len() - CATCH_UP_LINES);
        }
        Ok(lines
            .into_iter()
            .filter_map(|line| parse(&line).map(|r| (r, catch_up)))
            .collect())
    }
}
/// Discovery remains read only and bounded even with a large provider archive.
pub fn locate(sessions: &Path, native_id: &str) -> Option<PathBuf> {
    uuid::Uuid::parse_str(native_id).ok()?;
    let mut directories = vec![(sessions.to_path_buf(), 0usize)];
    let mut examined = 0;
    while let Some((dir, depth)) = directories.pop() {
        let mut entries: Vec<_> = std::fs::read_dir(dir)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .take(10000usize.saturating_sub(examined))
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            examined += 1;
            if examined > 10000 {
                return None;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_file()
                && name.ends_with(".jsonl")
                && name.to_lowercase().contains(&native_id.to_lowercase())
            {
                return Some(entry.path());
            }
            if kind.is_dir() && depth < 3 {
                directories.push((entry.path(), depth + 1));
            }
        }
    }
    None
}
pub fn retry_delay_ms(attempt: u32) -> u64 {
    if attempt >= 20 {
        60000
    } else {
        (250.0 * 1.45f64.powi(attempt as i32)).min(2000.0) as u64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum InteractionKind {
    UserInput,
    Approval,
}
#[derive(Debug, Clone)]
pub struct Interaction {
    pub id: String,
    pub kind: Option<InteractionKind>,
    pub thread_id: Option<String>,
    pub prompt: Option<Prompt>,
}
pub fn parse_app_server(line: &str) -> Option<Interaction> {
    let value: Value = serde_json::from_str(line).ok()?;
    let method = value["method"].as_str()?;
    let p = &value["params"];
    let id = |v: &Value| text(v).or_else(|| v.as_i64().map(|i| i.to_string()));
    let (request, kind) = if method == "tool/requestUserInput" {
        (id(&value["id"]), Some(InteractionKind::UserInput))
    } else if method.to_lowercase().contains("requestapproval") {
        (id(&value["id"]), Some(InteractionKind::Approval))
    } else if method == "serverRequest/resolved" {
        (id(&p["requestId"]), None)
    } else {
        return None;
    };
    let request = request?;
    let prompt = if kind == Some(InteractionKind::UserInput) {
        Some(prompt(&p["questions"], request.clone())?)
    } else {
        None
    };
    Some(Interaction {
        id: request,
        kind,
        thread_id: text(&p["threadId"]),
        prompt,
    })
}
#[derive(Debug, Default)]
pub struct InteractionTracker {
    pending: BTreeMap<String, InteractionKind>,
}
impl InteractionTracker {
    pub fn consume(
        &mut self,
        interaction: &Interaction,
    ) -> (Option<InteractionKind>, Vec<InteractionKind>) {
        let resolved = if let Some(kind) = interaction.kind {
            self.pending.insert(interaction.id.clone(), kind);
            None
        } else {
            self.pending.remove(&interaction.id)
        };
        (resolved, self.pending.values().copied().collect())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_usage_retains_reported_reasoning() {
        let line = r#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":8,"cached_input_tokens":3,"reasoning_output_tokens":2}}}}"#;
        assert_eq!(
            parse(line),
            Some(Record::Usage {
                input: 10,
                output: 8,
                cached: 3,
                reasoning: 2
            })
        );
    }
    #[test]
    fn debounce_overlap_and_resolutions() {
        let mut tracker = Tracker::default();
        let p = Prompt {
            call_id: "c".into(),
            message: "Choose?".into(),
            options: vec!["One".into()],
        };
        assert!(tracker.consume(Record::Prompt(p.clone()), 0).is_empty());
        assert!(
            tracker
                .consume(Record::Completed("c".into()), 200)
                .is_empty()
        );
        assert!(tracker.announce(300).is_empty());
        tracker.consume(Record::Prompt(p.clone()), 400);
        assert_eq!(tracker.pending_count(), 0);
        let mut next = p;
        next.call_id = "new".into();
        tracker.consume(Record::Prompt(next.clone()), 400);
        assert_eq!(tracker.announce(650), vec![Action::Prompt(next)]);
        assert_eq!(
            tracker.consume(Record::Completed("new".into()), 700),
            vec![Action::Resolved {
                call_id: "new".into(),
                has_other_pending: false
            }]
        );
    }
    #[test]
    fn parser_requires_structured_questions_and_ids() {
        let line = r#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"c","arguments":"{\"questions\":[{\"question\":\"Choose\",\"options\":[{\"label\":\"A\"}]}]}"}}"#;
        assert!(
            matches!(parse(line),Some(Record::Prompt(Prompt{message, ..})) if message=="Choose")
        );
        assert!(parse("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\"}}").is_none());
        assert_eq!(retry_delay_ms(20), 60000);
        assert_eq!(retry_delay_ms(0), 250);
    }
    #[test]
    fn tail_catches_up_once_and_waits_for_complete_line() {
        let path =
            std::env::temp_dir().join(format!("next-feedback-{}.jsonl", uuid::Uuid::new_v4()));
        let line = "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c\"}}";
        std::fs::write(&path, format!("{line}\n")).unwrap();
        let mut reader = Reader::new(path.clone());
        assert_eq!(
            reader.poll().unwrap(),
            vec![(Record::Completed("c".into()), true)]
        );
        assert!(reader.poll().unwrap().is_empty());
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        file.write_all(line.as_bytes()).unwrap();
        assert!(reader.poll().unwrap().is_empty());
        file.write_all(b"\n").unwrap();
        assert_eq!(
            reader.poll().unwrap(),
            vec![(Record::Completed("c".into()), false)]
        );
        std::fs::remove_file(&path).unwrap();
    }
    #[test]
    fn app_server_pending_approval_precedence_and_resolution() {
        let requested=parse_app_server(r#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread"}}"#).unwrap();
        assert_eq!(requested.id, "7");
        let mut tracker = InteractionTracker::default();
        assert_eq!(
            tracker.consume(&requested).1,
            vec![InteractionKind::Approval]
        );
        let resolved =
            parse_app_server(r#"{"method":"serverRequest/resolved","params":{"requestId":7}}"#)
                .unwrap();
        assert_eq!(
            tracker.consume(&resolved),
            (Some(InteractionKind::Approval), vec![])
        );
    }
}

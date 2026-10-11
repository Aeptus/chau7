//! Bounded incremental OSC 9 parsing and current Swift AI notification vocabulary.
//! The parser retains at most 64 KiB, including the four-byte introducer.

use crate::ai::event::{AiEvent, AiEventReliability, AiEventSource};

const PREFIX: &[u8] = b"\x1b]9;";
pub const MAX_BUFFERED_BYTES: usize = 65_536;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Chau7 { key: String, value: String },
    Foreign { message: String },
}

#[derive(Default)]
pub struct Parser {
    prefix_matched: usize,
    payload: Option<Vec<u8>>,
}

impl Parser {
    pub fn ingest(&mut self, bytes: &[u8]) -> Vec<Event> {
        let mut events = Vec::new();
        for &byte in bytes {
            if let Some(payload) = self.payload.as_mut() {
                let st = byte == b'\\' && payload.last() == Some(&0x1b);
                if byte == 7 || st {
                    if st {
                        payload.pop();
                    }
                    if let Some(event) = parse_payload(payload) {
                        events.push(event);
                    }
                    self.payload = None;
                    self.prefix_matched = 0;
                } else if payload.len() + PREFIX.len() < MAX_BUFFERED_BYTES {
                    payload.push(byte);
                } else {
                    // Drop an oversized incomplete sequence. Preserve only a
                    // potential introducer suffix, including the current byte.
                    let mut suffix = payload.iter().rev().take(3).copied().collect::<Vec<_>>();
                    suffix.reverse();
                    suffix.push(byte);
                    self.payload = None;
                    self.prefix_matched = 0;
                    for byte in suffix {
                        self.scan_prefix(byte);
                    }
                }
            } else {
                self.scan_prefix(byte);
            }
        }
        events
    }

    fn scan_prefix(&mut self, byte: u8) {
        if byte == PREFIX[self.prefix_matched] {
            self.prefix_matched += 1;
            if self.prefix_matched == PREFIX.len() {
                self.payload = Some(Vec::new());
                self.prefix_matched = 0;
            }
        } else {
            self.prefix_matched = usize::from(byte == PREFIX[0]);
        }
    }
}

fn parse_payload(bytes: &[u8]) -> Option<Event> {
    let text = std::str::from_utf8(bytes).ok()?.trim();
    if text.is_empty() {
        return None;
    }
    if bytes.starts_with(b"chau7;") {
        let (key, value) = text.strip_prefix("chau7;")?.split_once('=')?;
        let (key, value) = (key.trim(), value.trim());
        if key.is_empty() || value.is_empty() {
            return None;
        }
        Some(Event::Chau7 {
            key: key.into(),
            value: value.into(),
        })
    } else {
        Some(Event::Foreign {
            message: text.into(),
        })
    }
}

/// Current `classifyForeignDesktopNotification`, with provider context required
/// by `foreign_event` rather than guessing that every OSC 9 comes from Codex.
pub fn classify_foreign(message: &str) -> Option<&'static str> {
    let text = message.trim();
    let lower = text.to_lowercase();
    if text.starts_with("Approval requested:")
        || text.starts_with("Approval requested by")
        || text.starts_with("Codex wants to edit")
    {
        Some("permission")
    } else if text.starts_with("Question requested:")
        || text.starts_with("Questions requested:")
        || text == "Question requested"
    {
        Some("waiting_input")
    } else if text.starts_with("Plan mode prompt:") {
        Some("attention_required")
    } else if ["permission", "approval", "wants to"]
        .iter()
        .any(|part| lower.contains(part))
    {
        Some("permission")
    } else if ["waiting for", "needs your input", "input requested"]
        .iter()
        .any(|part| lower.contains(part))
    {
        Some("waiting_input")
    } else if ["needs your attention", "elicitation"]
        .iter()
        .any(|part| lower.contains(part))
    {
        Some("attention_required")
    } else if lower == "agent turn complete"
        || ["agent turn complete:", "codex finished", "task finished"]
            .iter()
            .any(|part| lower.starts_with(part))
    {
        Some("finished")
    } else {
        None
    }
}

pub fn foreign_event(
    message: &str,
    provider: Option<&str>,
    display_tool: Option<&str>,
    directory: &str,
    session_id: Option<&str>,
    timestamp: &str,
) -> Option<AiEvent> {
    let source = AiEventSource::for_provider(provider)?;
    let kind = classify_foreign(message)?;
    let tool = display_tool.or(provider)?;
    let mut event = AiEvent::new(source, kind, tool, message, timestamp);
    event.directory = Some(directory.into());
    event.session_id = session_id.map(str::to_owned);
    event.producer = Some("terminal_osc9".into());
    event.reliability = AiEventReliability::Authoritative;
    Some(event)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_chunk_boundaries_preserve_bel_st_unicode_and_order() {
        let bytes = b"noise\x1b]9;chau7;exit=3\x07\x1b]9;Approval requested: edit\x1b\\\x1b]9;chau7;branch=feat/\xc3\xa9\x07";
        let expected = vec![
            Event::Chau7 {
                key: "exit".into(),
                value: "3".into(),
            },
            Event::Foreign {
                message: "Approval requested: edit".into(),
            },
            Event::Chau7 {
                key: "branch".into(),
                value: "feat/é".into(),
            },
        ];
        for split in 0..=bytes.len() {
            let mut parser = Parser::default();
            let mut actual = parser.ingest(&bytes[..split]);
            actual.extend(parser.ingest(&bytes[split..]));
            assert_eq!(actual, expected, "split {split}");
        }
        let mut parser = Parser::default();
        let actual: Vec<_> = bytes.iter().flat_map(|b| parser.ingest(&[*b])).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn malformed_empty_and_foreign_prefix_contract() {
        let mut parser = Parser::default();
        assert_eq!(parser.ingest(b"\x1b]9; \x07\x1b]9;chau7;bad\x07\x1b]9;chau7; =x\x07\x1b]9;chau7;a= \x07\x1b]9;\xff\x07"), vec![]);
        assert_eq!(
            parser.ingest(b"\x1b]9; chau7;branch=x \x07"),
            vec![Event::Foreign {
                message: "chau7;branch=x".into()
            }]
        );
        assert_eq!(
            parser.ingest(b"\x1b]9;chau7; key = value=x \x07"),
            vec![Event::Chau7 {
                key: "key".into(),
                value: "value=x".into()
            }]
        );
    }

    #[test]
    fn repeated_noise_and_oversized_input_are_bounded_and_recover() {
        let mut parser = Parser::default();
        parser.ingest(b"\x1b]9;");
        for _ in 0..20 {
            parser.ingest(&vec![b'x'; MAX_BUFFERED_BYTES]);
            assert!(
                parser
                    .payload
                    .as_ref()
                    .is_none_or(|p| p.len() + PREFIX.len() <= MAX_BUFFERED_BYTES)
            );
            assert!(parser.prefix_matched < PREFIX.len());
        }
        assert_eq!(
            parser.ingest(b"\x1b\x1b]9;done\x07"),
            vec![Event::Foreign {
                message: "done".into()
            }]
        );
    }

    #[test]
    fn oversized_sequence_preserves_split_prefix_suffix() {
        let mut parser = Parser::default();
        parser.ingest(b"\x1b]9;");
        parser.ingest(&vec![b'x'; MAX_BUFFERED_BYTES - PREFIX.len() - 2]);
        parser.ingest(b"\x1b]9");
        assert_eq!(
            parser.ingest(b";task finished\x1b\\"),
            vec![Event::Foreign {
                message: "task finished".into()
            }]
        );
    }

    #[test]
    fn current_foreign_notification_vocabulary_requires_detected_provider() {
        for (message, kind) in [
            ("Approval requested by helper", "permission"),
            ("Codex wants to edit a file", "permission"),
            ("Questions requested: choose", "waiting_input"),
            ("Question requested", "waiting_input"),
            ("Plan mode prompt: approve", "attention_required"),
            ("Tool needs your input", "waiting_input"),
            ("ELICITATION", "attention_required"),
            ("Agent turn complete: done", "finished"),
            ("Codex finished working", "finished"),
        ] {
            assert_eq!(classify_foreign(message), Some(kind));
            assert!(foreign_event(message, None, Some("Codex"), "/repo", None, "now").is_none());
            let event = foreign_event(
                message,
                Some("claude"),
                Some("Claude Code"),
                "/repo",
                Some("native-session"),
                "now",
            )
            .unwrap();
            assert_eq!(event.source, AiEventSource::claude_code());
            assert_eq!(event.event_type, kind);
            assert_eq!(event.reliability, AiEventReliability::Authoritative);
            assert_eq!(event.producer.as_deref(), Some("terminal_osc9"));
            assert_eq!(event.session_id.as_deref(), Some("native-session"));
        }
        assert!(classify_foreign("Package installed successfully").is_none());
        assert!(classify_foreign("").is_none());
        assert!(
            foreign_event("task finished", Some("unknown"), None, "/repo", None, "now").is_none()
        );
    }
}

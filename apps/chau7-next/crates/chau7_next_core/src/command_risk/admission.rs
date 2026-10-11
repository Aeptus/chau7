//! Submission review and the exact deferred-input context fence.
//! No terminal, filesystem or provider side effects occur in this module.
use crate::shell_session::{apply_line_editing, sanitize_input_for_buffer};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Context {
    pub terminal_id: u64,
    pub shell_pid: u64,
    pub directory: Option<String>,
    pub input_prefix: String,
    pub input_revision: u64,
}
impl Context {
    pub fn accepts(&self, current: Option<&Self>) -> bool {
        self.shell_pid > 0 && current == Some(self)
    }
}

/// Current unsubmitted line, including already queued user input. Completed
/// lines are excluded, and editing uses the same semantics as ShellSession.
pub fn pending_prefix<I, S>(prefix: &str, chunks: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut buffer = prefix.to_string();
    for chunk in chunks {
        apply_line_editing(&mut buffer, &sanitize_input_for_buffer(chunk.as_ref()));
        if let Some(last) = buffer.rfind(['\r', '\n']) {
            buffer.drain(..last + 1);
        }
    }
    buffer
}

/// Review the whole input plan before its first PTY write. This preserves a
/// typed prefix, clear-line controls, bracketed paste and delayed bare Enter.
pub fn submitted_command<I, S>(prefix: &str, chunks: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut buffer = prefix.to_string();
    let mut submission = false;
    for chunk in chunks {
        let text = sanitize_input_for_buffer(chunk.as_ref());
        submission |= text.contains(['\r', '\n']);
        apply_line_editing(&mut buffer, &text);
    }
    submission.then_some(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn submissions_review_existing_prefix_and_the_complete_delayed_plan() {
        assert_eq!(
            submitted_command("kill ", ["-- -$$\r"]).as_deref(),
            Some("kill -- -$$\r")
        );
        assert_eq!(
            submitted_command(
                "stale ",
                ["\x15", "\x1b[200~pkill Chau7Next\x1b[201~", "\r"]
            )
            .as_deref(),
            Some("pkill Chau7Next\r")
        );
        assert_eq!(
            submitted_command("rm -rX", ["\x7ff /\n"]).as_deref(),
            Some("rm -rf /\n")
        );
        assert!(submitted_command("kill ", ["123"]).is_none());
        assert!(submitted_command("", ["\x1b[A"]).is_none());
    }
    #[test]
    fn queued_prefix_uses_current_tracker_editing_and_excludes_completed_lines() {
        assert_eq!(
            pending_prefix("old", ["\x15", "kill ", "123\x08"]),
            "kill 12"
        );
        assert_eq!(pending_prefix("old", ["\r", "new"]), "new");
        assert_eq!(pending_prefix("old", ["\x03"]), "");
    }
    #[test]
    fn approval_requires_every_actual_context_facet_and_immediate_revision() {
        let ctx = Context {
            terminal_id: 7,
            shell_pid: 42,
            directory: Some("/repo".into()),
            input_prefix: "kill 42".into(),
            input_revision: 9,
        };
        assert!(ctx.accepts(Some(&ctx)));
        assert!(!ctx.accepts(None));
        let mut changed = ctx.clone();
        changed.terminal_id += 1;
        assert!(!ctx.accepts(Some(&changed)));
        changed = ctx.clone();
        changed.shell_pid += 1;
        assert!(!ctx.accepts(Some(&changed)));
        changed = ctx.clone();
        changed.directory = Some("/other".into());
        assert!(!ctx.accepts(Some(&changed)));
        changed = ctx.clone();
        changed.input_prefix.clear();
        assert!(!ctx.accepts(Some(&changed)));
        changed = ctx.clone();
        changed.input_revision += 1;
        assert!(!ctx.accepts(Some(&changed)));
        changed = ctx.clone();
        changed.shell_pid = 0;
        assert!(!changed.accepts(Some(&changed)));
    }
}

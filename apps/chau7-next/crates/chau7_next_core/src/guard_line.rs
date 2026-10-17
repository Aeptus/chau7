//! Checking the line being typed against the command guard.
//!
//! Swift's guard receives the command text from its caller (and is never
//! called). Chau7 Next only sees the screen, so the typed command is the
//! screen line minus an unknown prompt: every text after a prompt marker is a
//! candidate, and the guard's verdict over the candidates decides.

use crate::command_risk::{CheckResult, DangerousCommandGuard};

/// Characters that usually end a prompt, each followed by a space.
const PROMPT_MARKERS: [&str; 6] = ["$ ", "# ", "% ", "> ", "❯ ", "➜ "];

/// Texts that may be the typed command, longest first. With no prompt marker
/// the whole line is the only candidate.
pub fn candidates(line: &str) -> Vec<String> {
    let line = line.trim_end();
    let mut found = Vec::new();
    for (i, _) in line.char_indices() {
        let rest = &line[i..];
        for marker in PROMPT_MARKERS {
            if let Some(command) = rest.strip_prefix(marker) {
                let command = command.trim();
                if !command.is_empty() && !found.iter().any(|c| c == command) {
                    found.push(command.to_string());
                }
            }
        }
    }
    if found.is_empty() {
        let whole = line.trim();
        if !whole.is_empty() {
            found.push(whole.to_string());
        }
    }
    found
}

/// The guard's verdict on the typed line. Blocked beats Allowed beats
/// NeedsConfirmation beats Safe; among risky candidates the shortest (the
/// one with the least prompt text in it) is reported.
pub fn check_line(
    guard: &DangerousCommandGuard,
    line: &str,
    directory: Option<&str>,
) -> CheckResult {
    let mut allowed = false;
    let mut risky: Option<CheckResult> = None;
    for candidate in candidates(line) {
        match guard.check(&candidate, directory) {
            CheckResult::Blocked => return CheckResult::Blocked,
            CheckResult::Allowed => allowed = true,
            CheckResult::Safe => {}
            CheckResult::NeedsConfirmation {
                command,
                matched_pattern,
            } => {
                let shorter = match &risky {
                    Some(CheckResult::NeedsConfirmation { command: old, .. }) => {
                        command.len() < old.len()
                    }
                    _ => true,
                };
                if shorter {
                    risky = Some(CheckResult::NeedsConfirmation {
                        command,
                        matched_pattern,
                    });
                }
            }
        }
    }
    if allowed {
        return CheckResult::Allowed;
    }
    risky.unwrap_or(CheckResult::Safe)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guard() -> DangerousCommandGuard {
        DangerousCommandGuard::default()
    }

    #[test]
    fn candidates_follow_prompt_markers() {
        assert_eq!(candidates("root@vm:~# rm -rf x  "), ["rm -rf x"]);
        assert_eq!(candidates("~ % echo \"a $ b\""), ["echo \"a $ b\"", "b\""]);
        assert_eq!(candidates("plain words"), ["plain words"]);
        assert!(candidates("   ").is_empty());
    }

    #[test]
    fn risky_line_needs_confirmation_with_the_command_only() {
        let result = check_line(&guard(), "user@host:~/p$ rm -rf /tmp/x", None);
        let CheckResult::NeedsConfirmation { command, .. } = result else {
            panic!("{result:?}");
        };
        assert_eq!(command, "rm -rf /tmp/x");
    }

    #[test]
    fn safe_line_passes() {
        assert_eq!(check_line(&guard(), "~ % ls -la", None), CheckResult::Safe);
        assert_eq!(check_line(&guard(), "", None), CheckResult::Safe);
    }

    #[test]
    fn allow_and_block_lists_apply_to_the_typed_command() {
        let mut g = guard();
        g.add_to_allow_list("rm -rf /tmp/x");
        assert_eq!(
            check_line(&g, "$ rm -rf /tmp/x", None),
            CheckResult::Allowed
        );
        g.add_to_block_list("rm -rf /tmp/x");
        assert_eq!(
            check_line(&g, "$ rm -rf /tmp/x", None),
            CheckResult::Blocked
        );
    }

    #[test]
    fn homoglyph_in_the_prompt_alone_is_ignored() {
        assert_eq!(
            check_line(&guard(), "ｕｓｅｒ$ ls", None),
            CheckResult::Safe
        );
        assert!(matches!(
            check_line(&guard(), "$ ｌs", None),
            CheckResult::NeedsConfirmation { .. }
        ));
    }

    #[test]
    fn disabled_guard_is_safe() {
        let mut g = guard();
        g.is_enabled = false;
        assert_eq!(check_line(&g, "$ rm -rf /", None), CheckResult::Safe);
    }
}

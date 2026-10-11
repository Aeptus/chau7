//! Best-effort detection of remote commands that target the Chau7 process.
//!
//! Port of `RemoteProtection.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//!
//! Threat model (same as Swift): a speed bump, not a sandbox. It catches common
//! direct invocations (kill, killall, pkill, launchctl, osascript) but can be
//! bypassed via shell metacharacters, aliases, pipes or indirect execution. The
//! real security boundary is the iOS approval gate.

/// Characters Swift's `Character.isNewline` accepts.
fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Describe the process-termination action `input` would perform on Chau7, if any.
pub fn flagged_termination_action(input: &str) -> Option<&'static str> {
    for raw_line in input.split(is_newline) {
        let line = raw_line.trim().to_lowercase();
        if line.is_empty() {
            continue;
        }

        if (line.starts_with("kill ") || line.starts_with("killall ") || line.starts_with("pkill "))
            && line.contains("chau7")
        {
            return Some("Terminate Chau7 on Mac");
        }

        if line.starts_with("launchctl ") && line.contains("chau7") {
            return Some("Disable Chau7 launch services on Mac");
        }

        if line.starts_with("osascript ") && line.contains("quit") && line.contains("chau7") {
            return Some("Quit Chau7 on Mac");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_terminate_chau7_process_commands() {
        assert_eq!(
            flagged_termination_action("killall Chau7"),
            Some("Terminate Chau7 on Mac")
        );
        assert_eq!(
            flagged_termination_action("pkill -f chau7-helper"),
            Some("Terminate Chau7 on Mac")
        );
        assert_eq!(
            flagged_termination_action("kill $(pgrep -f Chau7)"),
            Some("Terminate Chau7 on Mac")
        );
    }

    #[test]
    fn detects_launchctl_disable_commands() {
        assert_eq!(
            flagged_termination_action("launchctl bootout gui/501/chau7-agent"),
            Some("Disable Chau7 launch services on Mac")
        );
    }

    #[test]
    fn detects_quit_via_osascript() {
        assert_eq!(
            flagged_termination_action("osascript -e 'quit app \"Chau7\"'"),
            Some("Quit Chau7 on Mac")
        );
    }

    #[test]
    fn handles_multiline_input() {
        assert_eq!(
            flagged_termination_action("echo safe\nkillall chau7"),
            Some("Terminate Chau7 on Mac")
        );
        assert_eq!(
            flagged_termination_action("echo safe\r\nkillall chau7"),
            Some("Terminate Chau7 on Mac")
        );
    }

    #[test]
    fn ignores_unrelated_commands() {
        assert_eq!(flagged_termination_action("echo hello"), None);
        assert_eq!(flagged_termination_action("killall Finder"), None);
        assert_eq!(flagged_termination_action("launchctl list"), None);
    }

    #[test]
    fn requires_trailing_space_after_verb() {
        assert_eq!(flagged_termination_action("kill"), None);
        assert_eq!(flagged_termination_action("killchau7"), None);
    }
}

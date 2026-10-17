//! Shell command events raised when a command finishes
//! (`ShellEventDetector.commandFinished` in `Monitoring/`): `exit_code_match`
//! for watched exit codes, `command_failed` for a non-zero exit,
//! `command_finished` only when "notify on all command completion" is on,
//! then `process_ended`. Events use source `shell` and tool `Shell`.

use super::settings::ShellEventConfig;

/// `(type, message)` pairs for a finished command, in emission order.
pub fn command_finished_events(
    exit_code: Option<i32>,
    command: Option<&str>,
    config: &ShellEventConfig,
) -> Vec<(&'static str, String)> {
    let code = exit_code.unwrap_or(0);
    let description: String = command
        .map(|c| c.chars().take(100).collect())
        .unwrap_or_else(|| "Command".into());
    let mut events = Vec::new();
    if let Some(c) = exit_code
        && config.watched_exit_codes.contains(&c)
    {
        events.push(("exit_code_match", format!("Exit code {c}: {description}")));
    }
    if code != 0 {
        events.push(("command_failed", format!("Exit {code}: {description}")));
    } else if config.notify_on_all_command_completion {
        events.push(("command_finished", description.clone()));
    }
    events.push(("process_ended", format!("Exit {code}")));
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_command_with_watched_code() {
        let events = command_finished_events(Some(127), Some("nope"), &ShellEventConfig::default());
        assert_eq!(
            events,
            [
                ("exit_code_match", "Exit code 127: nope".to_string()),
                ("command_failed", "Exit 127: nope".to_string()),
                ("process_ended", "Exit 127".to_string()),
            ]
        );
    }

    #[test]
    fn success_only_reports_completion_when_asked() {
        let mut config = ShellEventConfig::default();
        assert_eq!(
            command_finished_events(Some(0), None, &config),
            [("process_ended", "Exit 0".to_string())]
        );
        config.notify_on_all_command_completion = true;
        let long = "x".repeat(150);
        let events = command_finished_events(Some(0), Some(&long), &config);
        assert_eq!(events[0].0, "command_finished");
        assert_eq!(events[0].1.len(), 100);
        // Exit 3 is not watched by default.
        assert_eq!(
            command_finished_events(Some(3), None, &config)[0].0,
            "command_failed"
        );
    }
}

//! Mac-composed remote notification text and authoritative approval risk.
use super::interactive_prompt::RemoteInteractivePromptListPayload;
use super::models::ApprovalRequestPayload;
use serde_json::{Value, json};

fn clean(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|part| !part.is_empty())
}
pub fn location_summary(
    tab: Option<&str>,
    project: Option<&str>,
    branch: Option<&str>,
    directory: Option<&str>,
) -> Option<String> {
    let mut parts = Vec::new();
    if let Some(tab) = clean(tab) {
        parts.push(tab.to_string());
    }
    match (clean(project), clean(branch)) {
        (Some(project), Some(branch)) => parts.push(format!("{project} ({branch})")),
        (Some(part), None) | (None, Some(part)) => parts.push(part.to_string()),
        (None, None) => {}
    }
    if let Some(directory) = clean(directory) {
        parts.push(directory.to_string());
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

pub fn approval_severity(command: &str, flagged: &str, reason: Option<&str>) -> &'static str {
    if destructive(command) || destructive(flagged) {
        "destructive"
    } else if command != flagged
        || reason.is_some_and(|reason| reason.to_lowercase().contains("protect chau7"))
    {
        "protected"
    } else {
        "standard"
    }
}
fn destructive(command: &str) -> bool {
    let c = command.to_lowercase();
    let flag = |flag: char| {
        c.split([' ', '\t']).any(|token| {
            token.starts_with('-') && !token.starts_with("--") && token[1..].contains(flag)
        })
    };
    let word = |word: &str| c.split([' ', '\t', '/']).any(|token| token == word);
    (c.contains("git")
        && ((c.contains("push") && (c.contains("--force") || flag('f')))
            || (c.contains("reset") && c.contains("--hard"))
            || (c.contains("clean") && flag('f'))))
        || ((word("rm") || c.contains("rm -"))
            && (flag('r') || c.contains("-rf") || c.contains("-fr"))
            && (flag('f') || c.contains("-rf") || c.contains("-fr")))
        || c.contains("mkfs")
        || (c.contains("diskutil") && c.contains("erase"))
        || (word("dd") && c.contains("of="))
        || c.contains("> /dev/")
        || c.contains("drop table")
        || c.contains("drop database")
        || c.contains("truncate table")
}
pub fn compose_approval(payload: &ApprovalRequestPayload, spine_seq: Option<u64>) -> Value {
    let mut wire = json!(payload);
    let protected = payload.command != payload.flagged_command;
    wire["push_title"] = json!(if protected {
        "Protected action needs approval".into()
    } else {
        clean(payload.tool_name.as_deref())
            .map(|tool| format!("{tool} needs approval"))
            .unwrap_or_else(|| "Command approval".into())
    });
    if let Some(subtitle) = location_summary(
        payload.tab_title.as_deref(),
        payload.project_name.as_deref(),
        payload.branch_name.as_deref(),
        payload.current_directory.as_deref(),
    ) {
        wire["push_subtitle"] = json!(subtitle);
    }
    wire["push_body"] = json!(if protected {
        &payload.flagged_command
    } else {
        &payload.command
    });
    wire["severity"] = json!(approval_severity(
        &payload.command,
        &payload.flagged_command,
        payload.context_note.as_deref()
    ));
    if let Some(seq) = spine_seq {
        wire["spine_seq"] = json!(seq);
    }
    wire
}
pub fn compose_prompt_list(payload: &RemoteInteractivePromptListPayload) -> Value {
    let mut wire = json!(payload);
    for (prompt, value) in payload
        .prompts
        .iter()
        .zip(wire["prompts"].as_array_mut().into_iter().flatten())
    {
        value["push_title"] = json!(
            clean(Some(&prompt.tool_name))
                .map(|tool| format!("{tool} is waiting"))
                .unwrap_or_else(|| "Interactive prompt".into())
        );
        if let Some(subtitle) = location_summary(
            Some(&prompt.tab_title),
            prompt.project_name.as_deref(),
            prompt.branch_name.as_deref(),
            prompt.current_directory.as_deref(),
        ) {
            value["push_subtitle"] = json!(subtitle);
        }
    }
    wire
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_and_protected_push_preserve_context_and_sequence() {
        let mut p = ApprovalRequestPayload::new("id", "ls", "ls", "now");
        p.tool_name = Some(" Codex ".into());
        p.tab_title = Some("Terminal".into());
        p.project_name = Some("Chau7".into());
        p.branch_name = Some("main".into());
        let wire = compose_approval(&p, Some(42));
        assert_eq!(wire["push_title"], "Codex needs approval");
        assert_eq!(wire["push_subtitle"], "Terminal · Chau7 (main)");
        assert_eq!(wire["severity"], "standard");
        assert_eq!(wire["spine_seq"], 42);
        assert_eq!(wire["request_id"], "id");
        p.flagged_command = "Stop managed session".into();
        let wire = compose_approval(&p, None);
        assert_eq!(wire["severity"], "protected");
        assert_eq!(wire["push_title"], "Protected action needs approval");
        assert_eq!(wire["push_body"], p.flagged_command);
        assert!(wire.get("spine_seq").is_none());
    }
    #[test]
    fn destructive_patterns_match_current_shared_classifier() {
        for command in [
            "git push --force-with-lease",
            "git reset --hard HEAD",
            "git clean -fd",
            "rm -rf /tmp/x",
            "/bin/rm -r -f x",
            "mkfs.ext4 x",
            "diskutil eraseDisk x",
            "dd if=a of=/dev/b",
            "cat x > /dev/disk1",
            "DROP TABLE things",
            "TRUNCATE TABLE things",
        ] {
            assert_eq!(
                approval_severity(command, command, None),
                "destructive",
                "{command}"
            );
        }
        for command in [
            "git push origin main",
            "git reset HEAD",
            "git clean -n",
            "rm -r x",
            "chmod 755 x",
            "add of=x",
        ] {
            assert_eq!(
                approval_severity(command, command, None),
                "standard",
                "{command}"
            );
        }
        assert_eq!(
            approval_severity("ls", "ls", Some("Protect Chau7: reason")),
            "protected"
        );
    }
    #[test]
    fn empty_context_is_omitted_and_directory_remains_verbatim() {
        assert!(location_summary(Some(" "), None, None, None).is_none());
        assert_eq!(
            location_summary(None, None, None, Some("/Users/person/Repo")).as_deref(),
            Some("/Users/person/Repo")
        );
    }
    #[test]
    fn prompt_composition_preserves_pane_multi_select_and_options() {
        let original = json!({"prompts":[{"id":"q","tab_id":1,"tab_title":"Shell","tool_name":"Claude","prompt":"Choose","options":[{"id":"1","label":"Keep","response":"1\r","is_destructive":false}],"detected_at":0.0,"pane_id":"00000000-0000-0000-0000-000000000003","is_multi_select":true}]});
        let payload: RemoteInteractivePromptListPayload =
            serde_json::from_value(original.clone()).unwrap();
        let wire = compose_prompt_list(&payload);
        assert_eq!(wire["prompts"][0]["push_title"], "Claude is waiting");
        for (key, value) in original["prompts"][0].as_object().unwrap() {
            assert_eq!(&wire["prompts"][0][key], value, "{key}");
        }
    }
}

//! Command permissions for MCP clients (`MCP/MCPCommandFilter.swift`).
//!
//! A command line is split into sub-commands on shell operators (outside
//! quotes), each sub-command is reduced to its program name, and the names
//! are checked against the blocked and allowed lists of the matched MCP
//! profile, or of the global settings when no profile matches:
//!
//! 1. blocked names are always rejected,
//! 2. allowed names always pass,
//! 3. anything else depends on the permission mode.
//!
//! One deliberate difference with Swift: the names returned by
//! [`extract_base_commands`] are normalized (base name, lowercased), as the
//! Swift tests expect. Swift returned the raw token, so "Always Allow" on
//! `/bin/rm` stored `/bin/rm`, which never matched again.

use std::collections::HashSet;

use uuid::Uuid;

use crate::mcp_profile::{MCPPermissionMode, MCPProfile, MCPTabContext, best_match};

/// Three-tier result of a check (`MCPCommandVerdict`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandVerdict {
    Allowed,
    /// Hard reject; carries the offending command name.
    Blocked(String),
    /// Ask the user; carries the command name that is not listed.
    NeedsApproval(String),
}

/// The rules that apply to one command: a matched profile's, or the global
/// settings' (`ResolvedPermissions`). Lists hold lowercased names.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedPermissions {
    pub mode: MCPPermissionMode,
    pub allowed: HashSet<String>,
    pub blocked: HashSet<String>,
    pub matched_profile: Option<MCPProfile>,
}

impl ResolvedPermissions {
    /// The global rules.
    pub fn global(mode: MCPPermissionMode, allowed: &[String], blocked: &[String]) -> Self {
        Self {
            mode,
            allowed: lowercased(allowed),
            blocked: lowercased(blocked),
            matched_profile: None,
        }
    }

    /// The rules of a profile.
    pub fn from_profile(profile: &MCPProfile) -> Self {
        Self {
            mode: profile.permission_mode,
            allowed: lowercased(&profile.allowed_commands),
            blocked: lowercased(&profile.blocked_commands),
            matched_profile: Some(profile.clone()),
        }
    }

    /// The profile "Always Allow" adds the command to (`profileID`).
    pub fn profile_id(&self) -> Option<Uuid> {
        self.matched_profile.as_ref().map(|p| p.id)
    }

    /// `sourceName`: "profile: <name>" or "global".
    pub fn source_name(&self) -> String {
        match &self.matched_profile {
            Some(profile) => format!("profile: {}", profile.name),
            None => "global".to_string(),
        }
    }

    /// Line shown in the approval dialog (`requestCommandApproval`).
    pub fn source_info(&self) -> String {
        match &self.matched_profile {
            Some(profile) => format!("Permissions source: profile \"{}\"", profile.name),
            None => "Permissions source: global settings".to_string(),
        }
    }
}

fn lowercased(list: &[String]) -> HashSet<String> {
    list.iter().map(|c| c.to_lowercase()).collect()
}

/// `resolvePermissions(for:)`: the best matching enabled profile for the
/// tab, else the global rules. `home` expands `~` in directory triggers.
pub fn resolve_permissions(
    global: &ResolvedPermissions,
    profiles: &[MCPProfile],
    context: Option<&MCPTabContext>,
    home: Option<&str>,
) -> ResolvedPermissions {
    if let Some(context) = context
        && let Some(profile) = best_match(profiles, context, home)
    {
        return ResolvedPermissions::from_profile(profile);
    }
    global.clone()
}

/// Result of [`check`]: the verdict, plus the names let through only
/// because the mode is Audit Only (the caller logs them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckResult {
    pub verdict: CommandVerdict,
    pub audited: Vec<String>,
}

/// Check a command line (`tab_exec`).
pub fn check(command: &str, permissions: &ResolvedPermissions) -> CheckResult {
    let mut audited = Vec::new();
    for base in extract_base_commands(command) {
        let normalized = normalize_command(&base);
        if permissions.blocked.contains(&normalized) {
            return CheckResult {
                verdict: CommandVerdict::Blocked(base),
                audited,
            };
        }
        if permissions.allowed.contains(&normalized) {
            continue;
        }
        match permissions.mode {
            MCPPermissionMode::AllowAll => {}
            MCPPermissionMode::Allowlist => {
                return CheckResult {
                    verdict: CommandVerdict::Blocked(base),
                    audited,
                };
            }
            MCPPermissionMode::AskUnlisted => {
                return CheckResult {
                    verdict: CommandVerdict::NeedsApproval(base),
                    audited,
                };
            }
            MCPPermissionMode::AuditOnly => audited.push(base),
        }
    }
    CheckResult {
        verdict: CommandVerdict::Allowed,
        audited,
    }
}

/// `checkRawInput` (`tab_send_input`): short input (2 characters or less
/// once trimmed) and input without a final newline are interactive typing
/// and pass; anything else is checked as a command.
pub fn check_raw_input(input: &str, permissions: &ResolvedPermissions) -> CheckResult {
    let trimmed = input.trim();
    if trimmed.chars().count() <= 2 || !(input.ends_with('\n') || input.ends_with('\r')) {
        return CheckResult {
            verdict: CommandVerdict::Allowed,
            audited: Vec::new(),
        };
    }
    check(trimmed, permissions)
}

fn trim_spaces(s: &str) -> &str {
    // Swift `.whitespaces`: horizontal whitespace only.
    s.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
}

/// Split a command line on `;`, `&&`, `||`, `|`, `&`, newlines and `$(`
/// (outside quotes, honoring backslash escapes) and return the program name
/// of each sub-command.
pub fn extract_base_commands(command: &str) -> Vec<String> {
    let mut commands: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut in_single = false;
    let mut in_double = false;
    let mut escape = false;
    let chars: Vec<char> = command.chars().collect();
    let flush = |current: &mut String, commands: &mut Vec<String>| {
        let trimmed = trim_spaces(current);
        if !trimmed.is_empty() {
            commands.push(trimmed.to_string());
        }
        current.clear();
    };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if escape {
            current.push(c);
            escape = false;
            i += 1;
            continue;
        }
        if c == '\\' && !in_single {
            escape = true;
            current.push(c);
            i += 1;
            continue;
        }
        if c == '\'' && !in_double {
            in_single = !in_single;
            current.push(c);
            i += 1;
            continue;
        }
        if c == '"' && !in_single {
            in_double = !in_double;
            current.push(c);
            i += 1;
            continue;
        }
        if !in_single && !in_double {
            let next = chars.get(i + 1).copied();
            if (c == '&' && next == Some('&')) || (c == '|' && next == Some('|')) {
                flush(&mut current, &mut commands);
                i += 2;
                continue;
            }
            if matches!(c, '|' | ';' | '&' | '\n' | '\r') {
                flush(&mut current, &mut commands);
                i += 1;
                continue;
            }
            if c == '$' && next == Some('(') {
                flush(&mut current, &mut commands);
                i += 2;
                continue;
            }
        }
        current.push(c);
        i += 1;
    }
    flush(&mut current, &mut commands);
    commands.iter().filter_map(|c| first_token(c)).collect()
}

/// The program name of one sub-command: skips `VAR=value`, flags, and the
/// prefixes `sudo`, `command`, `env`, `nohup`, `nice`, `time`, `exec`.
fn first_token(command: &str) -> Option<String> {
    const PASSTHROUGH: [&str; 7] = ["sudo", "command", "env", "nohup", "nice", "time", "exec"];
    let tokens: Vec<&str> = command.split_whitespace().collect();
    let first = tokens.first()?;
    for token in &tokens {
        if token.contains('=') && !token.starts_with('=') && !token.starts_with('-') {
            continue;
        }
        if token.starts_with('-') {
            continue;
        }
        let base = normalize_command(token);
        if PASSTHROUGH.contains(&base.as_str()) {
            continue;
        }
        return Some(base);
    }
    Some(normalize_command(first))
}

/// Base name, lowercased: `/usr/bin/RM` gives `rm`, `./run.sh` gives `run.sh`.
pub fn normalize_command(command: &str) -> String {
    let trimmed = command.trim_end_matches('/');
    let base = if trimmed.is_empty() {
        command
    } else {
        trimmed.rsplit('/').next().unwrap_or(trimmed)
    };
    base.to_lowercase()
}

/// `addToAllowedCommands`: add a lowercased command to a list once.
pub fn add_allowed(list: &mut Vec<String>, command: &str) {
    let normalized = command.to_lowercase();
    if !list.contains(&normalized) {
        list.push(normalized);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile_rules::ProfileSwitchTrigger;

    fn global(mode: MCPPermissionMode, allowed: &[&str], blocked: &[&str]) -> ResolvedPermissions {
        let s = |l: &[&str]| l.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        ResolvedPermissions::global(mode, &s(allowed), &s(blocked))
    }

    // MCPCommandFilterTests

    #[test]
    fn extract_base_commands_splits_background_operator() {
        assert_eq!(extract_base_commands("echo ok & rm -rf /"), ["echo", "rm"]);
    }

    #[test]
    fn extract_base_commands_splits_newlines() {
        assert_eq!(extract_base_commands("echo ok\nrm -rf /"), ["echo", "rm"]);
    }

    #[test]
    fn extract_base_commands_does_not_split_quoted_separator_literals() {
        assert_eq!(
            extract_base_commands("printf '&'\nprintf done"),
            ["printf", "printf"]
        );
    }

    #[test]
    fn extract_base_commands_treats_tabs_as_whitespace() {
        assert_eq!(
            extract_base_commands("env\tFOO=bar\t/bin/rm -f /tmp/test"),
            ["rm"]
        );
    }

    #[test]
    fn splits_every_operator_and_subshells() {
        assert_eq!(
            extract_base_commands("a && b || c | d; e $(f x) \"g;h\""),
            ["a", "b", "c", "d", "e", "f"]
        );
        assert_eq!(extract_base_commands("sudo -E nohup git push"), ["git"]);
        assert_eq!(extract_base_commands("echo a\\;b"), ["echo"]);
        assert!(extract_base_commands("   ").is_empty());
    }

    #[test]
    fn normalize_strips_path_and_case() {
        assert_eq!(normalize_command("/usr/bin/RM"), "rm");
        assert_eq!(normalize_command("./run.sh"), "run.sh");
        assert_eq!(normalize_command("dir/"), "dir");
        assert_eq!(normalize_command("/"), "/");
    }

    #[test]
    fn blocked_wins_over_allowed_and_mode() {
        let p = global(MCPPermissionMode::AllowAll, &["rm"], &["rm"]);
        assert_eq!(
            check("ls && rm x", &p).verdict,
            CommandVerdict::Blocked("rm".into())
        );
    }

    #[test]
    fn modes() {
        let allow_all = global(MCPPermissionMode::AllowAll, &[], &[]);
        assert_eq!(check("curl x", &allow_all).verdict, CommandVerdict::Allowed);

        let allowlist = global(MCPPermissionMode::Allowlist, &["git"], &[]);
        assert_eq!(
            check("git status", &allowlist).verdict,
            CommandVerdict::Allowed
        );
        assert_eq!(
            check("git status | grep x", &allowlist).verdict,
            CommandVerdict::Blocked("grep".into())
        );

        let ask = global(MCPPermissionMode::AskUnlisted, &["ls"], &[]);
        assert_eq!(
            check("ls; make", &ask).verdict,
            CommandVerdict::NeedsApproval("make".into())
        );

        let audit = global(MCPPermissionMode::AuditOnly, &["ls"], &["rm"]);
        let result = check("ls; make; cargo", &audit);
        assert_eq!(result.verdict, CommandVerdict::Allowed);
        assert_eq!(result.audited, ["make", "cargo"]);
        assert_eq!(
            check("rm x", &audit).verdict,
            CommandVerdict::Blocked("rm".into())
        );
    }

    #[test]
    fn lists_compare_lowercased() {
        let p = global(MCPPermissionMode::Allowlist, &["Git"], &["CURL"]);
        assert_eq!(check("GIT log", &p).verdict, CommandVerdict::Allowed);
        assert_eq!(
            check("/usr/bin/curl x", &p).verdict,
            CommandVerdict::Blocked("curl".into())
        );
    }

    #[test]
    fn raw_input_only_checks_submitted_lines() {
        let p = global(MCPPermissionMode::Allowlist, &[], &[]);
        assert_eq!(check_raw_input("y\n", &p).verdict, CommandVerdict::Allowed);
        assert_eq!(
            check_raw_input("rm -rf x", &p).verdict,
            CommandVerdict::Allowed
        );
        assert_eq!(
            check_raw_input("rm -rf x\n", &p).verdict,
            CommandVerdict::Blocked("rm".into())
        );
        assert_eq!(
            check_raw_input("rm -rf x\r", &p).verdict,
            CommandVerdict::Blocked("rm".into())
        );
    }

    #[test]
    fn profile_overrides_global_when_it_matches() {
        let g = global(MCPPermissionMode::AllowAll, &[], &[]);
        let mut profile = MCPProfile::new(
            "Prod",
            ProfileSwitchTrigger::Directory {
                path: "/srv/prod".into(),
            },
        );
        profile.permission_mode = MCPPermissionMode::Allowlist;
        profile.allowed_commands = vec!["LS".into()];
        let profiles = vec![profile.clone()];
        let ctx = MCPTabContext {
            directory: Some("/srv/prod".into()),
            ..Default::default()
        };
        let resolved = resolve_permissions(&g, &profiles, Some(&ctx), None);
        assert_eq!(resolved.profile_id(), Some(profile.id));
        assert_eq!(resolved.source_name(), "profile: Prod");
        assert_eq!(
            resolved.source_info(),
            "Permissions source: profile \"Prod\""
        );
        assert!(resolved.allowed.contains("ls"));
        assert_eq!(
            check("make", &resolved).verdict,
            CommandVerdict::Blocked("make".into())
        );

        let elsewhere = MCPTabContext {
            directory: Some("/tmp".into()),
            ..Default::default()
        };
        let resolved = resolve_permissions(&g, &profiles, Some(&elsewhere), None);
        assert_eq!(resolved.source_name(), "global");
        assert_eq!(resolved.profile_id(), None);
        let resolved = resolve_permissions(&g, &profiles, None, None);
        assert_eq!(
            resolved.source_info(),
            "Permissions source: global settings"
        );
    }

    #[test]
    fn add_allowed_is_lowercased_and_unique() {
        let mut list = vec!["git".to_string()];
        add_allowed(&mut list, "GIT");
        add_allowed(&mut list, "Make");
        assert_eq!(list, ["git", "make"]);
    }
}

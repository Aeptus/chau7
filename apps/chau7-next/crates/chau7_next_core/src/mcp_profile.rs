//! MCP permission mode and scoped MCP profiles.
//!
//! Port of `MCPPermissionMode.swift` and `MCPProfile.swift` from
//! `apps/chau7-macos/Sources/Chau7Core`.
//!
//! Matching needs the user's home directory to expand `~/` in directory
//! triggers; it is passed as a parameter (`home`).

use crate::profile_rules::{ProfileSwitchRule, ProfileSwitchTrigger, uuid_upper};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// How MCP commands are filtered when not explicitly allowed or blocked.
/// Raw values are persisted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MCPPermissionMode {
    #[serde(rename = "allow_all")]
    AllowAll,
    #[serde(rename = "allowlist")]
    Allowlist,
    #[serde(rename = "ask_unlisted")]
    AskUnlisted,
    /// Allow execution but log/audit the command for review.
    #[serde(rename = "audit_only")]
    AuditOnly,
}

impl MCPPermissionMode {
    pub const ALL: [MCPPermissionMode; 4] = [
        MCPPermissionMode::AllowAll,
        MCPPermissionMode::Allowlist,
        MCPPermissionMode::AskUnlisted,
        MCPPermissionMode::AuditOnly,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::AllowAll => "allow_all",
            Self::Allowlist => "allowlist",
            Self::AskUnlisted => "ask_unlisted",
            Self::AuditOnly => "audit_only",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::AllowAll => "Allow All",
            Self::Allowlist => "Allowlist Only",
            Self::AskUnlisted => "Ask for Unlisted",
            Self::AuditOnly => "Audit Only",
        }
    }
}

/// Three-option result from the MCP command approval dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MCPApprovalResult {
    Denied,
    AllowedOnce,
    AlwaysAllow,
}

impl MCPApprovalResult {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Denied => "denied",
            Self::AllowedOnce => "allowedOnce",
            Self::AlwaysAllow => "alwaysAllow",
        }
    }
}

/// Snapshot of terminal state used to match MCP profiles at command-check time.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MCPTabContext {
    pub directory: Option<String>,
    pub git_branch: Option<String>,
    pub ssh_host: Option<String>,
    pub processes: Option<Vec<String>>,
    pub environment: Option<HashMap<String, String>>,
}

/// A scoped set of MCP permission rules that activates when its trigger
/// matches the current terminal context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MCPProfile {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    pub name: String,
    pub is_enabled: bool,
    pub trigger: ProfileSwitchTrigger,
    pub permission_mode: MCPPermissionMode,
    pub allowed_commands: Vec<String>,
    pub blocked_commands: Vec<String>,
    pub priority: i64,
    /// When non-empty, the profile only applies to tabs running one of these
    /// agents. When empty it applies to all agents.
    pub agent_allowlist: Vec<String>,
}

impl MCPProfile {
    /// Defaults: enabled, `ask_unlisted`, no commands, priority 0, no agents.
    pub fn new(name: &str, trigger: ProfileSwitchTrigger) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.to_string(),
            is_enabled: true,
            trigger,
            permission_mode: MCPPermissionMode::AskUnlisted,
            allowed_commands: Vec::new(),
            blocked_commands: Vec::new(),
            priority: 0,
            agent_allowlist: Vec::new(),
        }
    }

    /// Whether this profile's trigger matches the given tab context.
    pub fn matches(&self, context: &MCPTabContext, home: Option<&str>) -> bool {
        if !self.is_enabled {
            return false;
        }
        let mut rule = ProfileSwitchRule::new(&self.name, self.trigger.clone(), "");
        rule.priority = self.priority;
        rule.matches(
            context.directory.as_deref(),
            context.git_branch.as_deref(),
            context.ssh_host.as_deref(),
            context.processes.as_deref(),
            context.environment.as_ref(),
            home,
        )
    }
}

/// Highest-priority enabled profile whose trigger matches, or `None`. Ties on
/// priority go to the alphabetically first name; a full tie keeps the first.
pub fn best_match<'a>(
    profiles: &'a [MCPProfile],
    context: &MCPTabContext,
    home: Option<&str>,
) -> Option<&'a MCPProfile> {
    let mut best: Option<&MCPProfile> = None;
    for p in profiles.iter().filter(|p| p.matches(context, home)) {
        best = match best {
            None => Some(p),
            Some(cur) => {
                let increasing = if cur.priority != p.priority {
                    cur.priority < p.priority
                } else {
                    cur.name > p.name
                };
                if increasing { Some(p) } else { Some(cur) }
            }
        };
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(p: &str) -> ProfileSwitchTrigger {
        ProfileSwitchTrigger::Directory { path: p.into() }
    }

    fn ctx_dir(p: &str) -> MCPTabContext {
        MCPTabContext {
            directory: Some(p.into()),
            ..Default::default()
        }
    }

    #[test]
    fn test_codable_round_trip() {
        let mut profile = MCPProfile::new("Work Project", dir("~/projects/work"));
        profile.allowed_commands = vec!["git".into(), "ls".into(), "cat".into()];
        profile.blocked_commands = vec!["rm".into(), "sudo".into()];
        profile.priority = 10;
        let json = serde_json::to_string(&profile).unwrap();
        let decoded: MCPProfile = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, profile);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["permissionMode"], "ask_unlisted");
        assert_eq!(v["isEnabled"], true);
        assert_eq!(v["trigger"]["directory"]["path"], "~/projects/work");
        assert!(v.get("agentAllowlist").is_some());
        assert_eq!(v["id"], profile.id.to_string().to_uppercase());
    }

    #[test]
    fn test_codable_array_round_trip() {
        let mut a = MCPProfile::new("A", dir("/a"));
        a.priority = 1;
        let mut b = MCPProfile::new(
            "B",
            ProfileSwitchTrigger::SshHost {
                hostname: "b.com".into(),
            },
        );
        b.permission_mode = MCPPermissionMode::Allowlist;
        b.priority = 2;
        let mut c = MCPProfile::new(
            "C",
            ProfileSwitchTrigger::ProcessRunning {
                name: "docker".into(),
            },
        );
        c.permission_mode = MCPPermissionMode::AllowAll;
        let json = serde_json::to_string(&vec![a, b, c]).unwrap();
        let decoded: Vec<MCPProfile> = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.len(), 3);
        assert_eq!(decoded[0].name, "A");
        assert_eq!(decoded[1].permission_mode, MCPPermissionMode::Allowlist);
        assert_eq!(
            decoded[2].trigger,
            ProfileSwitchTrigger::ProcessRunning {
                name: "docker".into()
            }
        );
    }

    #[test]
    fn test_matches_directory() {
        let p = MCPProfile::new("Test", dir("/Users/test/projects"));
        assert!(p.matches(&ctx_dir("/Users/test/projects"), None));
    }

    #[test]
    fn test_does_not_match_different_directory() {
        let p = MCPProfile::new("Test", dir("/Users/test/projects"));
        assert!(!p.matches(&ctx_dir("/Users/other/projects"), None));
    }

    #[test]
    fn test_matches_ssh_host() {
        let p = MCPProfile::new(
            "SSH",
            ProfileSwitchTrigger::SshHost {
                hostname: "prod.example.com".into(),
            },
        );
        let ctx = MCPTabContext {
            ssh_host: Some("prod.example.com".into()),
            ..Default::default()
        };
        assert!(p.matches(&ctx, None));
    }

    #[test]
    fn test_ssh_host_case_insensitive() {
        let p = MCPProfile::new(
            "SSH",
            ProfileSwitchTrigger::SshHost {
                hostname: "Prod.Example.COM".into(),
            },
        );
        let ctx = MCPTabContext {
            ssh_host: Some("prod.example.com".into()),
            ..Default::default()
        };
        assert!(p.matches(&ctx, None));
    }

    #[test]
    fn test_matches_process() {
        let p = MCPProfile::new(
            "Docker",
            ProfileSwitchTrigger::ProcessRunning {
                name: "docker".into(),
            },
        );
        let ctx = MCPTabContext {
            processes: Some(vec!["bash".into(), "docker".into(), "node".into()]),
            ..Default::default()
        };
        assert!(p.matches(&ctx, None));
    }

    #[test]
    fn test_matches_environment_variable() {
        let p = MCPProfile::new(
            "Prod",
            ProfileSwitchTrigger::EnvironmentVariable {
                key: "NODE_ENV".into(),
                value: "production".into(),
            },
        );
        let ctx = MCPTabContext {
            environment: Some(HashMap::from([
                ("NODE_ENV".to_string(), "production".to_string()),
                ("PATH".to_string(), "/usr/bin".to_string()),
            ])),
            ..Default::default()
        };
        assert!(p.matches(&ctx, None));
    }

    #[test]
    fn test_does_not_match_when_disabled() {
        let mut p = MCPProfile::new("Disabled", dir("/tmp"));
        p.is_enabled = false;
        assert!(!p.matches(&ctx_dir("/tmp"), None));
    }

    #[test]
    fn test_does_not_match_nil_context() {
        let p = MCPProfile::new("Test", dir("/tmp"));
        assert!(!p.matches(&MCPTabContext::default(), None));
    }

    #[test]
    fn test_matches_git_repository() {
        let p = MCPProfile::new(
            "Repo",
            ProfileSwitchTrigger::GitRepository {
                name: "my-project".into(),
            },
        );
        assert!(p.matches(&ctx_dir("/Users/test/code/my-project"), None));
    }

    #[test]
    fn test_tilde_directory_uses_home_parameter() {
        let p = MCPProfile::new("Home", dir("~/projects/work"));
        assert!(p.matches(&ctx_dir("/Users/me/projects/work"), Some("/Users/me")));
        assert!(!p.matches(&ctx_dir("/Users/me/projects/work"), None));
    }

    #[test]
    fn test_best_match_return_highest_priority() {
        let mut low = MCPProfile::new("Low", dir("/tmp"));
        low.priority = 1;
        let mut high = MCPProfile::new("High", dir("/tmp"));
        high.priority = 10;
        let profiles = [low, high];
        let result = best_match(&profiles, &ctx_dir("/tmp"), None);
        assert_eq!(result.map(|p| p.name.as_str()), Some("High"));
    }

    #[test]
    fn test_best_match_return_nil_for_no_match() {
        let profiles = [MCPProfile::new("A", dir("/a"))];
        assert!(best_match(&profiles, &ctx_dir("/b"), None).is_none());
    }

    #[test]
    fn test_best_match_skips_disabled() {
        let mut disabled = MCPProfile::new("Disabled", dir("/tmp"));
        disabled.is_enabled = false;
        disabled.priority = 100;
        let mut enabled = MCPProfile::new("Enabled", dir("/tmp"));
        enabled.priority = 1;
        let profiles = [disabled, enabled];
        let result = best_match(&profiles, &ctx_dir("/tmp"), None);
        assert_eq!(result.map(|p| p.name.as_str()), Some("Enabled"));
    }

    #[test]
    fn test_best_match_tiebreak_by_name() {
        let mut b = MCPProfile::new("BBB", dir("/tmp"));
        b.priority = 5;
        let mut a = MCPProfile::new("AAA", dir("/tmp"));
        a.priority = 5;
        let profiles = [b, a];
        let result = best_match(&profiles, &ctx_dir("/tmp"), None);
        assert_eq!(result.map(|p| p.name.as_str()), Some("AAA"));
    }

    #[test]
    fn test_best_match_empty_array() {
        assert!(best_match(&[], &ctx_dir("/tmp"), None).is_none());
    }

    #[test]
    fn test_equality_by_id() {
        let id = Uuid::new_v4();
        let mut a = MCPProfile::new("A", dir("/a"));
        a.id = id;
        let mut b = MCPProfile::new("B", dir("/b"));
        b.id = id;
        assert_ne!(a, b);
        let mut c = MCPProfile::new("A", dir("/a"));
        c.id = id;
        assert_eq!(a, c);
    }

    #[test]
    fn test_default_values() {
        let p = MCPProfile::new("Default", dir("/tmp"));
        assert!(p.is_enabled);
        assert_eq!(p.permission_mode, MCPPermissionMode::AskUnlisted);
        assert!(p.allowed_commands.is_empty());
        assert!(p.blocked_commands.is_empty());
        assert_eq!(p.priority, 0);
        assert!(p.agent_allowlist.is_empty());
    }

    // MCPApprovalResult

    #[test]
    fn test_approval_result_codable_round_trip() {
        for original in [
            MCPApprovalResult::Denied,
            MCPApprovalResult::AllowedOnce,
            MCPApprovalResult::AlwaysAllow,
        ] {
            let json = serde_json::to_string(&original).unwrap();
            let decoded: MCPApprovalResult = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, original);
        }
    }

    #[test]
    fn test_approval_result_raw_values() {
        for (v, raw) in [
            (MCPApprovalResult::Denied, "denied"),
            (MCPApprovalResult::AllowedOnce, "allowedOnce"),
            (MCPApprovalResult::AlwaysAllow, "alwaysAllow"),
        ] {
            assert_eq!(v.raw_value(), raw);
            assert_eq!(serde_json::to_string(&v).unwrap(), format!("\"{raw}\""));
        }
    }

    // MCPPermissionMode

    #[test]
    fn test_permission_mode_codable_round_trip() {
        for mode in MCPPermissionMode::ALL {
            let json = serde_json::to_string(&mode).unwrap();
            let decoded: MCPPermissionMode = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, mode);
            assert_eq!(json, format!("\"{}\"", mode.raw_value()));
        }
    }

    #[test]
    fn test_permission_mode_display_names() {
        assert_eq!(MCPPermissionMode::AllowAll.display_name(), "Allow All");
        assert_eq!(
            MCPPermissionMode::Allowlist.display_name(),
            "Allowlist Only"
        );
        assert_eq!(
            MCPPermissionMode::AskUnlisted.display_name(),
            "Ask for Unlisted"
        );
        assert_eq!(MCPPermissionMode::AuditOnly.display_name(), "Audit Only");
    }

    #[test]
    fn test_permission_mode_raw_values() {
        assert_eq!(MCPPermissionMode::AllowAll.raw_value(), "allow_all");
        assert_eq!(MCPPermissionMode::Allowlist.raw_value(), "allowlist");
        assert_eq!(MCPPermissionMode::AskUnlisted.raw_value(), "ask_unlisted");
        assert_eq!(MCPPermissionMode::AuditOnly.raw_value(), "audit_only");
    }

    // MCPTabContext

    #[test]
    fn test_empty_context() {
        let ctx = MCPTabContext::default();
        assert!(ctx.directory.is_none());
        assert!(ctx.git_branch.is_none());
        assert!(ctx.ssh_host.is_none());
        assert!(ctx.processes.is_none());
        assert!(ctx.environment.is_none());
    }

    #[test]
    fn test_full_context() {
        let ctx = MCPTabContext {
            directory: Some("/tmp".into()),
            git_branch: Some("main".into()),
            ssh_host: Some("server.com".into()),
            processes: Some(vec!["bash".into()]),
            environment: Some(HashMap::from([("PATH".into(), "/usr/bin".into())])),
        };
        assert_eq!(ctx.directory.as_deref(), Some("/tmp"));
        assert_eq!(ctx.git_branch.as_deref(), Some("main"));
        assert_eq!(ctx.ssh_host.as_deref(), Some("server.com"));
        assert_eq!(ctx.processes, Some(vec!["bash".to_string()]));
        assert_eq!(
            ctx.environment,
            Some(HashMap::from([(
                "PATH".to_string(),
                "/usr/bin".to_string()
            )]))
        );
    }
}

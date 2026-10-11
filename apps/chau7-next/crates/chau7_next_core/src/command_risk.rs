//! Command risk detection and the dangerous-command guard.
//!
//! Port of `CommandRiskDetection.swift` from `apps/chau7-macos/Sources/Chau7Core`,
//! plus the pure check logic of `DangerousCommandGuard.swift`
//! (`apps/chau7-macos/Sources/Chau7/Commands`) and the default pattern list
//! from `FeatureSettings.defaultDangerousCommandPatterns`.
//!
//! The Swift `isRisky` first tries the `chau7_risk_*` symbols of the optional
//! `libchau7_parse` dylib (`RustCommandRisk.swift`). No Rust implementation of
//! those symbols exists in the repo, so this module ports the pure Swift
//! fallback: case-insensitive, whitespace-normalized substring matching.
//!
//! The guard's persistence (UserDefaults), logging and `NSAlert` confirmation
//! are left to the UI layer.

use std::collections::{HashMap, HashSet};

/// Default risky command patterns, verbatim from
/// `FeatureSettings.defaultDangerousCommandPatterns`.
pub const DEFAULT_DANGEROUS_COMMAND_PATTERNS: &[&str] = &[
    // Filesystem destruction
    "rm -rf",
    "rm -r -f",
    "rm -fr",
    "rm --no-preserve-root",
    "rm -rf /",
    "rm -rf ~",
    "rm -rf $home",
    "rm -rf *",
    "rm -rf .",
    "rm -rf ..",
    "rm -rf ./",
    "rm -rf ../",
    "find / -delete",
    "find . -delete",
    "find .. -delete",
    "chmod -r 777 /",
    "chmod -r 777 ~",
    "chown -r",
    "chgrp -r",
    "mv /",
    "mv ~",
    "dd if=",
    "dd of=/dev/",
    "mkfs",
    "mkfs.ext",
    "mkfs.xfs",
    "mkfs.btrfs",
    "mkfs.fat",
    "mkfs.vfat",
    "mkswap",
    "wipefs",
    "blkdiscard",
    "shred ",
    "sgdisk --zap-all",
    "sfdisk",
    "fdisk",
    "parted rm",
    "parted mklabel",
    "diskutil erasedisk",
    "diskutil erasevolume",
    "diskutil partitiondisk",
    "diskutil apfs deletevolume",
    "diskutil apfs deletecontainer",
    "diskutil secureerase",
    "zpool destroy",
    "btrfs subvolume delete",
    "cryptsetup luksformat",
    "cryptsetup lukserase",
    "dmsetup remove",
    "lvremove",
    "vgremove",
    "pvremove",
    "swapoff -a",
    // System power/process
    "shutdown -r",
    "shutdown -h",
    "reboot",
    "poweroff",
    "halt",
    "init 0",
    "init 6",
    "kill -9 -1",
    "kill -kill -1",
    "killall -9",
    "pkill -9",
    // Git/VCS
    "git reset --hard",
    "git clean -fd",
    "git clean -fdx",
    "git clean -ffdx",
    "git push -f",
    "git push --force",
    "git push --force-with-lease",
    "git push origin :",
    "git branch -d",
    "git branch -d -f",
    "git branch -d --force",
    "git branch -d -D",
    "git tag -d",
    "git reflog expire --expire=now --all",
    "git gc --prune=now",
    "git checkout -- .",
    "git restore --staged",
    "git rm -r",
    "svn delete",
    "hg strip",
    // GitHub CLI
    "gh repo delete",
    "gh api repos/ -x delete",
    "gh codespace delete",
    "gh release delete",
    "gh gist delete",
    // Containers & Kubernetes
    "docker system prune -a",
    "docker system prune --volumes",
    "docker volume prune",
    "docker network prune",
    "docker container prune",
    "docker image prune -a",
    "docker builder prune -a",
    "docker rm -f",
    "docker rmi -f",
    "docker-compose down -v",
    "docker compose down -v",
    "kubectl delete namespace",
    "kubectl delete ns",
    "kubectl delete all --all",
    "kubectl delete --all --all-namespaces",
    "kubectl delete -f",
    "kubectl delete pods --all",
    "kubectl delete pvc --all",
    "kubectl delete pv --all",
    "helm uninstall",
    // IaC
    "terraform destroy",
    "terraform apply -destroy",
    "pulumi destroy",
    "cdk destroy",
    // Cloud provider CLIs
    "aws s3 rm --recursive",
    "aws s3 rb",
    "aws s3api delete-bucket",
    "aws s3api delete-object",
    "aws s3api delete-objects",
    "aws ec2 terminate-instances",
    "aws autoscaling delete-auto-scaling-group",
    "aws rds delete-db-instance",
    "aws rds delete-db-cluster",
    "aws cloudformation delete-stack",
    "aws dynamodb delete-table",
    "aws iam delete-user",
    "aws iam delete-role",
    "aws kms schedule-key-deletion",
    "aws eks delete-cluster",
    "aws ecs delete-cluster",
    "aws lambda delete-function",
    "aws logs delete-log-group",
    "gcloud projects delete",
    "gcloud compute instances delete",
    "gcloud compute disks delete",
    "gcloud sql instances delete",
    "gcloud sql databases delete",
    "gcloud container clusters delete",
    "gcloud storage rm -r",
    "gcloud storage buckets delete",
    "gcloud dns managed-zones delete",
    "az group delete",
    "az vm delete",
    "az aks delete",
    "az storage account delete",
    "az storage container delete",
    "az storage blob delete",
    "az sql db delete",
    "az cosmosdb delete",
    "az webapp delete",
    "doctl compute droplet delete",
    "doctl k8s cluster delete",
    "doctl database delete",
    // PaaS/DB services
    "heroku apps:destroy",
    "heroku pipelines:destroy",
    "vercel remove",
    "vercel project rm",
    "vercel projects remove",
    "railway project delete",
    "fly apps destroy",
    "supabase projects delete",
    "supabase db reset",
    "supabase db drop",
    "firebase projects:delete",
    "firebase hosting:delete",
    "firebase functions:delete",
    "netlify sites:delete",
    "cloudflare zones delete",
    // Backup tools
    "rclone delete",
    "rclone purge",
    "restic forget --prune",
    "restic prune",
    // Databases/SQL
    "drop database",
    "drop schema",
    "drop table",
    "truncate table",
    "delete from",
];

/// Returns true if the command line matches any of the risky patterns.
/// Matching is case-insensitive and whitespace-normalized, and a pattern
/// matches anywhere in the command (plain substring, no word boundaries).
pub fn is_risky<S: AsRef<str>>(command_line: &str, patterns: &[S]) -> bool {
    let normalized_command = normalize(command_line);
    if normalized_command.is_empty() {
        return false;
    }
    patterns.iter().any(|raw| {
        let pattern = normalize(raw.as_ref());
        !pattern.is_empty() && normalized_command.contains(&pattern)
    })
}

/// Trims, collapses every whitespace run to a single space and lowercases.
fn normalize(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Detects Unicode homoglyphs: characters from the Cyrillic block
/// (U+0400..=U+04FF) or the fullwidth forms (U+FF01..=U+FF5E) that visually
/// resemble ASCII and can disguise a malicious command.
pub fn contains_homoglyphs(text: &str) -> bool {
    text.chars()
        .any(|c| matches!(c as u32, 0x0400..=0x04FF | 0xFF01..=0xFF5E))
}

/// Result of checking a command with [`DangerousCommandGuard::check`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckResult {
    /// Not risky, proceed.
    Safe,
    /// Risky but in an allow list.
    Allowed,
    /// Needs user confirmation.
    NeedsConfirmation {
        command: String,
        matched_pattern: String,
    },
    /// In the block list.
    Blocked,
}

/// Pattern reported when the command contains homoglyph characters.
pub const HOMOGLYPH_MATCHED_PATTERN: &str = "Unicode homoglyph characters detected";
/// Pattern reported when the command spans multiple lines.
pub const MULTILINE_MATCHED_PATTERN: &str = "Multiline paste detected";
/// Pattern reported when no single pattern can be identified.
pub const FALLBACK_MATCHED_PATTERN: &str = "risky command pattern";

/// Guards against accidental execution of dangerous commands.
///
/// Pure state and check logic of the Swift `DangerousCommandGuard`; the
/// caller owns persistence and the confirmation UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DangerousCommandGuard {
    /// Whether the guard is active. A disabled guard reports everything safe.
    pub is_enabled: bool,
    /// Commands that are always allowed.
    pub allow_list: HashSet<String>,
    /// Commands that are always blocked. Takes precedence over allow lists.
    pub block_list: HashSet<String>,
    /// Risk patterns to match against.
    pub patterns: Vec<String>,
    /// Directory path to commands allowed in that directory or its children.
    directory_allow_lists: HashMap<String, HashSet<String>>,
}

impl Default for DangerousCommandGuard {
    /// Enabled, empty lists, [`DEFAULT_DANGEROUS_COMMAND_PATTERNS`].
    fn default() -> Self {
        Self::new(
            true,
            HashSet::new(),
            HashSet::new(),
            DEFAULT_DANGEROUS_COMMAND_PATTERNS
                .iter()
                .map(|p| (*p).to_string())
                .collect(),
        )
    }
}

impl DangerousCommandGuard {
    /// Creates a guard with the given state and no directory allow lists.
    pub fn new(
        enabled: bool,
        allow_list: HashSet<String>,
        block_list: HashSet<String>,
        patterns: Vec<String>,
    ) -> Self {
        Self {
            is_enabled: enabled,
            allow_list,
            block_list,
            patterns,
            directory_allow_lists: HashMap::new(),
        }
    }

    /// Checks whether a command needs confirmation.
    ///
    /// `directory` is the terminal's working directory, used for
    /// per-directory allow list matching.
    pub fn check(&self, command_line: &str, directory: Option<&str>) -> CheckResult {
        if !self.is_enabled {
            return CheckResult::Safe;
        }
        let trimmed = command_line.trim();
        if trimmed.is_empty() {
            return CheckResult::Safe;
        }

        if contains_homoglyphs(trimmed) {
            return needs_confirmation(trimmed, HOMOGLYPH_MATCHED_PATTERN);
        }
        if trimmed.contains('\n') {
            return needs_confirmation(trimmed, MULTILINE_MATCHED_PATTERN);
        }
        if self.block_list.contains(trimmed) {
            return CheckResult::Blocked;
        }
        if let Some(dir) = directory {
            let allowed_here = self
                .directory_allow_lists
                .iter()
                .any(|(allowed_dir, cmds)| {
                    let in_dir = dir == allowed_dir
                        || dir
                            .strip_prefix(allowed_dir.as_str())
                            .is_some_and(|rest| rest.starts_with('/'));
                    in_dir && cmds.contains(trimmed)
                });
            if allowed_here {
                return CheckResult::Allowed;
            }
        }
        if self.allow_list.contains(trimmed) {
            return CheckResult::Allowed;
        }
        if is_risky(trimmed, &self.patterns) {
            let matched = self.find_matched_pattern(trimmed);
            return needs_confirmation(trimmed, &matched);
        }
        CheckResult::Safe
    }

    /// Returns the first pattern that matches `command`, or
    /// [`FALLBACK_MATCHED_PATTERN`].
    pub fn find_matched_pattern(&self, command: &str) -> String {
        self.patterns
            .iter()
            .find(|p| is_risky(command, std::slice::from_ref(p)))
            .cloned()
            .unwrap_or_else(|| FALLBACK_MATCHED_PATTERN.to_string())
    }

    /// Adds a trimmed command to the allow list. Blank input is ignored.
    pub fn add_to_allow_list(&mut self, command: &str) {
        let trimmed = command.trim();
        if !trimmed.is_empty() {
            self.allow_list.insert(trimmed.to_string());
        }
    }

    /// Removes a command from the allow list (exact match, not trimmed).
    pub fn remove_from_allow_list(&mut self, command: &str) {
        self.allow_list.remove(command);
    }

    /// Adds a trimmed command to the block list. Blank input is ignored.
    pub fn add_to_block_list(&mut self, command: &str) {
        let trimmed = command.trim();
        if !trimmed.is_empty() {
            self.block_list.insert(trimmed.to_string());
        }
    }

    /// Removes a command from the block list (exact match, not trimmed).
    pub fn remove_from_block_list(&mut self, command: &str) {
        self.block_list.remove(command);
    }

    /// Clears the allow list.
    pub fn clear_allow_list(&mut self) {
        self.allow_list.clear();
    }

    /// Clears the block list.
    pub fn clear_block_list(&mut self) {
        self.block_list.clear();
    }

    /// Allows `command` when the working directory is `directory` or a child.
    pub fn add_to_directory_allow_list(&mut self, command: &str, directory: &str) {
        self.directory_allow_lists
            .entry(directory.to_string())
            .or_default()
            .insert(command.to_string());
    }

    /// Removes a per-directory allowance, dropping the directory when empty.
    pub fn remove_from_directory_allow_list(&mut self, command: &str, directory: &str) {
        if let Some(cmds) = self.directory_allow_lists.get_mut(directory) {
            cmds.remove(command);
            if cmds.is_empty() {
                self.directory_allow_lists.remove(directory);
            }
        }
    }

    /// Per-directory allow lists, keyed by directory path.
    pub fn directory_allow_lists(&self) -> &HashMap<String, HashSet<String>> {
        &self.directory_allow_lists
    }
}

fn needs_confirmation(command: &str, matched_pattern: &str) -> CheckResult {
    CheckResult::NeedsConfirmation {
        command: command.to_string(),
        matched_pattern: matched_pattern.to_string(),
    }
}

#[cfg(test)]
mod tests {
    // Ported from CommandRiskDetectionTests.swift, DangerousCommandGuardTests.swift
    // and the two dangerous-pattern tests of FeatureSettingsTests.swift
    // (run against DEFAULT_DANGEROUS_COMMAND_PATTERNS). No tests skipped:
    // none of them need AppKit. Extra tests for homoglyph, multiline and
    // per-directory logic are at the end.
    use super::*;

    // CommandRiskDetectionTests

    #[test]
    fn risky_command_matches_simple_patterns() {
        let patterns = ["rm -rf", "git push --force", "gh repo delete"];
        assert!(is_risky("rm -rf /tmp", &patterns));
        assert!(is_risky("git push --force origin main", &patterns));
        assert!(is_risky("gh repo delete org/repo", &patterns));
    }

    #[test]
    fn risky_command_matches_with_whitespace() {
        assert!(is_risky("rm    -rf   /", &["rm -rf"]));
    }

    #[test]
    fn risky_command_is_case_insensitive() {
        assert!(is_risky("git push -f origin main", &["GIT PUSH -F"]));
    }

    #[test]
    fn non_risky_command_does_not_match() {
        let patterns = ["rm -rf", "git push --force"];
        assert!(!is_risky("rm -r ./build", &patterns));
        assert!(!is_risky("git push origin main", &patterns));
    }

    #[test]
    fn empty_patterns_do_not_match() {
        assert!(!is_risky::<&str>("rm -rf /", &[]));
        assert!(!is_risky("", &["rm -rf"]));
    }

    #[test]
    fn pattern_matches_anywhere() {
        let patterns = ["--force"];
        assert!(is_risky("git push --force origin main", &patterns));
        assert!(is_risky("some-command --force-yes", &patterns));
    }

    #[test]
    fn pattern_does_not_match_partial_words() {
        // Plain substring matching: "storm -rf" contains "rm -rf".
        assert!(is_risky("storm -rf /tmp", &["rm -rf"]));
    }

    #[test]
    fn multi_command_with_semicolon() {
        assert!(is_risky("echo hello; rm -rf /", &["rm -rf"]));
    }

    #[test]
    fn multi_command_with_and_operator() {
        assert!(is_risky("cd /tmp && rm -rf *", &["rm -rf"]));
    }

    #[test]
    fn multi_command_with_pipe() {
        assert!(is_risky("find . -name '*.tmp' | xargs rm -rf", &["rm -rf"]));
    }

    #[test]
    fn tabs_normalized() {
        assert!(is_risky("rm\t-rf\t/", &["rm -rf"]));
    }

    #[test]
    fn leading_trailing_whitespace() {
        assert!(is_risky("  rm -rf /  ", &["rm -rf"]));
    }

    #[test]
    fn newline_in_command() {
        assert!(is_risky("rm\n-rf /", &["rm -rf"]));
    }

    #[test]
    fn very_long_command() {
        let command = format!("{} dangerous", "a".repeat(10_000));
        assert!(is_risky(&command, &["dangerous"]));
    }

    #[test]
    fn whitespace_only_command() {
        assert!(!is_risky("   \t\n  ", &["rm -rf"]));
    }

    #[test]
    fn whitespace_only_pattern() {
        assert!(!is_risky("rm -rf /", &["  ", "\t"]));
    }

    #[test]
    fn multiple_patterns_first_matches() {
        let patterns = ["rm -rf", "git push --force", "drop table"];
        assert!(is_risky("rm -rf /important", &patterns));
    }

    #[test]
    fn multiple_patterns_last_matches() {
        let patterns = ["rm -rf", "git push --force", "drop table"];
        assert!(is_risky("sql DROP TABLE users", &patterns));
    }

    // FeatureSettingsTests (dangerous command patterns)

    #[test]
    fn default_dangerous_command_patterns_not_empty() {
        assert!(!DEFAULT_DANGEROUS_COMMAND_PATTERNS.is_empty());
    }

    #[test]
    fn dangerous_command_patterns_contain_common_threats() {
        let p = DEFAULT_DANGEROUS_COMMAND_PATTERNS;
        assert!(p.contains(&"rm -rf"));
        assert!(p.contains(&"git reset --hard"));
        assert!(p.contains(&"drop database"));
    }

    // DangerousCommandGuardTests

    fn set(items: &[&str]) -> HashSet<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    fn make_guard(
        enabled: bool,
        allow_list: &[&str],
        block_list: &[&str],
        patterns: &[&str],
    ) -> DangerousCommandGuard {
        DangerousCommandGuard::new(
            enabled,
            set(allow_list),
            set(block_list),
            patterns.iter().map(|s| (*s).to_string()).collect(),
        )
    }

    const TEST_PATTERNS: &[&str] = &["rm -rf", "dd if=", "mkfs"];

    fn default_guard() -> DangerousCommandGuard {
        make_guard(true, &[], &[], TEST_PATTERNS)
    }

    fn assert_needs_confirmation(result: &CheckResult) {
        assert!(
            matches!(result, CheckResult::NeedsConfirmation { .. }),
            "expected NeedsConfirmation, got {result:?}"
        );
    }

    #[test]
    fn safe_command() {
        assert_eq!(default_guard().check("ls -la", None), CheckResult::Safe);
    }

    #[test]
    fn safe_command_git_status() {
        assert_eq!(default_guard().check("git status", None), CheckResult::Safe);
    }

    #[test]
    fn safe_command_echo() {
        assert_eq!(default_guard().check("echo hello", None), CheckResult::Safe);
    }

    #[test]
    fn risky_command_rm_rf() {
        assert_eq!(
            default_guard().check("rm -rf /tmp/stuff", None),
            needs_confirmation("rm -rf /tmp/stuff", "rm -rf")
        );
    }

    #[test]
    fn risky_command_dd() {
        assert_eq!(
            default_guard().check("dd if=/dev/zero of=/dev/sda", None),
            needs_confirmation("dd if=/dev/zero of=/dev/sda", "dd if=")
        );
    }

    #[test]
    fn risky_command_mkfs() {
        match default_guard().check("mkfs.ext4 /dev/sda1", None) {
            CheckResult::NeedsConfirmation { command, .. } => {
                assert_eq!(command, "mkfs.ext4 /dev/sda1");
            }
            other => panic!("expected NeedsConfirmation, got {other:?}"),
        }
    }

    #[test]
    fn allow_listed_command() {
        let g = make_guard(true, &["rm -rf /tmp/cache"], &[], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /tmp/cache", None), CheckResult::Allowed);
    }

    #[test]
    fn allow_list_does_not_affect_other_risky_commands() {
        let g = make_guard(true, &["rm -rf /tmp/cache"], &[], TEST_PATTERNS);
        assert_needs_confirmation(&g.check("rm -rf /home", None));
    }

    #[test]
    fn block_listed_command() {
        let g = make_guard(true, &[], &["rm -rf /"], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /", None), CheckResult::Blocked);
    }

    #[test]
    fn block_list_takes_precedence_over_allow_list() {
        let g = make_guard(true, &["rm -rf /"], &["rm -rf /"], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /", None), CheckResult::Blocked);
    }

    #[test]
    fn block_list_does_not_affect_safe_commands() {
        let g = make_guard(true, &[], &["rm -rf /"], TEST_PATTERNS);
        assert_eq!(g.check("ls -la", None), CheckResult::Safe);
    }

    #[test]
    fn empty_command_is_safe() {
        assert_eq!(default_guard().check("", None), CheckResult::Safe);
    }

    #[test]
    fn whitespace_only_command_is_safe() {
        assert_eq!(default_guard().check("   ", None), CheckResult::Safe);
    }

    #[test]
    fn newline_only_command_is_safe() {
        assert_eq!(default_guard().check("\n\t  ", None), CheckResult::Safe);
    }

    #[test]
    fn disabled_guard_returns_safe_for_risky_command() {
        let g = make_guard(false, &[], &[], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /", None), CheckResult::Safe);
    }

    #[test]
    fn disabled_guard_returns_safe_for_blocked_command() {
        let g = make_guard(false, &[], &["rm -rf /"], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /", None), CheckResult::Safe);
    }

    #[test]
    fn disabled_guard_returns_safe_for_allowed_command() {
        let g = make_guard(false, &["rm -rf /tmp"], &[], TEST_PATTERNS);
        assert_eq!(g.check("rm -rf /tmp", None), CheckResult::Safe);
    }

    #[test]
    fn case_insensitive_matching() {
        assert_needs_confirmation(&default_guard().check("RM -RF /tmp", None));
    }

    #[test]
    fn leading_trailing_whitespace_trimming_for_check() {
        match default_guard().check("  rm -rf /tmp  ", None) {
            CheckResult::NeedsConfirmation { command, .. } => assert_eq!(command, "rm -rf /tmp"),
            other => panic!("expected NeedsConfirmation, got {other:?}"),
        }
    }

    #[test]
    fn empty_patterns_always_safe() {
        let g = make_guard(true, &[], &[], &[]);
        assert_eq!(g.check("rm -rf /", None), CheckResult::Safe);
    }

    #[test]
    fn add_to_allow_list() {
        let mut g = default_guard();
        g.add_to_allow_list("rm -rf /tmp/safe");
        assert!(g.allow_list.contains("rm -rf /tmp/safe"));
        assert_eq!(g.check("rm -rf /tmp/safe", None), CheckResult::Allowed);
    }

    #[test]
    fn remove_from_allow_list() {
        let mut g = make_guard(true, &["rm -rf /tmp/safe"], &[], TEST_PATTERNS);
        g.remove_from_allow_list("rm -rf /tmp/safe");
        assert!(!g.allow_list.contains("rm -rf /tmp/safe"));
    }

    #[test]
    fn add_to_block_list() {
        let mut g = default_guard();
        g.add_to_block_list("danger-cmd");
        assert!(g.block_list.contains("danger-cmd"));
        assert_eq!(g.check("danger-cmd", None), CheckResult::Blocked);
    }

    #[test]
    fn remove_from_block_list() {
        let mut g = make_guard(true, &[], &["danger-cmd"], TEST_PATTERNS);
        g.remove_from_block_list("danger-cmd");
        assert!(!g.block_list.contains("danger-cmd"));
    }

    #[test]
    fn clear_allow_list() {
        let mut g = make_guard(true, &["a", "b", "c"], &[], TEST_PATTERNS);
        g.clear_allow_list();
        assert!(g.allow_list.is_empty());
    }

    #[test]
    fn clear_block_list() {
        let mut g = make_guard(true, &[], &["x", "y", "z"], TEST_PATTERNS);
        g.clear_block_list();
        assert!(g.block_list.is_empty());
    }

    #[test]
    fn add_empty_to_allow_list_is_ignored() {
        let mut g = default_guard();
        g.add_to_allow_list("  ");
        assert!(g.allow_list.is_empty());
    }

    #[test]
    fn add_empty_to_block_list_is_ignored() {
        let mut g = default_guard();
        g.add_to_block_list("  ");
        assert!(g.block_list.is_empty());
    }

    // Extra coverage for logic without Swift tests.

    #[test]
    fn homoglyphs_need_confirmation() {
        // Cyrillic "а" (U+0430) in place of Latin "a".
        assert_eq!(
            default_guard().check("c\u{0430}t file", None),
            needs_confirmation("c\u{0430}t file", HOMOGLYPH_MATCHED_PATTERN)
        );
        assert!(contains_homoglyphs("ls \u{FF01}"));
        assert!(!contains_homoglyphs("caf\u{e9} ls"));
    }

    #[test]
    fn multiline_needs_confirmation() {
        assert_eq!(
            default_guard().check("echo a\necho b", None),
            needs_confirmation("echo a\necho b", MULTILINE_MATCHED_PATTERN)
        );
    }

    #[test]
    fn directory_allow_list_matches_dir_and_children_only() {
        let mut g = default_guard();
        g.add_to_directory_allow_list("rm -rf build", "/repo");
        assert_eq!(g.check("rm -rf build", Some("/repo")), CheckResult::Allowed);
        assert_eq!(
            g.check("rm -rf build", Some("/repo/sub")),
            CheckResult::Allowed
        );
        assert_needs_confirmation(&g.check("rm -rf build", Some("/repo2")));
        assert_needs_confirmation(&g.check("rm -rf build", None));
        g.remove_from_directory_allow_list("rm -rf build", "/repo");
        assert!(g.directory_allow_lists().is_empty());
    }

    #[test]
    fn default_guard_uses_default_patterns() {
        let g = DangerousCommandGuard::default();
        assert!(g.is_enabled);
        assert_eq!(g.patterns.len(), DEFAULT_DANGEROUS_COMMAND_PATTERNS.len());
        assert_eq!(
            g.check("terraform destroy", None),
            needs_confirmation("terraform destroy", "terraform destroy")
        );
        assert_eq!(g.find_matched_pattern("ls"), FALLBACK_MATCHED_PATTERN);
    }
}

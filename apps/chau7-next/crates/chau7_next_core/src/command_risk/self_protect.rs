//! Current Swift `SelfProtectiveCommandDetection`: only commands targeting
//! this application, its shell or configured managed helpers are protected.
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ProtectionLevel {
    VerboseLogging,
    Warning,
    #[default]
    Blocking,
}
impl ProtectionLevel {
    pub const ALL: [Self; 3] = [Self::VerboseLogging, Self::Warning, Self::Blocking];
    pub fn raw(self) -> &'static str {
        match self {
            Self::VerboseLogging => "verbose_logging",
            Self::Warning => "warning",
            Self::Blocking => "blocking",
        }
    }
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|level| level.raw() == raw)
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::VerboseLogging => "Verbose Logging",
            Self::Warning => "Warning",
            Self::Blocking => "Blocking",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Context {
    pub protected_pids: HashSet<i32>,
    pub protected_names: HashSet<String>,
}
impl Context {
    pub fn new(
        pids: impl IntoIterator<Item = i32>,
        names: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            protected_pids: pids.into_iter().filter(|pid| *pid > 0).collect(),
            protected_names: names
                .into_iter()
                .map(|name| normalize_token(&name))
                .filter(|name| !name.is_empty())
                .collect(),
        }
    }
    /// Swift FeatureSettings also expands configured substrings to actually
    /// observed child names; input comes from the cached native process worker.
    pub fn with_observed_names(mut self, patterns: &[String], observed: &[String]) -> Self {
        let normalized: Vec<_> = patterns
            .iter()
            .map(|s| normalize_token(s))
            .filter(|s| !s.is_empty())
            .collect();
        for raw in observed {
            let name = normalize_token(raw);
            if !name.is_empty()
                && normalized
                    .iter()
                    .any(|p| name.contains(p) || p.contains(&name))
            {
                self.protected_names.insert(name);
            }
        }
        self
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    pub command: String,
    pub reason: &'static str,
}
pub fn normalize_token(raw: &str) -> String {
    raw.trim_matches(['\"', '\'', '`']).trim().to_lowercase()
}
pub fn detect(line: &str, context: &Context) -> Option<Match> {
    for command in subcommands(line.trim()) {
        let tokens = tokenize(&command);
        let Some(first) = tokens.first() else {
            continue;
        };
        let executable = normalize_token(first);
        let reason = match executable.as_str() {
            "kill" if protected_kill(&tokens[1..], context) => {
                Some("would terminate a protected Chau7-managed process")
            }
            "pkill" | "killall"
                if tokens[1..].iter().any(|token| {
                    let name = normalize_token(token);
                    !name.is_empty()
                        && !name.starts_with('-')
                        && context
                            .protected_names
                            .iter()
                            .any(|p| name.contains(p) || p.contains(&name))
                }) =>
            {
                Some("would target Chau7 or a protected Chau7 helper process")
            }
            "osascript"
                if command.to_lowercase().contains("quit app")
                    && context
                        .protected_names
                        .iter()
                        .any(|name| command.to_lowercase().contains(name)) =>
            {
                Some("would ask macOS to quit Chau7")
            }
            _ => None,
        };
        if let Some(reason) = reason {
            return Some(Match { command, reason });
        }
    }
    None
}
fn protected_kill(tokens: &[String], context: &Context) -> bool {
    let mut signal = false;
    let mut targets_only = false;
    for raw in tokens {
        let token = normalize_token(raw);
        if signal {
            signal = false;
            continue;
        }
        if token == "--" {
            targets_only = true;
            continue;
        }
        if token == "-s" || token == "--signal" {
            signal = true;
            continue;
        }
        let signless = token.strip_prefix('-').unwrap_or(&token);
        let pid = signless.parse::<i32>().ok();
        let group_target =
            token.starts_with('-') && pid.is_some_and(|pid| context.protected_pids.contains(&pid));
        if !targets_only && token.starts_with('-') && !group_target {
            continue;
        }
        if (token == "$$" || token == "-$$") && !context.protected_pids.is_empty() {
            return true;
        }
        if pid.is_some_and(|pid| context.protected_pids.contains(&pid)) {
            return true;
        }
    }
    false
}
fn subcommands(line: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let (mut single, mut double, mut escape) = (false, false, false);
    for c in line.chars() {
        if escape {
            current.push(c);
            escape = false;
            continue;
        }
        if c == '\\' && !single {
            current.push(c);
            escape = true;
            continue;
        }
        if c == '\'' && !double {
            single = !single;
            current.push(c);
            continue;
        }
        if c == '"' && !single {
            double = !double;
            current.push(c);
            continue;
        }
        if !single && !double && matches!(c, ';' | '|' | '&' | '\n' | '\r') {
            let trimmed = current.trim();
            if !trimmed.is_empty() {
                result.push(trimmed.into());
            }
            current.clear();
        } else {
            current.push(c);
        }
    }
    if !current.trim().is_empty() {
        result.push(current.trim().into());
    }
    result
}
fn tokenize(command: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let (mut single, mut double, mut escape) = (false, false, false);
    for c in command.chars() {
        if escape {
            current.push(c);
            escape = false;
            continue;
        }
        if c == '\\' && !single {
            escape = true;
            continue;
        }
        if c == '\'' && !double {
            single = !single;
            continue;
        }
        if c == '"' && !single {
            double = !double;
            continue;
        }
        if !single && !double && c.is_whitespace() {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context() -> Context {
        Context::new([4242], ["chau7".into(), " Chau7-MCP-Bridge ".into()])
    }
    #[test]
    fn current_swift_examples() {
        for command in [
            "kill 4242",
            "killall Chau7",
            "osascript -e 'quit app \"Chau7\"'",
        ] {
            assert_eq!(detect(command, &context()).unwrap().command, command);
        }
        for command in [
            "kill 9999",
            "git status",
            "echo 'kill 4242'",
            "echo \"killall Chau7\"",
            "killall unrelated",
        ] {
            assert!(detect(command, &context()).is_none(), "{command}");
        }
    }
    #[test]
    fn signals_groups_chains_and_quotes_follow_current_swift() {
        for command in [
            "kill -9 4242",
            "kill --signal TERM 4242",
            "kill -s 4242 9999; kill 4242",
            "kill -4242",
            "kill -- -4242",
            "kill $$",
            "kill -- -$$",
            "echo okay && pkill Chau7Next",
            "echo 'x; kill 9999' | killall Chau7",
            "echo x\\;y; kill 4242",
        ] {
            assert!(detect(command, &context()).is_some(), "{command}");
        }
        for command in [
            "kill -s 4242 9999",
            "kill --signal 4242 9999",
            "kill -$$",
            "echo 'killall Chau7; true'",
            "echo x\\;killall Chau7",
            "echo \"quoted && kill 4242\"",
        ] {
            assert!(detect(command, &context()).is_none(), "{command}");
        }
        assert!(detect("kill $$", &Context::default()).is_none());
    }
    #[test]
    fn configured_patterns_expand_only_observed_matching_names() {
        let context = Context::new([4242], ["mcp".into(), " ".into()])
            .with_observed_names(&["mcp".into()], &["mcp-bridge".into(), "unrelated".into()]);
        assert!(detect("killall bridge", &context).is_some());
        assert!(detect("killall unrelated", &context).is_none());
        assert!(!context.protected_names.contains(""));
        assert_eq!(ProtectionLevel::from_raw("invalid"), None);
    }
}

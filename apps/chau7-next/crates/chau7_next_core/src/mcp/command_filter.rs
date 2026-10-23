//! Command permissions for MCP clients (`MCP/MCPCommandFilter.swift`).
//!
//! A command line is split into sub-commands on shell operators, subshells
//! and substitutions, each sub-command is reduced to its program name with
//! shell quoting removed (see [`extract_base_commands`]), and the names
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

/// The name reported for a line whose text the shell edits before running
/// it (cursor moves, word kills, ...): what runs cannot be read from it.
pub const LINE_EDITING_INPUT: &str = "(line editing keys)";

/// Control characters other than tab and line ends: the shell treats them
/// as editing keys, so the line it runs is not the text that was sent.
fn has_line_editing(command: &str) -> bool {
    command
        .chars()
        .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
}

/// Check a command line (`tab_exec`).
///
/// A line with editing keys in it cannot be checked name by name: unless a
/// blocked name shows, it is blocked in Allowlist mode and needs approval
/// in every other mode.
pub fn check(command: &str, permissions: &ResolvedPermissions) -> CheckResult {
    let mut audited = Vec::new();
    let bases = extract_base_commands(command);
    if has_line_editing(command) {
        let blocked = bases
            .into_iter()
            .find(|base| permissions.blocked.contains(&normalize_command(base)));
        let verdict = match (blocked, permissions.mode) {
            (Some(base), _) => CommandVerdict::Blocked(base),
            (None, MCPPermissionMode::Allowlist) => {
                CommandVerdict::Blocked(LINE_EDITING_INPUT.into())
            }
            (None, _) => CommandVerdict::NeedsApproval(LINE_EDITING_INPUT.into()),
        };
        return CheckResult { verdict, audited };
    }
    for base in bases {
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

/// `checkRawInput` (`tab_send_input` with nothing typed before): every
/// line the input submits is checked with [`check_submitted_lines`]; text
/// after the last line end is still being typed and passes.
pub fn check_raw_input(input: &str, permissions: &ResolvedPermissions) -> CheckResult {
    let staged = stage_input("", input);
    check_submitted_lines(&staged.submitted, permissions)
}

/// Longest unsubmitted text kept for a tab, in characters. Input that
/// would leave more than this unsubmitted is refused rather than tracked
/// partially, since a partial record could hide a command.
pub const MAX_PENDING_INPUT_CHARS: usize = 16 * 1024;

/// What a piece of input does to a tab's command line (`mcpPendingInput`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StagedInput {
    /// Lines the input submits (Return, Line Feed or Ctrl+O), with the
    /// text typed before them; these must be checked before it is sent.
    pub submitted: Vec<String>,
    /// Text left typed but not submitted.
    pub pending: String,
}

impl StagedInput {
    /// The pending text is too long to track ([`MAX_PENDING_INPUT_CHARS`]).
    pub fn overflows(&self) -> bool {
        self.pending.chars().count() > MAX_PENDING_INPUT_CHARS
    }
}

/// Apply `input` (text, or the bytes of a key press) to the unsubmitted
/// text `pending` of a tab. Ctrl+C drops the line; Ctrl+U and Backspace
/// are applied while the line has no other editing key in it (the cursor
/// is then at its end), and kept as editing keys otherwise.
pub fn stage_input(pending: &str, input: &str) -> StagedInput {
    let mut submitted = Vec::new();
    let mut line = pending.to_string();
    let mut edited = has_line_editing(&line);
    for c in input.chars() {
        match c {
            // Ctrl+O is bash and zsh "operate-and-get-next": it runs the line.
            '\r' | '\n' | '\u{0f}' => {
                submitted.push(std::mem::take(&mut line));
                edited = false;
            }
            '\u{03}' => {
                line.clear();
                edited = false;
            }
            '\u{15}' if !edited => line.clear(),
            '\u{7f}' | '\u{08}' if !edited => {
                line.pop();
            }
            _ => {
                edited |= c.is_control() && c != '\t';
                line.push(c);
            }
        }
    }
    StagedInput {
        submitted,
        pending: line,
    }
}

/// The printable text of a line, escape sequences and control characters
/// removed.
fn printable_text(line: &str) -> String {
    let mut out = String::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            match chars.next() {
                // CSI: parameters, then a final byte in `@`..`~`.
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // SS3 (`ESC O x`), else an Alt+key.
                Some('O') => {
                    chars.next();
                }
                _ => {}
            }
        } else if !c.is_control() || c == '\t' {
            out.push(c);
        }
    }
    out
}

/// Check the lines a piece of input submits (`tab_send_input`,
/// `tab_press_key`, `tab_submit_prompt`). Lines with no printable text
/// (empty, or only keys such as arrows) pass; lines of 2 characters or less
/// are interactive answers (`y`, `n`, `1`) and are only checked against the
/// blocked names; anything else is checked as a command with [`check`].
pub fn check_submitted_lines<S: AsRef<str>>(
    lines: &[S],
    permissions: &ResolvedPermissions,
) -> CheckResult {
    let mut audited = Vec::new();
    for line in lines {
        let line = line.as_ref();
        let text = printable_text(line);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.chars().count() <= 2 {
            if let Some(base) = extract_base_commands(trimmed)
                .into_iter()
                .find(|base| permissions.blocked.contains(&normalize_command(base)))
            {
                return CheckResult {
                    verdict: CommandVerdict::Blocked(base),
                    audited,
                };
            }
            continue;
        }
        let result = check(line.trim(), permissions);
        audited.extend(result.audited);
        if result.verdict != CommandVerdict::Allowed {
            return CheckResult {
                verdict: result.verdict,
                audited,
            };
        }
    }
    CheckResult {
        verdict: CommandVerdict::Allowed,
        audited,
    }
}

/// Split a command line into sub-commands and return the program name of
/// each one.
///
/// The line is read the way a shell reads it, so that quoting cannot hide a
/// program name: quotes and backslashes are removed from words (`"rm"`,
/// `'rm'`, `\rm`, `r''m` and `$'\x72m'` all give `rm`), and sub-commands
/// start after `;`, `&&`, `||`, `|`, `&`, newlines, `(`, `)`, backticks and
/// `$(` (also inside double quotes), and after `{`, `}` and `!` in command
/// position. Names come out in the order their sub-commands start.
pub fn extract_base_commands(command: &str) -> Vec<String> {
    split_sub_commands(command)
        .iter()
        .filter_map(|words| first_token(words))
        .collect()
}

/// One sub-command being read: its finished words and the current word.
#[derive(Default)]
struct SubCommand {
    /// Index of this sub-command in the output, reserved when it starts.
    slot: Option<usize>,
    words: Vec<String>,
    word: String,
    in_word: bool,
}

impl SubCommand {
    fn at_command_start(&self) -> bool {
        self.words.is_empty() && !self.in_word
    }
}

/// Where the reader is: shell code (top level, `$( )`, `( )` or backticks,
/// with the character that closes it), or a double-quoted string.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Frame {
    Code(Option<char>),
    Double,
}

struct Splitter {
    chars: Vec<char>,
    i: usize,
    frames: Vec<Frame>,
    /// One sub-command per `Frame::Code`, innermost last.
    commands: Vec<SubCommand>,
    out: Vec<Option<Vec<String>>>,
}

impl Splitter {
    fn word(&self) -> &str {
        &self.commands.last().expect("top-level sub-command").word
    }

    fn current(&mut self) -> &mut SubCommand {
        self.commands.last_mut().expect("top-level sub-command")
    }

    fn reserve_slot(&mut self) {
        if self.current().slot.is_none() {
            let slot = self.out.len();
            self.out.push(None);
            self.current().slot = Some(slot);
        }
    }

    /// Mark the current word as started (also for empty quotes).
    fn mark_word(&mut self) {
        self.reserve_slot();
        self.current().in_word = true;
    }

    fn push_char(&mut self, c: char) {
        self.mark_word();
        self.current().word.push(c);
    }

    fn end_word(&mut self) {
        let current = self.current();
        if current.in_word {
            let word = std::mem::take(&mut current.word);
            current.words.push(word);
            current.in_word = false;
        }
    }

    fn end_command(&mut self) {
        self.end_word();
        let current = self.current();
        let words = std::mem::take(&mut current.words);
        if let Some(slot) = current.slot.take()
            && !words.is_empty()
        {
            self.out[slot] = Some(words);
        }
    }

    /// Enter `$( )`, `( )` or backticks: a new sub-command.
    fn open_code(&mut self, closer: char) {
        self.frames.push(Frame::Code(Some(closer)));
        self.commands.push(SubCommand::default());
    }

    /// Leave the innermost code frame; its text is part of the outer word.
    fn close_code(&mut self) {
        self.end_command();
        self.frames.pop();
        self.commands.pop();
        let at_start = self
            .commands
            .last()
            .is_some_and(SubCommand::at_command_start);
        if self.frames.last() == Some(&Frame::Double) || !at_start {
            self.mark_word();
        }
    }

    fn top(&self) -> Frame {
        *self.frames.last().expect("top-level frame")
    }

    fn peek(&self, offset: usize) -> Option<char> {
        self.chars.get(self.i + offset).copied()
    }

    /// Copy a balanced `open`..`close` span (`${...}`, `$((...))`) into the
    /// current word as is, starting at the opening character.
    fn copy_balanced(&mut self, open: char, close: char) {
        let mut depth = 0usize;
        while let Some(c) = self.peek(0) {
            self.push_char(c);
            self.i += 1;
            if c == open {
                depth += 1;
            } else if c == close {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    break;
                }
            }
        }
    }

    /// `$'...'` (ANSI-C quoting): the decoded text joins the word.
    fn read_ansi_c(&mut self) {
        self.mark_word();
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '\'' => return,
                '\\' => {
                    let decoded = self.ansi_c_escape();
                    if let Some(decoded) = decoded {
                        self.push_char(decoded);
                    }
                }
                _ => self.push_char(c),
            }
        }
    }

    fn ansi_c_escape(&mut self) -> Option<char> {
        let c = self.peek(0)?;
        self.i += 1;
        let radix_digits = |this: &mut Self, radix: u32, max: usize| {
            let mut value = 0u32;
            let mut count = 0;
            while count < max
                && let Some(d) = this.peek(0).and_then(|d| d.to_digit(radix))
            {
                value = value * radix + d;
                this.i += 1;
                count += 1;
            }
            (count > 0).then(|| char::from_u32(value)).flatten()
        };
        Some(match c {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'a' => '\x07',
            'b' => '\x08',
            'e' | 'E' => '\x1b',
            'f' => '\x0c',
            'v' => '\x0b',
            'x' => return radix_digits(self, 16, 2),
            'u' => return radix_digits(self, 16, 4),
            'U' => return radix_digits(self, 16, 8),
            '0'..='7' => {
                self.i -= 1;
                return radix_digits(self, 8, 3);
            }
            other => other,
        })
    }

    fn read_code(&mut self, closer: Option<char>) {
        let c = self.chars[self.i];
        let next = self.peek(1);
        match c {
            '\\' => {
                match next {
                    // Line continuation.
                    Some('\n') => {}
                    Some(escaped) => self.push_char(escaped),
                    None => {}
                }
                self.i += 2;
            }
            '\'' => {
                self.mark_word();
                self.i += 1;
                while let Some(quoted) = self.peek(0) {
                    self.i += 1;
                    if quoted == '\'' {
                        break;
                    }
                    self.push_char(quoted);
                }
            }
            '"' => {
                self.mark_word();
                self.frames.push(Frame::Double);
                self.i += 1;
            }
            '$' if next == Some('\'') => {
                self.i += 2;
                self.read_ansi_c();
            }
            '$' if next == Some('"') => {
                // `$"..."`: a translated double-quoted string.
                self.i += 1;
            }
            '$' => self.read_dollar(),
            '`' => {
                self.i += 1;
                if closer == Some('`') {
                    self.close_code();
                } else {
                    self.open_code('`');
                }
            }
            '(' => {
                self.end_command();
                self.i += 1;
                self.open_code(')');
            }
            ')' => {
                self.i += 1;
                if closer == Some(')') {
                    self.close_code();
                } else {
                    self.end_command();
                }
            }
            // `>&`, `<&`, `&>`: redirections, not the background operator.
            '&' if self.word().ends_with(['>', '<']) || next == Some('>') => {
                self.push_char(c);
                self.i += 1;
            }
            // `>|`: a redirection, not a pipe.
            '|' if self.word().ends_with('>') => {
                self.push_char(c);
                self.i += 1;
            }
            ';' | '&' | '|' | '\n' | '\r' => {
                self.end_command();
                self.i += 1;
            }
            // Reserved words in command position: `{ rm x; }`, `! rm x`.
            '{' | '}' | '!'
                if self
                    .commands
                    .last()
                    .is_some_and(SubCommand::at_command_start) =>
            {
                self.i += 1;
            }
            c if c == ' ' || c == '\t' => {
                self.end_word();
                self.i += 1;
            }
            _ => {
                self.push_char(c);
                self.i += 1;
            }
        }
    }

    /// `$(`, `$((`, `${` or a plain `$`.
    fn read_dollar(&mut self) {
        match (self.peek(1), self.peek(2)) {
            (Some('('), Some('(')) => {
                self.push_char('$');
                self.i += 1;
                self.copy_balanced('(', ')');
            }
            (Some('('), _) => {
                self.i += 2;
                self.open_code(')');
            }
            (Some('{'), _) => {
                self.push_char('$');
                self.i += 1;
                self.copy_balanced('{', '}');
            }
            _ => {
                self.push_char('$');
                self.i += 1;
            }
        }
    }

    fn read_double(&mut self) {
        let c = self.chars[self.i];
        let next = self.peek(1);
        match c {
            '"' => {
                self.frames.pop();
                self.i += 1;
            }
            '\\' if matches!(next, Some('$' | '`' | '"' | '\\' | '\n')) => {
                if next != Some('\n') {
                    self.push_char(next.unwrap_or_default());
                }
                self.i += 2;
            }
            '$' => self.read_dollar(),
            '`' => {
                self.i += 1;
                self.open_code('`');
            }
            _ => {
                self.push_char(c);
                self.i += 1;
            }
        }
    }

    fn run(mut self) -> Vec<Vec<String>> {
        while self.i < self.chars.len() {
            match self.top() {
                Frame::Code(closer) => self.read_code(closer),
                Frame::Double => self.read_double(),
            }
        }
        // Unterminated quotes or substitutions: close everything.
        while self.frames.len() > 1 {
            match self.top() {
                Frame::Double => {
                    self.frames.pop();
                }
                Frame::Code(_) => self.close_code(),
            }
        }
        self.end_command();
        self.out.into_iter().flatten().collect()
    }
}

/// The words of each sub-command, quotes and backslashes removed.
fn split_sub_commands(command: &str) -> Vec<Vec<String>> {
    Splitter {
        chars: command.chars().collect(),
        i: 0,
        frames: vec![Frame::Code(None)],
        commands: vec![SubCommand::default()],
        out: Vec::new(),
    }
    .run()
}

/// `NAME=value` or `NAME+=value`, with a shell identifier as the name.
fn is_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let name = name.strip_suffix('+').unwrap_or(name);
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A redirection word (`>out`, `2>&1`, `<`, `&>>log`), and whether its
/// target is the next word.
fn redirection(word: &str) -> Option<bool> {
    let rest = word.trim_start_matches(|c: char| c.is_ascii_digit());
    let rest = rest.strip_prefix('&').unwrap_or(rest);
    if !rest.starts_with(['<', '>']) {
        return None;
    }
    let target = rest.trim_start_matches(['<', '>', '&', '|']);
    Some(target.is_empty())
}

/// The program name of one sub-command: skips `VAR=value`, redirections,
/// flags (and the values of known wrapper options such as `sudo -u root`),
/// and the prefixes `sudo`, `command`, `builtin`, `env`, `nohup`, `nice`,
/// `time`, `exec` and the reserved words `if`, `then`, `else`, `elif`,
/// `while`, `until`, `do`.
fn first_token(words: &[String]) -> Option<String> {
    const PASSTHROUGH: [&str; 15] = [
        "sudo", "command", "builtin", "env", "nohup", "nice", "time", "exec", "if", "then", "else",
        "elif", "while", "until", "do",
    ];
    // Wrapper options that take a separate value.
    fn takes_value(wrapper: &str, option: &str) -> bool {
        match wrapper {
            "sudo" => matches!(
                option,
                "-u" | "-g" | "-h" | "-p" | "-C" | "-D" | "-r" | "-t" | "-U" | "-T"
            ),
            "nice" => option == "-n",
            "env" => matches!(option, "-u" | "-C"),
            "exec" => option == "-a",
            _ => false,
        }
    }
    let first = words.first()?;
    let mut wrapper: Option<String> = None;
    let mut skip_next = false;
    for word in words {
        if std::mem::take(&mut skip_next) {
            continue;
        }
        if let Some(target_is_next) = redirection(word) {
            skip_next = target_is_next;
            continue;
        }
        if is_assignment(word) {
            continue;
        }
        if word.starts_with('-') {
            skip_next = wrapper
                .as_deref()
                .is_some_and(|wrapper| takes_value(wrapper, word));
            continue;
        }
        let base = normalize_command(word);
        if PASSTHROUGH.contains(&base.as_str()) {
            wrapper = Some(base);
            continue;
        }
        return Some(base);
    }
    Some(normalize_command(first))
}

/// Base name, lowercased, without quotes or backslashes: `/usr/bin/RM`
/// gives `rm`, `./run.sh` gives `run.sh`, `"r"m` gives `rm`.
pub fn normalize_command(command: &str) -> String {
    let unquoted: String = command
        .chars()
        .filter(|c| !matches!(c, '\'' | '"' | '\\'))
        .collect();
    let command = unquoted.as_str();
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
    fn quoting_does_not_hide_the_program_name() {
        for command in [
            "\"rm\" -rf x",
            "'rm' x",
            "\\rm x",
            "r''m x",
            "r\"\"m x",
            "$'\\x72m' x",
            "$'\\162m' x",
            "'/bin/rm' '-rf' '/'",
            "FOO='a b' rm x",
            "FOO=\"a b\" rm x",
        ] {
            assert_eq!(extract_base_commands(command), ["rm"], "{command}");
        }
    }

    #[test]
    fn subshells_groups_and_substitutions_are_sub_commands() {
        assert_eq!(extract_base_commands("(rm -rf x)"), ["rm"]);
        assert_eq!(extract_base_commands("{ rm x; }"), ["rm"]);
        assert_eq!(extract_base_commands("! rm x"), ["rm"]);
        assert_eq!(extract_base_commands("!rm x"), ["rm"]);
        assert_eq!(extract_base_commands("echo `rm x`"), ["echo", "rm"]);
        assert_eq!(extract_base_commands("echo \"`rm x`\""), ["echo", "rm"]);
        assert_eq!(extract_base_commands("echo \"$(rm x)\""), ["echo", "rm"]);
        assert_eq!(
            extract_base_commands("ls; (cd x && rm y)"),
            ["ls", "cd", "rm"]
        );
        assert_eq!(extract_base_commands("cat <(rm x)"), ["cat", "rm"]);
        assert_eq!(extract_base_commands("f() { rm x; }"), ["f", "rm"]);
        assert_eq!(
            extract_base_commands("if rm x; then :; fi"),
            ["rm", ":", "fi"]
        );
        assert_eq!(
            extract_base_commands("while true; do rm x; done"),
            ["true", "rm", "done"]
        );
    }

    #[test]
    fn wrappers_redirections_and_assignments_are_skipped() {
        assert_eq!(extract_base_commands("sudo -u root rm -rf /"), ["rm"]);
        assert_eq!(extract_base_commands("nice -n 10 rm x"), ["rm"]);
        assert_eq!(extract_base_commands(">out rm x"), ["rm"]);
        assert_eq!(extract_base_commands("2> /dev/null rm x"), ["rm"]);
        assert_eq!(extract_base_commands("ls 2>&1 | grep x"), ["ls", "grep"]);
        assert_eq!(extract_base_commands("ls &> out"), ["ls"]);
        // Only identifiers can be assigned: this runs `./x=1`.
        assert_eq!(extract_base_commands("./x=1 git"), ["x=1"]);
    }

    #[test]
    fn literal_text_is_not_split() {
        assert_eq!(
            extract_base_commands("git commit -m \"fix (x); y {z}\""),
            ["git"]
        );
        assert_eq!(extract_base_commands("echo {a,b} hi!"), ["echo"]);
        assert_eq!(extract_base_commands("echo ${HOME} $((1 + 2))"), ["echo"]);
        assert_eq!(extract_base_commands("echo $(date)foo"), ["echo", "date"]);
        assert_eq!(extract_base_commands("echo 'unterminated"), ["echo"]);
    }

    #[test]
    fn quoted_blocked_commands_are_blocked() {
        let p = global(MCPPermissionMode::AllowAll, &[], &["rm"]);
        for command in [
            "\"rm\" -rf x",
            "'rm' x",
            "\\rm x",
            "r''m x",
            "(rm -rf x)",
            "{ rm x; }",
            "echo `rm x`",
            // `GenericShellBackend::launch_command` quotes every argument.
            "'rm' '-rf' '/'",
        ] {
            assert_eq!(
                check(command, &p).verdict,
                CommandVerdict::Blocked("rm".into()),
                "{command}"
            );
        }
    }

    #[test]
    fn normalize_strips_path_and_case() {
        assert_eq!(normalize_command("\"/bin/r\\m\""), "rm");
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
    fn raw_input_checks_every_submitted_line() {
        let p = global(MCPPermissionMode::AllowAll, &[], &["rm"]);
        for input in [
            "ls\nrm -rf ~\n",
            "ls\rrm -rf ~\rls",
            "rm -rf ~\u{f}",
            "ls\n\nrm x\nls",
        ] {
            assert_eq!(
                check_raw_input(input, &p).verdict,
                CommandVerdict::Blocked("rm".into()),
                "{input:?}"
            );
        }
        // Text after the last line end is still being typed.
        assert_eq!(
            check_raw_input("ls\nrm -rf ~", &p).verdict,
            CommandVerdict::Allowed
        );
        // Short answers are only checked against the blocked names.
        let allowlist = global(MCPPermissionMode::Allowlist, &[], &["rm"]);
        assert_eq!(
            check_raw_input("y\nn\r", &allowlist).verdict,
            CommandVerdict::Allowed
        );
        assert_eq!(
            check_raw_input("rm\n", &allowlist).verdict,
            CommandVerdict::Blocked("rm".into())
        );
    }

    #[test]
    fn staged_input_is_checked_when_submitted() {
        let p = global(MCPPermissionMode::AllowAll, &[], &["rm"]);
        // `tab_send_input "rm -rf ~"`, then `tab_submit_prompt` (Enter).
        let typed = stage_input("", "rm -rf ~");
        assert!(typed.submitted.is_empty());
        assert_eq!(typed.pending, "rm -rf ~");
        let entered = stage_input(&typed.pending, "\r");
        assert_eq!(entered.submitted, ["rm -rf ~"]);
        assert_eq!(entered.pending, "");
        assert_eq!(
            check_submitted_lines(&entered.submitted, &p).verdict,
            CommandVerdict::Blocked("rm".into())
        );
        // `tab_send_input "ls\nrm -rf ~"` leaves `rm -rf ~` on the line.
        assert_eq!(stage_input("", "ls\nrm -rf ~").pending, "rm -rf ~");
        // Typed in pieces.
        let r = stage_input("", "r");
        let rm = stage_input(&r.pending, "m -rf ~\n");
        assert_eq!(rm.submitted, ["rm -rf ~"]);
        // Ctrl+C drops the line; Ctrl+U and Backspace edit it.
        assert_eq!(stage_input("rm -rf ~", "\u{3}\r").submitted, [""]);
        assert_eq!(stage_input("x", "\u{15}rm\r").submitted, ["rm"]);
        assert_eq!(stage_input("rmx", "\u{7f}\r").submitted, ["rm"]);
        assert!(!stage_input("", "x").overflows());
        assert!(stage_input("", &"x".repeat(MAX_PENDING_INPUT_CHARS + 1)).overflows());
    }

    #[test]
    fn line_editing_keys_need_approval() {
        // Ctrl+A then `r`: the shell runs `rm -rf ~`.
        let line = stage_input("m -rf ~", "\u{1}r\r");
        let allow_all = global(MCPPermissionMode::AllowAll, &[], &["rm"]);
        assert_eq!(
            check_submitted_lines(&line.submitted, &allow_all).verdict,
            CommandVerdict::NeedsApproval(LINE_EDITING_INPUT.into())
        );
        // Left arrow, then Backspace: kept as editing keys.
        let line = stage_input("rmx -rf ~", "\u{1b}[D\u{7f}\r");
        assert_eq!(line.submitted, ["rmx -rf ~\u{1b}[D\u{7f}"]);
        assert_eq!(
            check_submitted_lines(&line.submitted, &allow_all).verdict,
            CommandVerdict::NeedsApproval(LINE_EDITING_INPUT.into())
        );
        let allowlist = global(MCPPermissionMode::Allowlist, &["ls"], &[]);
        assert_eq!(
            check("ls\u{1}x", &allowlist).verdict,
            CommandVerdict::Blocked(LINE_EDITING_INPUT.into())
        );
        // A blocked name still wins.
        assert_eq!(
            check("rm x\u{1}", &allow_all).verdict,
            CommandVerdict::Blocked("rm".into())
        );
        // Keys alone (menu navigation in a TUI) pass.
        let keys = stage_input("", "\u{1b}[B\u{1b}[B\r");
        assert_eq!(
            check_submitted_lines(&keys.submitted, &allowlist).verdict,
            CommandVerdict::Allowed
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

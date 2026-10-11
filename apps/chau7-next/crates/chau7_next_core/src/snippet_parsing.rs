//! Snippet placeholder expansion and token replacement.
//!
//! Port of `SnippetParsing.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//!
//! The Swift version uses `NSRegularExpression`; this crate has no
//! dependencies, so the same patterns are matched by hand:
//!
//! - placeholders: `\$\{(\d+)(?::([^}]*))?\}`
//! - env tokens: `\$\{env:([A-Za-z0-9_]+)\}`
//! - placeholder detection: `\$\{\d+`
//!
//! Offsets and lengths are counted in `char`s (Unicode scalars). Swift counts
//! `Character`s (grapheme clusters), so the two differ only for text that
//! contains multi-scalar graphemes. `\d` is matched as ASCII digits only;
//! Swift's `\d` also accepts other Unicode decimal digits, but those then fail
//! `Int(...)` and fall back to index 0.

/// A tab stop in an expanded snippet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placeholder {
    pub index: usize,
    /// Offset in chars from the start of the expanded text.
    pub start: usize,
    /// Length in chars of the default text.
    pub length: usize,
}

impl Placeholder {
    pub const fn new(index: usize, start: usize, length: usize) -> Self {
        Self {
            index,
            start,
            length,
        }
    }
}

/// Result of expanding placeholders in a snippet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpansionResult {
    pub text: String,
    pub placeholders: Vec<Placeholder>,
    pub final_cursor_offset: Option<usize>,
}

/// One `${N}` or `${N:default}` match, as byte offsets into the input.
struct PlaceholderMatch<'a> {
    start: usize,
    end: usize,
    index: &'a str,
    default_text: &'a str,
}

/// Tries to match the placeholder pattern at byte offset `at`.
fn match_placeholder_at(input: &str, at: usize) -> Option<PlaceholderMatch<'_>> {
    let rest = &input[at..];
    let body = rest.strip_prefix("${")?;
    let digits_len = body.bytes().take_while(u8::is_ascii_digit).count();
    if digits_len == 0 {
        return None;
    }
    let index = &body[..digits_len];
    let after_digits = &body[digits_len..];
    let digits_end = at + 2 + digits_len;

    // Optional `:[^}]*` group, which only matches if a closing `}` follows.
    if let Some(default_and_rest) = after_digits.strip_prefix(':')
        && let Some(close) = default_and_rest.find('}')
    {
        let default_text = &default_and_rest[..close];
        return Some(PlaceholderMatch {
            start: at,
            end: digits_end + 1 + close + 1,
            index,
            default_text,
        });
    }

    after_digits.starts_with('}').then_some(PlaceholderMatch {
        start: at,
        end: digits_end + 1,
        index,
        default_text: "",
    })
}

/// Finds all non-overlapping placeholder matches, left to right.
fn placeholder_matches(input: &str) -> Vec<PlaceholderMatch<'_>> {
    let mut matches = Vec::new();
    let mut pos = 0;
    while let Some(found) = input[pos..].find("${") {
        let at = pos + found;
        if let Some(m) = match_placeholder_at(input, at) {
            pos = m.end;
            matches.push(m);
        } else {
            // `$` is one byte, so `at + 1` is a char boundary.
            pos = at + 1;
        }
    }
    matches
}

/// Expands placeholders in the format `${1}`, `${2:default}`, `${0}` (final
/// cursor). Placeholders are returned sorted by index, then by start.
pub fn expand_placeholders(input: &str) -> ExpansionResult {
    let matches = placeholder_matches(input);
    if matches.is_empty() {
        return ExpansionResult {
            text: input.to_string(),
            placeholders: Vec::new(),
            final_cursor_offset: None,
        };
    }

    let mut output = String::with_capacity(input.len());
    let mut placeholders = Vec::new();
    let mut cursor = 0;
    let mut current_length = 0;
    let mut final_offset = None;

    for m in &matches {
        let before = &input[cursor..m.start];
        output.push_str(before);
        current_length += before.chars().count();

        // Swift: `Int(indexString) ?? 0`, where Int is 64-bit signed.
        let index = m.index.parse::<i64>().map_or(0, |v| v as usize);
        let default_len = m.default_text.chars().count();

        output.push_str(m.default_text);

        if index == 0 {
            final_offset = Some(current_length + default_len);
        } else {
            placeholders.push(Placeholder::new(index, current_length, default_len));
        }
        current_length += default_len;
        cursor = m.end;
    }

    output.push_str(&input[cursor..]);

    placeholders.sort_by(|a, b| a.index.cmp(&b.index).then(a.start.cmp(&b.start)));

    ExpansionResult {
        text: output,
        placeholders,
        final_cursor_offset: final_offset,
    }
}

/// Replaces `${env:VARNAME}` tokens with values from the process environment.
/// Unset or non-UTF-8 variables expand to an empty string.
pub fn replace_env_tokens(input: &str) -> String {
    replace_env_tokens_with(input, |key| std::env::var(key).unwrap_or_default())
}

/// Replaces `${env:VARNAME}` tokens using a custom provider (for testing).
pub fn replace_env_tokens_with<F>(input: &str, mut provider: F) -> String
where
    F: FnMut(&str) -> String,
{
    const PREFIX: &str = "${env:";
    let mut output = String::with_capacity(input.len());
    let mut pos = 0;

    while let Some(found) = input[pos..].find(PREFIX) {
        let at = pos + found;
        let name_start = at + PREFIX.len();
        let name_len = input[name_start..]
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
            .count();
        let name_end = name_start + name_len;

        if name_len > 0 && input[name_end..].starts_with('}') {
            output.push_str(&input[pos..at]);
            output.push_str(&provider(&input[name_start..name_end]));
            pos = name_end + 1;
        } else {
            output.push_str(&input[pos..at + 1]);
            pos = at + 1;
        }
    }

    output.push_str(&input[pos..]);
    output
}

/// Parses a comma-separated list into trimmed, non-empty values.
pub fn parse_csv(text: &str) -> Vec<String> {
    text.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Checks if text contains any of the standard tokens.
pub fn contains_tokens(text: &str) -> bool {
    const TOKENS: [&str; 5] = ["${cwd}", "${home}", "${date}", "${time}", "${clip}"];
    TOKENS.iter().any(|token| text.contains(token))
}

/// Checks if text contains environment variable tokens.
pub fn contains_env_tokens(text: &str) -> bool {
    text.contains("${env:")
}

/// Checks if text contains placeholder syntax (`${` followed by a digit).
pub fn contains_placeholders(text: &str) -> bool {
    text.match_indices("${").any(|(at, _)| {
        text.as_bytes()
            .get(at + 2)
            .is_some_and(|b| b.is_ascii_digit())
    })
}

#[cfg(test)]
mod tests {
    // Ported from SnippetParsingTests.swift. No tests skipped.
    use super::*;

    // Placeholder expansion

    #[test]
    fn expand_simple_placeholder() {
        let result = expand_placeholders("Hello ${1}");
        assert_eq!(result.text, "Hello ");
        assert_eq!(result.placeholders.len(), 1);
        assert_eq!(result.placeholders[0].index, 1);
        assert_eq!(result.placeholders[0].start, 6);
        assert_eq!(result.placeholders[0].length, 0);
    }

    #[test]
    fn expand_placeholder_with_default() {
        let result = expand_placeholders("Hello ${1:World}");
        assert_eq!(result.text, "Hello World");
        assert_eq!(result.placeholders.len(), 1);
        assert_eq!(result.placeholders[0].index, 1);
        assert_eq!(result.placeholders[0].start, 6);
        assert_eq!(result.placeholders[0].length, 5);
    }

    #[test]
    fn expand_multiple_placeholders() {
        let result = expand_placeholders("${1:first} and ${2:second}");
        assert_eq!(result.text, "first and second");
        assert_eq!(result.placeholders.len(), 2);
        assert_eq!(result.placeholders[0].index, 1);
        assert_eq!(result.placeholders[1].index, 2);
    }

    #[test]
    fn expand_final_cursor_position() {
        let result = expand_placeholders("Hello ${1:name}!${0}");
        assert_eq!(result.text, "Hello name!");
        assert_eq!(result.final_cursor_offset, Some(11));
    }

    #[test]
    fn expand_no_placeholders() {
        let result = expand_placeholders("Hello World");
        assert_eq!(result.text, "Hello World");
        assert_eq!(result.placeholders.len(), 0);
        assert_eq!(result.final_cursor_offset, None);
    }

    #[test]
    fn expand_placeholders_sorted() {
        let result = expand_placeholders("${3:c} ${1:a} ${2:b}");
        assert_eq!(result.placeholders[0].index, 1);
        assert_eq!(result.placeholders[1].index, 2);
        assert_eq!(result.placeholders[2].index, 3);
    }

    #[test]
    fn expand_empty_default() {
        let result = expand_placeholders("prefix${1}suffix");
        assert_eq!(result.text, "prefixsuffix");
        assert_eq!(result.placeholders[0].start, 6);
        assert_eq!(result.placeholders[0].length, 0);
    }

    // Environment tokens

    #[test]
    fn replace_env_tokens_single() {
        let result = replace_env_tokens_with("User: ${env:USER}", |key| {
            if key == "USER" {
                "testuser".to_string()
            } else {
                String::new()
            }
        });
        assert_eq!(result, "User: testuser");
    }

    #[test]
    fn replace_multiple_env_tokens() {
        let result = replace_env_tokens_with("${env:HOME}/${env:USER}", |key| {
            match key {
                "HOME" => "/home/test",
                "USER" => "testuser",
                _ => "",
            }
            .to_string()
        });
        assert_eq!(result, "/home/test/testuser");
    }

    #[test]
    fn replace_missing_env_token() {
        let result = replace_env_tokens_with("Value: ${env:MISSING}", |_| String::new());
        assert_eq!(result, "Value: ");
    }

    #[test]
    fn no_env_tokens() {
        let result = replace_env_tokens_with("No tokens here", |_| "FAIL".to_string());
        assert_eq!(result, "No tokens here");
    }

    // CSV parsing

    #[test]
    fn parse_csv_basic() {
        assert_eq!(parse_csv("a, b, c"), vec!["a", "b", "c"]);
    }

    #[test]
    fn parse_csv_with_spaces() {
        assert_eq!(parse_csv("  hello  ,  world  "), vec!["hello", "world"]);
    }

    #[test]
    fn parse_csv_empty() {
        assert!(parse_csv("").is_empty());
        assert!(parse_csv("  ").is_empty());
    }

    #[test]
    fn parse_csv_empty_values() {
        assert_eq!(parse_csv("a,,b,  ,c"), vec!["a", "b", "c"]);
    }

    #[test]
    fn parse_csv_single_value() {
        assert_eq!(parse_csv("single"), vec!["single"]);
    }

    // Token detection

    #[test]
    fn contains_tokens_detects_standard_tokens() {
        assert!(contains_tokens("cd ${cwd}"));
        assert!(contains_tokens("Home: ${home}"));
        assert!(contains_tokens("Date: ${date}"));
        assert!(contains_tokens("Time: ${time}"));
        assert!(contains_tokens("Paste: ${clip}"));
        assert!(!contains_tokens("No tokens"));
    }

    #[test]
    fn contains_env_tokens_detects_env_prefix() {
        assert!(contains_env_tokens("${env:PATH}"));
        assert!(contains_env_tokens("User is ${env:USER}"));
        assert!(!contains_env_tokens("$PATH"));
        assert!(!contains_env_tokens("${PATH}"));
    }

    #[test]
    fn contains_placeholders_detects_numbered_placeholders() {
        assert!(contains_placeholders("${1}"));
        assert!(contains_placeholders("${0}"));
        assert!(contains_placeholders("Hello ${1:name}"));
        assert!(!contains_placeholders("${env:VAR}"));
        assert!(!contains_placeholders("${cwd}"));
        assert!(!contains_placeholders("No placeholders"));
    }

    // Complex snippets

    #[test]
    fn complex_snippet_expansion() {
        let snippet = "function ${1:name}(${2:params}) {\n    ${0}\n}";
        let result = expand_placeholders(snippet);
        // Indentation before ${0} is preserved when the placeholder is removed.
        assert_eq!(result.text, "function name(params) {\n    \n}");
        assert_eq!(result.placeholders.len(), 2);
        assert!(result.final_cursor_offset.is_some());
    }

    #[test]
    fn mixed_tokens_and_placeholders() {
        // Only tests placeholder expansion, not token replacement.
        let result = expand_placeholders("${cwd}/${1:filename}");
        assert_eq!(result.text, "${cwd}/filename");
        assert_eq!(result.placeholders.len(), 1);
    }

    // Extra coverage for the hand-written matchers (not in the Swift suite).

    #[test]
    fn expand_unterminated_default_is_left_alone() {
        let result = expand_placeholders("${1:open");
        assert_eq!(result.text, "${1:open");
        assert!(result.placeholders.is_empty());
    }

    #[test]
    fn expand_default_runs_to_first_closing_brace() {
        // Same as the regex: `[^}]*` swallows a nested `${2` up to the first `}`.
        let result = expand_placeholders("${1:a ${2} b}");
        assert_eq!(result.text, "a ${2 b}");
        assert_eq!(result.placeholders, vec![Placeholder::new(1, 0, 5)]);
    }

    #[test]
    fn expand_counts_chars_not_bytes() {
        let result = expand_placeholders("é ${1:ü}");
        assert_eq!(result.placeholders, vec![Placeholder::new(1, 2, 1)]);
    }

    #[test]
    fn replace_env_tokens_ignores_invalid_names() {
        let result =
            replace_env_tokens_with("${env:} ${env:A-B} ${env:${env:X}", |k| format!("<{k}>"));
        assert_eq!(result, "${env:} ${env:A-B} ${env:<X>");
    }

    #[test]
    fn replace_env_tokens_reads_process_environment() {
        let path = std::env::var("PATH").unwrap_or_default();
        assert_eq!(replace_env_tokens("${env:PATH}"), path);
    }
}

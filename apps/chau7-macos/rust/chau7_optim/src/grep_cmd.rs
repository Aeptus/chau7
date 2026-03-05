use crate::tracking;
use anyhow::{Context, Result};
use regex::Regex;
use std::collections::HashMap;
use std::process::Command;

/// Parsed grep arguments — supports both standard grep flags and optimizer flags.
struct GrepArgs {
    pattern: String,
    path: String,
    // Flags that produce non-optimizable output → trigger fallthrough (exit 2)
    quiet: bool,       // -q / --quiet / --silent
    count: bool,       // -c / --count
    files_only: bool,  // -l / --files-with-matches
    files_without: bool, // -L / --files-without-match
    // Flags that affect matching — passed through to rg
    ignore_case: bool,    // -i
    fixed_strings: bool,  // -F
    word_regexp: bool,    // -w
    perl_regexp: bool,    // -P
    invert_match: bool,   // -v
    only_matching: bool,  // -o
    // Context flags
    after_context: Option<usize>,  // -A N
    before_context: Option<usize>, // -B N
    grep_context: Option<usize>,   // -C N (grep-style context)
    max_count: Option<usize>,      // -m N
    // Optimizer-specific (long-form only)
    max_line_len: usize,
    max_results: usize,
    context_only: bool,
    file_type: Option<String>,
    ultra_compact: bool,
    // Remaining args passed directly to rg
    extra_rg_args: Vec<String>,
}

impl Default for GrepArgs {
    fn default() -> Self {
        Self {
            pattern: String::new(),
            path: ".".into(),
            quiet: false,
            count: false,
            files_only: false,
            files_without: false,
            ignore_case: false,
            fixed_strings: false,
            word_regexp: false,
            perl_regexp: false,
            invert_match: false,
            only_matching: false,
            after_context: None,
            before_context: None,
            grep_context: None,
            max_count: None,
            max_line_len: 80,
            max_results: 50,
            context_only: false,
            file_type: None,
            ultra_compact: false,
            extra_rg_args: Vec::new(),
        }
    }
}

/// Parse grep-compatible arguments manually (bypasses clap for full flag compat).
///
/// Handles combined short flags (e.g. -rlq), flags with values (-A 3, -m5),
/// explicit pattern flag (-e PATTERN), and the `--` separator.
fn parse_grep_args(args: &[String]) -> GrepArgs {
    let mut result = GrepArgs::default();
    let mut positionals: Vec<String> = Vec::new();
    let mut explicit_patterns: Vec<String> = Vec::new();
    let mut i = 0;

    while i < args.len() {
        let arg = &args[i];

        if arg == "--" {
            positionals.extend_from_slice(&args[i + 1..]);
            break;
        }

        if arg.starts_with("--") {
            // Handle --flag=value style
            let (key, inline_val) = if let Some((k, v)) = arg.split_once('=') {
                (k, Some(v.to_string()))
            } else {
                (arg.as_str(), None)
            };

            match key {
                // Bypass flags (no optimizable output)
                "--quiet" | "--silent" => result.quiet = true,
                "--count" => result.count = true,
                "--files-with-matches" => result.files_only = true,
                "--files-without-match" => result.files_without = true,
                // Matching flags (pass through to rg)
                "--ignore-case" => result.ignore_case = true,
                "--extended-regexp" => {} // default for rg
                "--fixed-strings" => result.fixed_strings = true,
                "--word-regexp" => result.word_regexp = true,
                "--perl-regexp" => result.perl_regexp = true,
                "--invert-match" => result.invert_match = true,
                "--only-matching" => result.only_matching = true,
                "--recursive" => {} // default for rg
                "--line-number" => {} // always on
                "--with-filename" => {} // default for rg
                "--no-filename" => result.extra_rg_args.push("--no-filename".into()),
                "--no-messages" => result.extra_rg_args.push("--no-messages".into()),
                // Flags with values
                "--regexp" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    explicit_patterns.push(val);
                }
                "--after-context" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    result.after_context = val.parse().ok();
                }
                "--before-context" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    result.before_context = val.parse().ok();
                }
                "--context" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    result.grep_context = val.parse().ok();
                }
                "--max-count" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    result.max_count = val.parse().ok();
                }
                // Optimizer-specific long flags
                "--max-len" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    if let Ok(v) = val.parse() {
                        result.max_line_len = v;
                    }
                }
                "--max" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    if let Ok(v) = val.parse() {
                        result.max_results = v;
                    }
                }
                "--context-only" => result.context_only = true,
                "--file-type" => {
                    let val = inline_val.unwrap_or_else(|| {
                        i += 1;
                        args.get(i).cloned().unwrap_or_default()
                    });
                    result.file_type = Some(val);
                }
                "--ultra-compact" => result.ultra_compact = true,
                // Anything else → pass through to rg
                _ => result.extra_rg_args.push(arg.clone()),
            }
        } else if arg.starts_with('-') && arg.len() > 1 {
            // Short flags — may be combined (e.g., -rlqi)
            let chars: Vec<char> = arg[1..].chars().collect();
            let mut j = 0;
            while j < chars.len() {
                match chars[j] {
                    // Bypass flags
                    'q' => result.quiet = true,
                    'c' => result.count = true,
                    'l' => result.files_only = true,
                    'L' => result.files_without = true,
                    // Matching flags
                    'i' => result.ignore_case = true,
                    'E' => {} // default for rg
                    'G' => {} // BRE — rg handles this differently, pass through
                    'F' => result.fixed_strings = true,
                    'w' => result.word_regexp = true,
                    'P' => result.perl_regexp = true,
                    'v' => result.invert_match = true,
                    'o' => result.only_matching = true,
                    'r' | 'R' => {} // default for rg
                    'n' => {} // always on
                    'H' => {} // default for rg
                    'h' => result.extra_rg_args.push("--no-filename".into()),
                    's' => result.extra_rg_args.push("--no-messages".into()),
                    'x' => result.extra_rg_args.push("--line-regexp".into()),
                    // -e PATTERN: rest of combined flags OR next arg is the pattern
                    'e' => {
                        let rest: String = chars[j + 1..].iter().collect();
                        if !rest.is_empty() {
                            explicit_patterns.push(rest);
                        } else {
                            i += 1;
                            if let Some(p) = args.get(i) {
                                explicit_patterns.push(p.clone());
                            }
                        }
                        j = chars.len();
                        continue;
                    }
                    // -f FILE: pattern file — can't optimize, pass through
                    'f' => {
                        let rest: String = chars[j + 1..].iter().collect();
                        if !rest.is_empty() {
                            result.extra_rg_args.push("-f".into());
                            result.extra_rg_args.push(rest);
                        } else {
                            i += 1;
                            result.extra_rg_args.push("-f".into());
                            if let Some(v) = args.get(i) {
                                result.extra_rg_args.push(v.clone());
                            }
                        }
                        j = chars.len();
                        continue;
                    }
                    // Flags with numeric value: -A N, -B N, -C N, -m N
                    'A' | 'B' | 'C' | 'm' => {
                        let rest: String = chars[j + 1..].iter().collect();
                        let value_str = if !rest.is_empty() {
                            rest
                        } else {
                            i += 1;
                            args.get(i).cloned().unwrap_or_default()
                        };
                        let value = value_str.parse().ok();
                        match chars[j] {
                            'A' => result.after_context = value,
                            'B' => result.before_context = value,
                            'C' => result.grep_context = value,
                            'm' => result.max_count = value,
                            _ => unreachable!(),
                        }
                        j = chars.len();
                        continue;
                    }
                    // Optimizer short flags (non-conflicting)
                    't' => {
                        let rest: String = chars[j + 1..].iter().collect();
                        let val = if !rest.is_empty() {
                            rest
                        } else {
                            i += 1;
                            args.get(i).cloned().unwrap_or_default()
                        };
                        result.file_type = Some(val);
                        j = chars.len();
                        continue;
                    }
                    'u' => result.ultra_compact = true,
                    // Unknown flag → pass through
                    ch => result.extra_rg_args.push(format!("-{}", ch)),
                }
                j += 1;
            }
        } else {
            positionals.push(arg.clone());
        }

        i += 1;
    }

    // Pattern: from -e flags if present, otherwise first positional
    if !explicit_patterns.is_empty() {
        result.pattern = explicit_patterns.join("|");
        result.path = positionals
            .first()
            .cloned()
            .unwrap_or_else(|| ".".into());
    } else {
        result.pattern = positionals
            .first()
            .cloned()
            .unwrap_or_default();
        result.path = positionals
            .get(1)
            .cloned()
            .unwrap_or_else(|| ".".into());
        // Additional positional paths → pass to rg
        for p in positionals.iter().skip(2) {
            result.extra_rg_args.push(p.clone());
        }
    }

    result
}

pub fn run(args: &[String], verbose: u8) -> Result<()> {
    let parsed = parse_grep_args(args);

    // No pattern → nothing to do, let real grep show usage
    if parsed.pattern.is_empty() {
        std::process::exit(2);
    }

    // Flags that produce non-standard output → fall through to real binary
    if parsed.quiet || parsed.count || parsed.files_only || parsed.files_without {
        std::process::exit(2);
    }

    let timer = tracking::TimedExecution::start();

    if verbose > 0 {
        eprintln!("grep: '{}' in {}", parsed.pattern, parsed.path);
    }

    // Fix: convert BRE alternation \| → | for rg (which uses PCRE-style regex)
    let rg_pattern = parsed.pattern.replace(r"\|", "|");

    let mut rg_cmd = Command::new("rg");
    rg_cmd.args(["-n", "--no-heading", &rg_pattern, &parsed.path]);

    // Matching flags
    if parsed.ignore_case {
        rg_cmd.arg("-i");
    }
    if parsed.fixed_strings {
        rg_cmd.arg("-F");
    }
    if parsed.word_regexp {
        rg_cmd.arg("-w");
    }
    if parsed.perl_regexp {
        rg_cmd.arg("-P");
    }
    if parsed.invert_match {
        rg_cmd.arg("-v");
    }
    if parsed.only_matching {
        rg_cmd.arg("--only-matching");
    }
    // Context flags
    if let Some(n) = parsed.after_context {
        rg_cmd.args(["-A", &n.to_string()]);
    }
    if let Some(n) = parsed.before_context {
        rg_cmd.args(["-B", &n.to_string()]);
    }
    if let Some(n) = parsed.grep_context {
        rg_cmd.args(["-C", &n.to_string()]);
    }
    if let Some(n) = parsed.max_count {
        rg_cmd.args(["-m", &n.to_string()]);
    }

    if let Some(ref ft) = parsed.file_type {
        rg_cmd.arg("--type").arg(ft);
    }

    for arg in &parsed.extra_rg_args {
        // Skip -r (rg is recursive by default; rg -r means --replace)
        if arg == "-r" || arg == "--recursive" {
            continue;
        }
        rg_cmd.arg(arg);
    }

    let output = rg_cmd
        .output()
        .or_else(|_| {
            Command::new("grep")
                .args(["-rn", &parsed.pattern, &parsed.path])
                .output()
        })
        .context("grep/rg failed")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let exit_code = output.status.code().unwrap_or(1);

    let raw_output = stdout.to_string();

    if stdout.trim().is_empty() {
        if exit_code == 2 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.trim().is_empty() {
                eprintln!("{}", stderr.trim());
            }
        }
        let msg = format!("🔍 0 for '{}'", parsed.pattern);
        println!("{}", msg);
        timer.track(
            &format!("grep -rn '{}' {}", parsed.pattern, parsed.path),
            "rtk grep",
            &raw_output,
            &msg,
        );
        if exit_code != 0 {
            std::process::exit(exit_code);
        }
        return Ok(());
    }

    let mut by_file: HashMap<String, Vec<(usize, String)>> = HashMap::new();
    let mut total = 0;

    for line in stdout.lines() {
        let parts: Vec<&str> = line.splitn(3, ':').collect();

        let (file, line_num, content) = if parts.len() == 3 {
            let ln = parts[1].parse().unwrap_or(0);
            (parts[0].to_string(), ln, parts[2])
        } else if parts.len() == 2 {
            let ln = parts[0].parse().unwrap_or(0);
            (parsed.path.to_string(), ln, parts[1])
        } else {
            continue;
        };

        total += 1;
        let cleaned = clean_line(
            content,
            parsed.max_line_len,
            parsed.context_only,
            &parsed.pattern,
        );
        by_file.entry(file).or_default().push((line_num, cleaned));
    }

    let mut rtk_output = String::new();
    rtk_output.push_str(&format!("🔍 {} in {}F:\n\n", total, by_file.len()));

    let mut shown = 0;
    let mut files: Vec<_> = by_file.iter().collect();
    files.sort_by_key(|(f, _)| *f);

    for (file, matches) in files {
        if shown >= parsed.max_results {
            break;
        }

        let file_display = compact_path(file);
        rtk_output.push_str(&format!("📄 {} ({}):\n", file_display, matches.len()));

        for (line_num, content) in matches.iter().take(10) {
            rtk_output.push_str(&format!("  {:>4}: {}\n", line_num, content));
            shown += 1;
            if shown >= parsed.max_results {
                break;
            }
        }

        if matches.len() > 10 {
            rtk_output.push_str(&format!("  +{}\n", matches.len() - 10));
        }
        rtk_output.push('\n');
    }

    if total > shown {
        rtk_output.push_str(&format!("... +{}\n", total - shown));
    }

    print!("{}", rtk_output);
    timer.track(
        &format!("grep -rn '{}' {}", parsed.pattern, parsed.path),
        "rtk grep",
        &raw_output,
        &rtk_output,
    );

    if exit_code != 0 {
        std::process::exit(exit_code);
    }

    Ok(())
}

fn clean_line(line: &str, max_len: usize, context_only: bool, pattern: &str) -> String {
    let trimmed = line.trim();

    if context_only {
        if let Ok(re) = Regex::new(&format!("(?i).{{0,20}}{}.*", regex::escape(pattern))) {
            if let Some(m) = re.find(trimmed) {
                let matched = m.as_str();
                if matched.len() <= max_len {
                    return matched.to_string();
                }
            }
        }
    }

    if trimmed.len() <= max_len {
        trimmed.to_string()
    } else {
        let lower = trimmed.to_lowercase();
        let pattern_lower = pattern.to_lowercase();

        if let Some(pos) = lower.find(&pattern_lower) {
            let char_pos = lower[..pos].chars().count();
            let chars: Vec<char> = trimmed.chars().collect();
            let char_len = chars.len();

            let start = char_pos.saturating_sub(max_len / 3);
            let end = (start + max_len).min(char_len);
            let start = if end == char_len {
                end.saturating_sub(max_len)
            } else {
                start
            };

            let slice: String = chars[start..end].iter().collect();
            if start > 0 && end < char_len {
                format!("...{}...", slice)
            } else if start > 0 {
                format!("...{}", slice)
            } else {
                format!("{}...", slice)
            }
        } else {
            let t: String = trimmed.chars().take(max_len - 3).collect();
            format!("{}...", t)
        }
    }
}

fn compact_path(path: &str) -> String {
    if path.len() <= 50 {
        return path.to_string();
    }

    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() <= 3 {
        return path.to_string();
    }

    format!(
        "{}/.../{}/{}",
        parts[0],
        parts[parts.len() - 2],
        parts[parts.len() - 1]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clean_line() {
        let line = "            const result = someFunction();";
        let cleaned = clean_line(line, 50, false, "result");
        assert!(!cleaned.starts_with(' '));
        assert!(cleaned.len() <= 50);
    }

    #[test]
    fn test_compact_path() {
        let path = "/Users/patrick/dev/project/src/components/Button.tsx";
        let compact = compact_path(path);
        assert!(compact.len() <= 60);
    }

    #[test]
    fn test_clean_line_multibyte() {
        let line = "  สวัสดีครับ นี่คือข้อความที่ยาวมากสำหรับทดสอบ  ";
        let cleaned = clean_line(line, 20, false, "ครับ");
        assert!(!cleaned.is_empty());
    }

    #[test]
    fn test_clean_line_emoji() {
        let line = "🎉🎊🎈🎁🎂🎄 some text 🎃🎆🎇✨";
        let cleaned = clean_line(line, 15, false, "text");
        assert!(!cleaned.is_empty());
    }

    #[test]
    fn test_bre_alternation_translated() {
        let pattern = r"fn foo\|pub.*bar";
        let rg_pattern = pattern.replace(r"\|", "|");
        assert_eq!(rg_pattern, "fn foo|pub.*bar");
    }

    // Flag parsing tests

    #[test]
    fn test_simple_pattern_path() {
        let args: Vec<String> = vec!["TODO".into(), "src/".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.pattern, "TODO");
        assert_eq!(parsed.path, "src/");
        assert!(!parsed.quiet);
    }

    #[test]
    fn test_quiet_flag() {
        let args: Vec<String> = vec!["-q".into(), "pattern".into(), "file".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.quiet);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_combined_flags() {
        let args: Vec<String> = vec!["-rlqi".into(), "pattern".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.quiet);
        assert!(parsed.files_only);
        assert!(parsed.ignore_case);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_ignore_case_flag() {
        let args: Vec<String> = vec!["-i".into(), "pattern".into(), ".".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.ignore_case);
        assert!(!parsed.quiet);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_extended_regexp() {
        let args: Vec<String> = vec!["-E".into(), "foo|bar".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.pattern, "foo|bar");
        assert!(!parsed.quiet);
    }

    #[test]
    fn test_explicit_pattern_with_e() {
        let args: Vec<String> = vec!["-e".into(), "pattern".into(), "file.txt".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.pattern, "pattern");
        assert_eq!(parsed.path, "file.txt");
    }

    #[test]
    fn test_context_flag_with_value() {
        let args: Vec<String> = vec!["-A".into(), "3".into(), "pattern".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.after_context, Some(3));
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_combined_context_value() {
        let args: Vec<String> = vec!["-A3".into(), "pattern".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.after_context, Some(3));
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_long_flags() {
        let args: Vec<String> = vec![
            "--ignore-case".into(),
            "--word-regexp".into(),
            "pattern".into(),
        ];
        let parsed = parse_grep_args(&args);
        assert!(parsed.ignore_case);
        assert!(parsed.word_regexp);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_long_flag_with_equals() {
        let args: Vec<String> = vec!["--max-count=10".into(), "pattern".into()];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.max_count, Some(10));
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_optimizer_flags() {
        let args: Vec<String> = vec![
            "--max-len".into(),
            "120".into(),
            "--max".into(),
            "100".into(),
            "--context-only".into(),
            "pattern".into(),
        ];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.max_line_len, 120);
        assert_eq!(parsed.max_results, 100);
        assert!(parsed.context_only);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_double_dash_separator() {
        let args: Vec<String> = vec!["-i".into(), "--".into(), "-pattern".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.ignore_case);
        assert_eq!(parsed.pattern, "-pattern");
    }

    #[test]
    fn test_count_flag_triggers_bypass() {
        let args: Vec<String> = vec!["-c".into(), "pattern".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.count);
    }

    #[test]
    fn test_files_with_matches_flag() {
        let args: Vec<String> = vec!["-rl".into(), "pattern".into(), "dir/".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.files_only);
        assert_eq!(parsed.pattern, "pattern");
    }

    #[test]
    fn test_empty_args_empty_pattern() {
        let args: Vec<String> = vec![];
        let parsed = parse_grep_args(&args);
        assert!(parsed.pattern.is_empty());
    }

    #[test]
    fn test_invert_match() {
        let args: Vec<String> = vec!["-v".into(), "exclude_this".into()];
        let parsed = parse_grep_args(&args);
        assert!(parsed.invert_match);
        assert_eq!(parsed.pattern, "exclude_this");
    }

    #[test]
    fn test_multiple_e_patterns() {
        let args: Vec<String> = vec![
            "-e".into(),
            "foo".into(),
            "-e".into(),
            "bar".into(),
            "file".into(),
        ];
        let parsed = parse_grep_args(&args);
        assert_eq!(parsed.pattern, "foo|bar");
        assert_eq!(parsed.path, "file");
    }
}

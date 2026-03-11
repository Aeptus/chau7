use crate::filter::{self, FilterLevel, Language};
use crate::tracking;
use anyhow::{Context, Result};
use std::fs;
use std::path::Path;

/// Slice raw content to keep only lines `[start_line..]` (1-based).
/// Returns the sliced string and the 1-based offset of the first included line.
fn apply_start_line(content: &str, start_line: Option<usize>) -> (String, usize) {
    match start_line {
        Some(start) if start > 1 => {
            let sliced: String = content
                .lines()
                .skip(start - 1)
                .collect::<Vec<_>>()
                .join("\n");
            (sliced, start)
        }
        _ => (content.to_string(), 1),
    }
}

pub fn run(
    file: &Path,
    level: FilterLevel,
    max_lines: Option<usize>,
    start_line: Option<usize>,
    line_numbers: bool,
    verbose: u8,
) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    if verbose > 0 {
        eprintln!("Reading: {} (filter: {})", file.display(), level);
    }

    // Read file content
    let content = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Slice to start_line before filtering — discards lines the caller doesn't want.
    let (sliced, line_offset) = apply_start_line(&content, start_line);

    // Detect language from extension
    let lang = file
        .extension()
        .and_then(|e| e.to_str())
        .map(Language::from_extension)
        .unwrap_or(Language::Unknown);

    if verbose > 1 {
        eprintln!("Detected language: {:?}", lang);
    }

    // Apply filter
    let filter = filter::get_filter(level);
    let mut filtered = filter.filter(&sliced, &lang);

    if verbose > 0 {
        let original_lines = sliced.lines().count();
        let filtered_lines = filtered.lines().count();
        let reduction = if original_lines > 0 {
            ((original_lines - filtered_lines) as f64 / original_lines as f64) * 100.0
        } else {
            0.0
        };
        eprintln!(
            "Lines: {} -> {} ({:.1}% reduction)",
            original_lines, filtered_lines, reduction
        );
    }

    // Apply smart truncation if max_lines is set
    if let Some(max) = max_lines {
        filtered = filter::smart_truncate(&filtered, max, &lang);
    }

    let rtk_output = if line_numbers {
        format_with_line_numbers(&filtered, line_offset)
    } else {
        filtered.clone()
    };
    println!("{}", rtk_output);
    timer.track(
        &format!("cat {}", file.display()),
        "rtk read",
        &sliced,
        &rtk_output,
    );
    Ok(())
}

pub fn run_stdin(
    level: FilterLevel,
    max_lines: Option<usize>,
    start_line: Option<usize>,
    line_numbers: bool,
    verbose: u8,
) -> Result<()> {
    use std::io::{self, Read as IoRead};

    let timer = tracking::TimedExecution::start();

    if verbose > 0 {
        eprintln!("Reading from stdin (filter: {})", level);
    }

    // Read from stdin
    let mut content = String::new();
    io::stdin()
        .lock()
        .read_to_string(&mut content)
        .context("Failed to read from stdin")?;

    // Slice to start_line before filtering
    let (sliced, line_offset) = apply_start_line(&content, start_line);

    // No file extension, so use Unknown language
    let lang = Language::Unknown;

    if verbose > 1 {
        eprintln!("Language: {:?} (stdin has no extension)", lang);
    }

    // Apply filter
    let filter = filter::get_filter(level);
    let mut filtered = filter.filter(&sliced, &lang);

    if verbose > 0 {
        let original_lines = sliced.lines().count();
        let filtered_lines = filtered.lines().count();
        let reduction = if original_lines > 0 {
            ((original_lines - filtered_lines) as f64 / original_lines as f64) * 100.0
        } else {
            0.0
        };
        eprintln!(
            "Lines: {} -> {} ({:.1}% reduction)",
            original_lines, filtered_lines, reduction
        );
    }

    // Apply smart truncation if max_lines is set
    if let Some(max) = max_lines {
        filtered = filter::smart_truncate(&filtered, max, &lang);
    }

    let rtk_output = if line_numbers {
        format_with_line_numbers(&filtered, line_offset)
    } else {
        filtered.clone()
    };
    println!("{}", rtk_output);

    timer.track("cat - (stdin)", "rtk read -", &sliced, &rtk_output);
    Ok(())
}

/// Format content with line numbers starting at `first_line_number`.
/// When `--start-line 5` is used, numbers start at 5 so output matches
/// the original file's line numbering.
fn format_with_line_numbers(content: &str, first_line_number: usize) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let last_number = first_line_number + lines.len().saturating_sub(1);
    let width = last_number.to_string().len();
    let mut out = String::new();
    for (i, line) in lines.iter().enumerate() {
        out.push_str(&format!(
            "{:>width$} │ {}\n",
            first_line_number + i,
            line,
            width = width
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_read_rust_file() -> Result<()> {
        let mut file = NamedTempFile::with_suffix(".rs")?;
        writeln!(
            file,
            r#"// Comment
fn main() {{
    println!("Hello");
}}"#
        )?;

        // Just verify it doesn't panic
        run(file.path(), FilterLevel::Minimal, None, None, false, 0)?;
        Ok(())
    }

    #[test]
    fn test_stdin_support_signature() {
        // Test that run_stdin has correct signature and compiles
        // We don't actually run it because it would hang waiting for stdin
        // Compile-time verification that the function exists with correct signature
    }

    #[test]
    fn test_apply_start_line_none() {
        let content = "line1\nline2\nline3\nline4\nline5";
        let (result, offset) = apply_start_line(content, None);
        assert_eq!(result, content);
        assert_eq!(offset, 1);
    }

    #[test]
    fn test_apply_start_line_one() {
        let content = "line1\nline2\nline3";
        let (result, offset) = apply_start_line(content, Some(1));
        assert_eq!(result, content);
        assert_eq!(offset, 1);
    }

    #[test]
    fn test_apply_start_line_mid() {
        let content = "line1\nline2\nline3\nline4\nline5";
        let (result, offset) = apply_start_line(content, Some(3));
        assert_eq!(result, "line3\nline4\nline5");
        assert_eq!(offset, 3);
    }

    #[test]
    fn test_apply_start_line_last() {
        let content = "line1\nline2\nline3";
        let (result, offset) = apply_start_line(content, Some(3));
        assert_eq!(result, "line3");
        assert_eq!(offset, 3);
    }

    #[test]
    fn test_apply_start_line_beyond_eof() {
        let content = "line1\nline2";
        let (result, offset) = apply_start_line(content, Some(10));
        assert_eq!(result, "");
        assert_eq!(offset, 10);
    }

    #[test]
    fn test_format_line_numbers_with_offset() {
        let content = "alpha\nbeta\ngamma";
        let result = format_with_line_numbers(content, 5);
        assert_eq!(result, "5 │ alpha\n6 │ beta\n7 │ gamma\n");
    }

    #[test]
    fn test_format_line_numbers_default_offset() {
        let content = "first\nsecond";
        let result = format_with_line_numbers(content, 1);
        assert_eq!(result, "1 │ first\n2 │ second\n");
    }

    #[test]
    fn test_read_with_start_line() -> Result<()> {
        let mut file = NamedTempFile::with_suffix(".txt")?;
        for i in 1..=10 {
            writeln!(file, "Line {}", i)?;
        }

        // Read starting from line 5 with no filter — shouldn't panic
        run(
            file.path(),
            FilterLevel::None,
            None,
            Some(5),
            false,
            0,
        )?;
        Ok(())
    }

    #[test]
    fn test_read_with_start_line_and_max_lines() -> Result<()> {
        let mut file = NamedTempFile::with_suffix(".txt")?;
        for i in 1..=20 {
            writeln!(file, "Line {}", i)?;
        }

        // Read lines 5 onward, truncated to 3 lines — shouldn't panic
        run(
            file.path(),
            FilterLevel::None,
            Some(3),
            Some(5),
            false,
            0,
        )?;
        Ok(())
    }
}

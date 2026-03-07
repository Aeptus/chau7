use crate::tracking;
use crate::utils::truncate;
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::ffi::OsString;
use std::process::Command;

/// Filter swift build output: strip Compiling/Linking/Write progress lines,
/// keep errors and warnings grouped by file.
fn filter_build(output: &str) -> String {
    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut build_time = String::new();
    let mut target_count = 0u32;

    for line in output.lines() {
        let trimmed = line.trim();

        // Track progress to extract target count
        // Format: [N/M] Compiling ...
        if trimmed.starts_with('[') {
            if let Some(slash) = trimmed.find('/') {
                if let Some(bracket) = trimmed.find(']') {
                    if let Ok(total) = trimmed[slash + 1..bracket].parse::<u32>() {
                        if total > target_count {
                            target_count = total;
                        }
                    }
                }
            }
            continue; // Skip progress lines
        }

        // Build complete line
        if trimmed.starts_with("Build complete!") || trimmed.starts_with("Building for") {
            if trimmed.starts_with("Build complete!") {
                build_time = trimmed.to_string();
            }
            continue;
        }

        // Error/warning lines: path/File.swift:line:col: error: message
        if trimmed.contains(": error:") {
            errors.push(trimmed.to_string());
        } else if trimmed.contains(": warning:") {
            warnings.push(trimmed.to_string());
        } else if trimmed.contains(": note:") {
            // Skip notes (they follow errors/warnings with context)
            continue;
        } else if trimmed.starts_with('|') || trimmed.starts_with('`') {
            // Swift diagnostic caret lines — skip
            continue;
        } else if !trimmed.is_empty() {
            // Other non-empty lines (e.g., error details) — attach to last error
            if !errors.is_empty() {
                errors.push(format!("  {}", trimmed));
            }
        }
    }

    if !errors.is_empty() {
        return format_diagnostics(&errors, &warnings, &build_time, target_count);
    }

    if !warnings.is_empty() {
        let unique_warnings = dedup_diagnostics(&warnings);
        let time_part = extract_time(&build_time);
        return format!(
            "✓ swift build: {} targets{} ({} warnings)\n{}",
            target_count,
            time_part,
            unique_warnings.len(),
            format_grouped_diagnostics(&unique_warnings, 10),
        );
    }

    // Clean build
    let time_part = extract_time(&build_time);
    format!("✓ swift build: {} targets{}", target_count, time_part)
}

/// Filter swift test output: strip per-test started/passed lines,
/// keep failures with their output, show compact summary.
fn filter_test(output: &str) -> String {
    let mut total_tests = 0usize;
    let mut total_failures = 0usize;
    let mut total_time: Option<f64> = None;
    let mut failed_tests: Vec<(String, Vec<String>)> = Vec::new();
    let mut current_failure: Option<(String, Vec<String>)> = None;
    let mut _suites_passed = 0usize;
    let mut _suites_failed = 0usize;
    let mut build_lines_done = false;

    for line in output.lines() {
        let trimmed = line.trim();

        // Skip build progress lines
        if !build_lines_done {
            if trimmed.starts_with('[')
                || trimmed.starts_with("Building for")
                || trimmed.starts_with("Build complete!")
                || trimmed.starts_with("[0/1] Planning build")
            {
                continue;
            }
            if trimmed.starts_with("Test Suite") || trimmed.starts_with("Test Case") {
                build_lines_done = true;
            } else {
                // Check for build errors during test compilation
                if trimmed.contains(": error:") {
                    return format!("swift test: BUILD FAILED\n{}", trimmed);
                }
                continue;
            }
        }

        // Swift Testing framework lines (new format)
        if trimmed.starts_with("◇ ")
            || trimmed.starts_with("↳ ")
            || trimmed.starts_with("✔ ")
            || trimmed.starts_with("✘ ")
        {
            continue;
        }

        // Final summary: "Executed N tests, with N failures ... in X.XXX (Y.YYY) seconds"
        if trimmed.contains("Executed") && trimmed.contains("tests") {
            if let Some(summary) = parse_executed_line(trimmed) {
                total_tests = summary.0;
                total_failures = summary.1;
                total_time = Some(summary.2);
            }
            continue;
        }

        // Test Suite markers
        if trimmed.starts_with("Test Suite '") {
            if trimmed.contains("passed") {
                _suites_passed += 1;
            } else if trimmed.contains("failed") {
                _suites_failed += 1;
            }
            continue;
        }

        // Test Case started — track for potential failure
        if trimmed.starts_with("Test Case '") || trimmed.starts_with("Test Case '-[") {
            // Flush previous failure
            if let Some(failure) = current_failure.take() {
                failed_tests.push(failure);
            }

            if trimmed.contains("' failed") {
                let test_name = extract_test_name(trimmed);
                current_failure = Some((test_name, Vec::new()));
            }
            // Skip passed/started lines
            continue;
        }

        // Collect output lines for current failure
        if let Some((_, ref mut output_lines)) = current_failure {
            if !trimmed.is_empty() {
                output_lines.push(trimmed.to_string());
            }
        }
    }

    // Flush last failure
    if let Some(failure) = current_failure {
        failed_tests.push(failure);
    }

    // Build summary
    if total_tests == 0 {
        return "swift test: 0 tests found".to_string();
    }

    let time_str = total_time
        .map(|t| format!(" ({:.1}s)", t))
        .unwrap_or_default();

    if total_failures == 0 {
        return format!("✓ swift test: {} passed{}", total_tests, time_str);
    }

    let mut result = format!(
        "swift test: {} passed, {} failed{}\n",
        total_tests - total_failures,
        total_failures,
        time_str,
    );
    result.push_str("═══════════════════════════════════════\n");

    for (test_name, output_lines) in &failed_tests {
        result.push_str(&format!("  ❌ {}\n", test_name));
        for line in output_lines.iter().take(5) {
            result.push_str(&format!("     {}\n", truncate(line, 100)));
        }
    }

    result.trim().to_string()
}

/// Parse "Executed N tests, with N failures (N unexpected) in X.XXX (Y.YYY) seconds"
fn parse_executed_line(line: &str) -> Option<(usize, usize, f64)> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    let tests = parts
        .iter()
        .position(|&w| w == "Executed")
        .and_then(|i| parts.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())?;
    let failures = parts
        .iter()
        .position(|&w| w == "with")
        .and_then(|i| parts.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())?;
    let time = parts
        .iter()
        .position(|&w| w == "in")
        .and_then(|i| parts.get(i + 1))
        .and_then(|s| s.parse::<f64>().ok())?;
    Some((tests, failures, time))
}

/// Extract test name from "Test Case '-[Module.Class testMethod]' failed (0.001 seconds)."
fn extract_test_name(line: &str) -> String {
    if let Some(start) = line.find("'-[") {
        if let Some(end) = line[start..].find("]'") {
            return line[start + 3..start + end].to_string();
        }
    }
    if let Some(start) = line.find("'") {
        if let Some(end) = line[start + 1..].find("'") {
            return line[start + 1..start + 1 + end].to_string();
        }
    }
    line.to_string()
}

/// Extract time from "Build complete! (21.12s)"
fn extract_time(build_line: &str) -> String {
    if let Some(paren) = build_line.find('(') {
        if let Some(end) = build_line.find(')') {
            return format!(" ({})", &build_line[paren + 1..end]);
        }
    }
    String::new()
}

/// Deduplicate diagnostics by file:line
fn dedup_diagnostics(diagnostics: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    for diag in diagnostics {
        // Key: file:line:col prefix before ": warning:" or ": error:"
        let key = if let Some(pos) = diag.find(": warning:").or_else(|| diag.find(": error:")) {
            &diag[..pos]
        } else {
            diag.as_str()
        };
        if seen.insert(key.to_string()) {
            result.push(diag.clone());
        }
    }
    result
}

/// Format errors and warnings for display
fn format_diagnostics(
    errors: &[String],
    warnings: &[String],
    _build_time: &str,
    _targets: u32,
) -> String {
    let unique_errors = dedup_diagnostics(errors);
    let unique_warnings = dedup_diagnostics(warnings);

    let mut result = format!(
        "swift build: FAILED ({} errors, {} warnings)\n",
        unique_errors.len(),
        unique_warnings.len(),
    );
    result.push_str("═══════════════════════════════════════\n");
    result.push_str(&format_grouped_diagnostics(&unique_errors, 20));

    if !unique_warnings.is_empty() && unique_errors.len() < 5 {
        result.push_str(&format!("\n({} warnings omitted)\n", unique_warnings.len()));
    }

    result.trim().to_string()
}

/// Group diagnostics by file and format compactly
fn format_grouped_diagnostics(diagnostics: &[String], limit: usize) -> String {
    let mut by_file: HashMap<String, Vec<String>> = HashMap::new();

    for diag in diagnostics.iter().take(limit) {
        let (file, message) = split_diagnostic(diag);
        by_file.entry(file).or_default().push(message);
    }

    let mut files: Vec<_> = by_file.keys().cloned().collect();
    files.sort();

    let mut result = String::new();
    for file in &files {
        let messages = &by_file[file];
        let short_file = shorten_path(file);
        result.push_str(&format!("  {} ({})\n", short_file, messages.len()));
        for msg in messages.iter().take(3) {
            result.push_str(&format!("    {}\n", truncate(msg, 90)));
        }
        if messages.len() > 3 {
            result.push_str(&format!("    +{} more\n", messages.len() - 3));
        }
    }

    if diagnostics.len() > limit {
        result.push_str(&format!(
            "  +{} more diagnostics\n",
            diagnostics.len() - limit
        ));
    }

    result
}

/// Split "path/File.swift:42:10: warning: some message" into (file, message)
fn split_diagnostic(diag: &str) -> (String, String) {
    // Find ": warning:" or ": error:"
    if let Some(pos) = diag.find(": warning:") {
        let file = &diag[..pos];
        let msg = diag[pos + 10..].trim();
        // Further split file into path and line:col
        if let Some(first_colon) = file.find(".swift:") {
            let path = &file[..first_colon + 6]; // include .swift
            return (path.to_string(), msg.to_string());
        }
        return (file.to_string(), msg.to_string());
    }
    if let Some(pos) = diag.find(": error:") {
        let file = &diag[..pos];
        let msg = diag[pos + 8..].trim();
        if let Some(first_colon) = file.find(".swift:") {
            let path = &file[..first_colon + 6];
            return (path.to_string(), msg.to_string());
        }
        return (file.to_string(), msg.to_string());
    }
    (String::new(), diag.to_string())
}

/// Shorten a path for display: strip common prefixes, keep last 2 components
fn shorten_path(path: &str) -> String {
    // Find Sources/ or Tests/ and show from there
    for marker in &["/Sources/", "/Tests/", "/src/"] {
        if let Some(pos) = path.find(marker) {
            return path[pos + 1..].to_string();
        }
    }
    // Fallback: last 2 path components
    let parts: Vec<&str> = path.rsplit('/').take(3).collect();
    parts.into_iter().rev().collect::<Vec<_>>().join("/")
}

pub fn run_build(args: &[String], verbose: u8) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = Command::new("swift");
    cmd.arg("build");
    for arg in args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: swift build {}", args.join(" "));
    }

    let output = cmd.output().context("Failed to run swift build")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    // Swift emits progress to stdout, errors/warnings to stderr
    let combined = format!("{}\n{}", stdout, stderr);

    let exit_code = output
        .status
        .code()
        .unwrap_or(if output.status.success() { 0 } else { 1 });
    let filtered = filter_build(&combined);

    if let Some(hint) = crate::tee::tee_and_hint(&combined, "swift_build", exit_code) {
        println!("{}\n{}", filtered, hint);
    } else {
        println!("{}", filtered);
    }

    timer.track(
        &format!("swift build {}", args.join(" ")),
        &format!("rtk swift build {}", args.join(" ")),
        &combined,
        &filtered,
    );

    if !output.status.success() {
        std::process::exit(exit_code);
    }

    Ok(())
}

pub fn run_test(args: &[String], verbose: u8) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = Command::new("swift");
    cmd.arg("test");
    for arg in args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: swift test {}", args.join(" "));
    }

    let output = cmd.output().context("Failed to run swift test")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{}\n{}", stdout, stderr);

    let exit_code = output
        .status
        .code()
        .unwrap_or(if output.status.success() { 0 } else { 1 });
    let filtered = filter_test(&combined);

    if let Some(hint) = crate::tee::tee_and_hint(&combined, "swift_test", exit_code) {
        println!("{}\n{}", filtered, hint);
    } else {
        println!("{}", filtered);
    }

    timer.track(
        &format!("swift test {}", args.join(" ")),
        &format!("rtk swift test {}", args.join(" ")),
        &combined,
        &filtered,
    );

    if !output.status.success() {
        std::process::exit(exit_code);
    }

    Ok(())
}

pub fn run_other(args: &[OsString], verbose: u8) -> Result<()> {
    if args.is_empty() {
        anyhow::bail!("swift: no subcommand specified");
    }

    let timer = tracking::TimedExecution::start();

    let subcommand = args[0].to_string_lossy();
    let mut cmd = Command::new("swift");
    for arg in args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: swift {} ...", subcommand);
    }

    let output = cmd
        .output()
        .with_context(|| format!("Failed to run swift {}", subcommand))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    print!("{}", stdout);
    eprint!("{}", stderr);

    let raw = format!("{}\n{}", stdout, stderr);
    timer.track(
        &format!("swift {}", subcommand),
        &format!("rtk swift {}", subcommand),
        &raw,
        &raw,
    );

    if !output.status.success() {
        std::process::exit(output.status.code().unwrap_or(1));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_build_clean() {
        let output = r#"Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
[1/50] Compiling Foo Bar.swift
[2/50] Compiling Foo Baz.swift
[49/50] Linking MyApp
Build complete! (3.45s)"#;

        let result = filter_build(output);
        assert!(result.contains("✓ swift build"));
        assert!(result.contains("50 targets"));
        assert!(result.contains("3.45s"));
        assert!(!result.contains("Compiling"));
    }

    #[test]
    fn test_filter_build_with_warnings() {
        let output = r#"Building for debugging...
[1/10] Compiling Foo Bar.swift
/path/Sources/Foo/Bar.swift:42:10: warning: unused variable 'x'
[2/10] Compiling Foo Baz.swift
/path/Sources/Foo/Baz.swift:10:5: warning: result unused
Build complete! (1.23s)"#;

        let result = filter_build(output);
        assert!(result.contains("2 warnings"));
        assert!(result.contains("10 targets"));
        assert!(!result.contains("Compiling"));
    }

    #[test]
    fn test_filter_build_with_errors() {
        let output = r#"Building for debugging...
[1/10] Compiling Foo Bar.swift
/path/Sources/Foo/Bar.swift:42:10: error: cannot convert 'Int' to 'String'
Build complete!"#;

        let result = filter_build(output);
        assert!(result.contains("FAILED"));
        assert!(result.contains("1 errors"));
        assert!(result.contains("cannot convert"));
    }

    #[test]
    fn test_filter_build_no_progress() {
        let output = "Build complete! (0.18s)";
        let result = filter_build(output);
        assert!(result.contains("✓ swift build"));
        assert!(result.contains("0.18s"));
    }

    #[test]
    fn test_filter_test_all_pass() {
        let output = r#"Building for debugging...
[1/5] Compiling Tests FooTests.swift
Build complete! (2.1s)
Test Suite 'All tests' started at 2026-01-01.
Test Suite 'FooTests' started at 2026-01-01.
Test Case '-[Tests.FooTests testBar]' started.
Test Case '-[Tests.FooTests testBar]' passed (0.001 seconds).
Test Case '-[Tests.FooTests testBaz]' started.
Test Case '-[Tests.FooTests testBaz]' passed (0.002 seconds).
Test Suite 'FooTests' passed at 2026-01-01.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
Test Suite 'All tests' passed at 2026-01-01.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds"#;

        let result = filter_test(output);
        assert!(result.contains("✓ swift test"));
        assert!(result.contains("2 passed"));
        assert!(!result.contains("testBar"));
    }

    #[test]
    fn test_filter_test_with_failure() {
        let output = r#"Test Suite 'All tests' started.
Test Suite 'FooTests' started.
Test Case '-[Tests.FooTests testGood]' started.
Test Case '-[Tests.FooTests testGood]' passed (0.001 seconds).
Test Case '-[Tests.FooTests testBad]' started.
/path/Tests/FooTests.swift:42: error: -[Tests.FooTests testBad] : XCTAssertEqual failed: ("1") is not equal to ("2")
Test Case '-[Tests.FooTests testBad]' failed (0.003 seconds).
Test Suite 'FooTests' failed.
	 Executed 2 tests, with 1 failures (1 unexpected) in 0.004 (0.005) seconds
Test Suite 'All tests' failed.
	 Executed 2 tests, with 1 failures (1 unexpected) in 0.004 (0.005) seconds"#;

        let result = filter_test(output);
        assert!(result.contains("1 passed"));
        assert!(result.contains("1 failed"));
        assert!(result.contains("testBad"));
    }

    #[test]
    fn test_filter_test_zero_tests() {
        let output = r#"Building for debugging...
Build complete! (0.5s)
Test Suite 'Selected tests' started.
Test Suite 'Selected tests' passed.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds"#;

        let result = filter_test(output);
        assert!(result.contains("0 tests found"));
    }

    #[test]
    fn test_extract_test_name() {
        assert_eq!(
            extract_test_name("Test Case '-[Tests.FooTests testBar]' failed (0.001 seconds)."),
            "Tests.FooTests testBar"
        );
    }

    #[test]
    fn test_parse_executed_line() {
        let line = "Executed 775 tests, with 0 failures (0 unexpected) in 16.965 (16.998) seconds";
        let result = parse_executed_line(line);
        assert!(result.is_some());
        let (tests, failures, time) = result.unwrap();
        assert_eq!(tests, 775);
        assert_eq!(failures, 0);
        assert!((time - 16.965).abs() < 0.001);
    }

    #[test]
    fn test_shorten_path() {
        assert_eq!(
            shorten_path("/Users/foo/project/Sources/MyApp/Bar.swift"),
            "Sources/MyApp/Bar.swift"
        );
        assert_eq!(
            shorten_path("/Users/foo/project/Tests/MyTests/FooTest.swift"),
            "Tests/MyTests/FooTest.swift"
        );
    }

    #[test]
    fn test_split_diagnostic() {
        let (file, msg) =
            split_diagnostic("/path/Sources/Foo/Bar.swift:42:10: warning: unused variable 'x'");
        assert_eq!(file, "/path/Sources/Foo/Bar.swift");
        assert_eq!(msg, "unused variable 'x'");
    }

    #[test]
    fn test_dedup_diagnostics() {
        let diags = vec![
            "/path/Foo.swift:10:5: warning: unused var".to_string(),
            "/path/Foo.swift:10:5: warning: unused var".to_string(),
            "/path/Bar.swift:20:3: warning: other thing".to_string(),
        ];
        let deduped = dedup_diagnostics(&diags);
        assert_eq!(deduped.len(), 2);
    }
}

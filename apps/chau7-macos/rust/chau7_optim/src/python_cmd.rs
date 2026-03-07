use crate::{pytest_cmd, tracking};
use anyhow::{Context, Result};
use std::process::Command;

/// Run `python3 -m <module> <args>` with optimization for supported modules.
/// For pytest: adds compact flags and filters output.
/// For ruff/pip: runs directly and tracks usage.
pub fn run_module(module: &str, args: &[String], verbose: u8) -> Result<()> {
    match module {
        "pytest" => run_pytest(args, verbose),
        "ruff" | "pip" => run_passthrough(module, args, verbose),
        _ => {
            // Unknown module — intentional skip
            std::process::exit(3);
        }
    }
}

/// Run `python3 manage.py test <args>` — Django test runner with pytest-style filtering.
pub fn run_manage_test(args: &[String], verbose: u8) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    // args[0] = "manage.py", args[1] = "test", args[2..] = test args
    let mut cmd = Command::new("python3");
    for arg in args {
        cmd.arg(arg);
    }
    cmd.arg("--verbosity=2");

    if verbose > 0 {
        eprintln!("Running: python3 {}", args.join(" "));
    }

    let output = cmd
        .output()
        .context("Failed to run python3 manage.py test")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let raw = format!("{}\n{}", stdout, stderr);
    let combined = format!("{}\n{}", stdout, stderr);

    let filtered = filter_django_test_output(&combined);

    let exit_code = output
        .status
        .code()
        .unwrap_or(if output.status.success() { 0 } else { 1 });
    if let Some(hint) = crate::tee::tee_and_hint(&raw, "python-manage-test", exit_code) {
        println!("{}\n{}", filtered, hint);
    } else {
        println!("{}", filtered);
    }

    timer.track(
        &format!("python3 {}", args.join(" ")),
        "cto python manage.py test",
        &raw,
        &filtered,
    );

    if !output.status.success() {
        std::process::exit(exit_code);
    }

    Ok(())
}

fn run_pytest(args: &[String], verbose: u8) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = Command::new("python3");
    cmd.arg("-m").arg("pytest");

    // Add compact flags if not already specified
    let has_tb_flag = args.iter().any(|a| a.starts_with("--tb"));
    let has_quiet_flag = args.iter().any(|a| a == "-q" || a == "--quiet");
    if !has_tb_flag {
        cmd.arg("--tb=short");
    }
    if !has_quiet_flag {
        cmd.arg("-q");
    }

    for arg in args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: python3 -m pytest {}", args.join(" "));
    }

    let output = cmd
        .output()
        .context("Failed to run python3 -m pytest. Is pytest installed?")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let raw = format!("{}\n{}", stdout, stderr);

    let filtered = pytest_cmd::filter_pytest_output(&stdout);

    let exit_code = output
        .status
        .code()
        .unwrap_or(if output.status.success() { 0 } else { 1 });
    if let Some(hint) = crate::tee::tee_and_hint(&raw, "python-pytest", exit_code) {
        println!("{}\n{}", filtered, hint);
    } else {
        println!("{}", filtered);
    }

    if !stderr.trim().is_empty() {
        eprintln!("{}", stderr.trim());
    }

    timer.track(
        &format!("python3 -m pytest {}", args.join(" ")),
        "cto python -m pytest",
        &raw,
        &filtered,
    );

    if !output.status.success() {
        std::process::exit(exit_code);
    }

    Ok(())
}

fn run_passthrough(module: &str, args: &[String], verbose: u8) -> Result<()> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = Command::new("python3");
    cmd.arg("-m").arg(module);
    for arg in args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: python3 -m {} {}", module, args.join(" "));
    }

    let status = cmd
        .status()
        .with_context(|| format!("Failed to run python3 -m {}", module))?;

    let args_str = args.join(" ");
    timer.track_passthrough(
        &format!("python3 -m {} {}", module, args_str),
        &format!("cto python -m {} (passthrough)", module),
    );

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }

    Ok(())
}

/// Filter Django test output (manage.py test --verbosity=2).
/// Django uses unittest format: "test_name (module.Class) ... ok/FAIL"
fn filter_django_test_output(output: &str) -> String {
    let mut failures: Vec<String> = Vec::new();
    let mut current_failure: Vec<String> = Vec::new();
    let mut in_failure = false;
    let mut total_tests = 0;
    let mut failed_count = 0;
    let mut passed_count = 0;
    let mut error_count = 0;

    for line in output.lines() {
        let trimmed = line.trim();

        // Summary line: "Ran N tests in Xs"
        if trimmed.starts_with("Ran ") && trimmed.contains(" tests in ") {
            if let Some(n) = trimmed
                .strip_prefix("Ran ")
                .and_then(|s| s.split_whitespace().next())
                .and_then(|s| s.parse::<usize>().ok())
            {
                total_tests = n;
            }
            continue;
        }

        // Result line: "OK" or "FAILED (failures=N, errors=N)"
        if trimmed == "OK" || trimmed.starts_with("OK (") {
            passed_count = total_tests;
            continue;
        }
        if trimmed.starts_with("FAILED") {
            // Parse "FAILED (failures=2, errors=1)"
            if let Some(inner) = trimmed
                .strip_prefix("FAILED (")
                .and_then(|s| s.strip_suffix(')'))
            {
                for part in inner.split(',') {
                    let part = part.trim();
                    if let Some(n) = part
                        .strip_prefix("failures=")
                        .and_then(|s| s.parse::<usize>().ok())
                    {
                        failed_count = n;
                    }
                    if let Some(n) = part
                        .strip_prefix("errors=")
                        .and_then(|s| s.parse::<usize>().ok())
                    {
                        error_count = n;
                    }
                }
                passed_count = total_tests.saturating_sub(failed_count + error_count);
            }
            continue;
        }

        // Failure/error section starts with a line of just "======"
        if trimmed.starts_with("======") && trimmed.chars().all(|c| c == '=') {
            in_failure = true;
            if !current_failure.is_empty() {
                failures.push(current_failure.join("\n"));
                current_failure.clear();
            }
            continue;
        }

        // Separator within failures (line of just "------")
        if trimmed.starts_with("------") && trimmed.chars().all(|c| c == '-') {
            if !current_failure.is_empty() {
                failures.push(current_failure.join("\n"));
                current_failure.clear();
            }
            // Also ends the failure section when it follows the traceback
            // (before "Ran N tests...")
            continue;
        }

        if in_failure && !trimmed.is_empty() {
            current_failure.push(trimmed.to_string());
        }
    }

    if !current_failure.is_empty() {
        failures.push(current_failure.join("\n"));
    }

    // Build output
    if failed_count == 0 && error_count == 0 && total_tests > 0 {
        return format!("✓ Django: {} passed", total_tests);
    }

    if total_tests == 0 {
        return "Django: No tests ran".to_string();
    }

    let mut result = format!("Django: {} passed, {} failed", passed_count, failed_count);
    if error_count > 0 {
        result.push_str(&format!(", {} errors", error_count));
    }

    if !failures.is_empty() {
        result.push_str("\n═══════════════════════════════════════\n");
        for (i, failure) in failures.iter().take(5).enumerate() {
            result.push_str(&format!("{}. {}\n", i + 1, failure));
        }
        if failures.len() > 5 {
            result.push_str(&format!("... +{} more\n", failures.len() - 5));
        }
    }

    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_django_all_pass() {
        let output = r#"test_create_user (accounts.tests.UserTests) ... ok
test_login (accounts.tests.UserTests) ... ok
test_logout (accounts.tests.UserTests) ... ok

----------------------------------------------------------------------
Ran 3 tests in 0.45s

OK"#;
        let result = filter_django_test_output(output);
        assert!(result.contains("✓ Django"), "got: {}", result);
        assert!(result.contains("3 passed"));
    }

    #[test]
    fn test_filter_django_with_failures() {
        let output = r#"test_create_user (accounts.tests.UserTests) ... ok
test_login (accounts.tests.UserTests) ... FAIL

======================================================================
FAIL: test_login (accounts.tests.UserTests)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "tests.py", line 15, in test_login
    self.assertEqual(response.status_code, 200)
AssertionError: 403 != 200

----------------------------------------------------------------------
Ran 2 tests in 0.30s

FAILED (failures=1)"#;
        let result = filter_django_test_output(output);
        assert!(result.contains("1 passed, 1 failed"), "got: {}", result);
        assert!(result.contains("test_login"));
    }

    #[test]
    fn test_filter_django_no_tests() {
        let output = "----------------------------------------------------------------------\nRan 0 tests in 0.00s\n\nOK";
        let result = filter_django_test_output(output);
        assert!(result.contains("No tests ran"), "got: {}", result);
    }
}

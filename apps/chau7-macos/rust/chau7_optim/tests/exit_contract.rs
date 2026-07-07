//! Guards the CTO wrapper's exit-code contract (audit Finding 3).
//!
//! The generated wrapper treats exit codes 2 (clap parse) and 3 (intentional
//! skip) as "fall through to the real binary"; every other code is taken as
//! "optimized successfully" and the real command is NOT run. So an *internal*
//! optimizer failure must surface as exit 3 (fall through), never as a code the
//! wrapper would mistake for a successful optimization and then suppress the
//! real command. Conversely, a handler's *deliberate* exit code that follows
//! real output (e.g. grep no-match = 1) must be preserved, not remapped.
//!
//! These spawn the built binary; Cargo provides its path via CARGO_BIN_EXE_*.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;

fn optim() -> &'static str {
    env!("CARGO_BIN_EXE_chau7-optim")
}

/// Writes `contents` to a uniquely named temp file and returns its path.
/// Avoids a tempfile dev-dependency; caller need not clean up (temp dir).
fn temp_file(tag: &str, contents: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "chau7_optim_exit_contract_{}_{}.txt",
        tag,
        std::process::id()
    ));
    let mut f = fs::File::create(&path).expect("create temp file");
    f.write_all(contents.as_bytes()).expect("write temp file");
    path
}

fn run(args: &[&str]) -> Option<i32> {
    Command::new(optim())
        .args(args)
        .output()
        .expect("spawn chau7-optim")
        .status
        .code()
}

#[test]
fn internal_error_falls_through_with_exit_3() {
    // `read` on a missing file returns Err → main() must map it to exit 3 so
    // the wrapper re-execs the real binary, NOT exit 1 (which would suppress).
    let code = run(&["read", "/chau7/definitely/not/a/real/path.txt"]);
    assert_eq!(
        code,
        Some(3),
        "internal error must fall through (exit 3), got {code:?}"
    );
}

#[test]
fn successful_optimization_exits_zero() {
    let file = temp_file("ok", "hello\nworld\n");
    let code = run(&["read", file.to_str().unwrap()]);
    assert_eq!(code, Some(0), "a clean read must report success (0)");
}

#[test]
fn passthrough_python_invocation_skips_with_exit_3() {
    // `python --version` isn't a form the optimizer handles → intentional skip.
    let code = run(&["python", "--version"]);
    assert_eq!(code, Some(3), "unhandled python invocation must skip (exit 3)");
}

#[test]
fn deliberate_grep_no_match_code_is_preserved() {
    // grep no-match is a *deliberate* exit 1 after real output — it must NOT be
    // remapped to the fall-through code, or the wrapper would double-run grep.
    let file = temp_file("grep", "alpha\nbeta\n");
    let code = run(&["grep", "zzz_no_such_token", file.to_str().unwrap()]);
    assert_eq!(
        code,
        Some(1),
        "deliberate grep no-match (1) must be preserved, got {code:?}"
    );
}

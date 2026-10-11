//! Port of `SubprocessRunner.swift`: run a subprocess and return its stdout.
//!
//! The child is always waited on (which reaps it), so no zombie is left behind
//! on background threads. Stderr is discarded, as in Swift.

use std::io::Read;
use std::process::{Command, Stdio};

/// Runs a subprocess and returns stdout as UTF-8 text (invalid bytes are
/// replaced). Returns `None` if the process cannot be started.
pub fn run(executable_path: &str, arguments: &[&str]) -> Option<String> {
    let mut child = Command::new(executable_path)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let mut data = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_end(&mut data);
    }
    let _ = child.wait();

    Some(String::from_utf8_lossy(&data).into_owned())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn run_captures_stdout() {
        let output = run("/bin/echo", &["chau7"]);
        assert_eq!(output.as_deref(), Some("chau7\n"));
    }

    #[test]
    fn run_returns_none_for_missing_executable() {
        assert_eq!(run("/path/that/does/not/exist", &[]), None);
    }
}

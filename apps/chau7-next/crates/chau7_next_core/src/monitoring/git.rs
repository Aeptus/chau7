//! Git helpers of `Monitoring/GitDiffTracker.swift` (`runGit`, `diffStat`):
//! git runs with `GIT_TERMINAL_PROMPT=0` and is killed after 5 s.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Kill delay (`runGit`: large repos).
pub const GIT_TIMEOUT: Duration = Duration::from_secs(5);

/// `git -C <directory> <args>`: trimmed stdout, or "" on failure, non-zero
/// exit or timeout.
pub fn run_git(args: &[&str], directory: &str) -> String {
    run_git_raw(args, directory).trim().to_string()
}

/// [`run_git`] without trimming (porcelain output keeps its leading spaces).
pub fn run_git_raw(args: &[&str], directory: &str) -> String {
    let child = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return String::new();
    };
    // Read on a thread so a full pipe never blocks the timeout.
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut data = Vec::new();
        if let Some(out) = stdout.as_mut() {
            let _ = out.read_to_end(&mut data);
        }
        data
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() >= GIT_TIMEOUT => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => break None,
        }
    };
    let data = reader.join().unwrap_or_default();
    match status {
        Some(s) if s.success() => String::from_utf8_lossy(&data).into_owned(),
        _ => String::new(),
    }
}

/// Last line of `git diff --stat` mentioning "changed" (the summary).
pub fn stat_summary(output: &str) -> Option<String> {
    output
        .lines()
        .rev()
        .find(|l| l.contains("changed"))
        .map(|l| l.trim().to_string())
}

/// `diffStat(file:in:)`: "1 file changed, 3 insertions(+), 1 deletion(-)"
/// for the working tree, else the staged diff, else "".
pub fn diff_stat(file: &str, directory: &str) -> String {
    if let Some(summary) = stat_summary(&run_git(&["diff", "--stat", "--", file], directory)) {
        return summary;
    }
    stat_summary(&run_git(
        &["diff", "--cached", "--stat", "--", file],
        directory,
    ))
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_line() {
        let out = " src/a.rs | 4 +++-\n 1 file changed, 3 insertions(+), 1 deletion(-)";
        assert_eq!(
            stat_summary(out).as_deref(),
            Some("1 file changed, 3 insertions(+), 1 deletion(-)")
        );
        assert_eq!(stat_summary(""), None);
    }

    #[test]
    fn git_outside_a_repo_is_empty() {
        let dir = std::env::temp_dir().join(format!("chau7-next-nogit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(
            run_git(&["status", "--porcelain"], &dir.to_string_lossy()),
            ""
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

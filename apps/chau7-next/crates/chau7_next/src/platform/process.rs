//! Process information from the OS (libproc on macOS, `/proc` on Linux):
//! working directory, child processes, CPU time and memory, plus git
//! information for a shell's directory.
//!
//! The Swift app learns the directory from shell integration (OSC 7). Chau7
//! Next asks the OS for the shell's current directory instead, so it works
//! without installing any shell hooks.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// Current working directory of a process, when the OS exposes it.
pub fn process_cwd(pid: u32) -> Option<PathBuf> {
    if pid == 0 {
        return None;
    }
    platform_cwd(pid)
}

#[cfg(target_os = "linux")]
fn platform_cwd(pid: u32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

#[cfg(target_os = "macos")]
fn platform_cwd(pid: u32) -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::mem::{MaybeUninit, size_of};

    let mut info = MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
    let size = size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info`.
    let written = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if written != size {
        return None;
    }
    // SAFETY: fully initialized by the successful call above.
    let info = unsafe { info.assume_init() };
    let path = info.pvi_cdir.vip_path;
    // SAFETY: vip_path is a NUL-terminated C string inside a fixed buffer.
    let cstr = unsafe { CStr::from_ptr(path.as_ptr().cast()) };
    let text = cstr.to_str().ok()?;
    (!text.is_empty()).then(|| PathBuf::from(text))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_cwd(_pid: u32) -> Option<PathBuf> {
    None
}

/// Number of direct child processes of `pid` (the shell's running jobs).
/// Mirrors `countRunningProcesses` in the Swift app, used to warn before
/// closing a tab that still runs something.
pub fn child_process_count(pid: u32) -> usize {
    if pid == 0 {
        return 0;
    }
    platform_child_count(pid)
}

#[cfg(target_os = "linux")]
fn platform_child_count(pid: u32) -> usize {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()))
        .filter(|child| {
            std::fs::read_to_string(format!("/proc/{child}/stat"))
                .ok()
                .and_then(|stat| {
                    // Field 4 (ppid) follows the ")" that closes the command name.
                    let rest = &stat[stat.rfind(')')? + 1..];
                    rest.split_whitespace().nth(1)?.parse::<u32>().ok()
                })
                == Some(pid)
        })
        .count()
}

#[cfg(target_os = "macos")]
fn platform_child_count(pid: u32) -> usize {
    let mut pids = vec![0 as libc::pid_t; 256];
    let size = (pids.len() * std::mem::size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: the buffer holds `size` bytes; the call writes at most that.
    let n = unsafe { libc::proc_listchildpids(pid as libc::pid_t, pids.as_mut_ptr().cast(), size) };
    if n <= 0 { 0 } else { n as usize }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_child_count(_pid: u32) -> usize {
    0
}

/// Direct child processes of `pid`.
pub fn child_pids(pid: u32) -> Vec<u32> {
    if pid == 0 {
        return Vec::new();
    }
    platform_child_pids(pid)
}

#[cfg(target_os = "linux")]
fn platform_child_pids(pid: u32) -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()))
        .filter(|child| {
            std::fs::read_to_string(format!("/proc/{child}/stat"))
                .ok()
                .and_then(|stat| parse_linux_stat(&stat))
                .is_some_and(|stat| stat.ppid == pid)
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn platform_child_pids(pid: u32) -> Vec<u32> {
    let mut pids = vec![0 as libc::pid_t; 256];
    let size = (pids.len() * std::mem::size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: the buffer holds `size` bytes; the call writes at most that.
    let n = unsafe { libc::proc_listchildpids(pid as libc::pid_t, pids.as_mut_ptr().cast(), size) };
    if n <= 0 {
        return Vec::new();
    }
    // proc_listchildpids returns a number of pids, like `child_process_count`.
    pids.truncate((n as usize).min(pids.len()));
    pids.into_iter()
        .filter(|&p| p > 0)
        .map(|p| p as u32)
        .collect()
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_child_pids(_pid: u32) -> Vec<u32> {
    super::log_unsupported_once("process list");
    Vec::new()
}

/// Arguments and environment of a process of the same user (profile
/// auto-switch SSH host and environment triggers). The environment is the
/// one the process started with.
pub fn process_args_env(pid: u32) -> Option<chau7_next_core::procargs::ArgsEnv> {
    if pid == 0 {
        return None;
    }
    platform_args_env(pid)
}

#[cfg(target_os = "linux")]
fn platform_args_env(pid: u32) -> Option<chau7_next_core::procargs::ArgsEnv> {
    use chau7_next_core::procargs::{parse_environ, split_nul};
    let args = split_nul(&std::fs::read(format!("/proc/{pid}/cmdline")).ok()?);
    let env = std::fs::read(format!("/proc/{pid}/environ"))
        .map(|b| parse_environ(&b))
        .unwrap_or_default();
    Some((args, env))
}

#[cfg(target_os = "macos")]
fn platform_args_env(pid: u32) -> Option<chau7_next_core::procargs::ArgsEnv> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as libc::c_int];
    let mut size: libc::size_t = 0;
    // SAFETY: a size query (null buffer) for a valid MIB.
    let ok = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok != 0 || size == 0 {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: the buffer holds `size` bytes; sysctl writes at most that and
    // updates `size`.
    let ok = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok != 0 {
        return None;
    }
    buf.truncate(size);
    chau7_next_core::procargs::parse_procargs2(&buf)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_args_env(_pid: u32) -> Option<chau7_next_core::procargs::ArgsEnv> {
    super::log_unsupported_once("process arguments");
    None
}

/// Executable name of a process (`ProcessInfo.name` of a child in Swift).
pub fn process_name(pid: u32) -> Option<String> {
    if pid == 0 {
        return None;
    }
    platform_name(pid).filter(|n| !n.is_empty())
}

#[cfg(target_os = "linux")]
fn platform_name(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .ok()
        .map(|n| n.trim().to_string())
}

#[cfg(target_os = "macos")]
fn platform_name(pid: u32) -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: proc_name writes at most `buffer.len()` bytes, NUL terminated.
    let n = unsafe {
        libc::proc_name(
            pid as libc::c_int,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
        )
    };
    if n <= 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buffer[..n as usize]).into_owned())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_name(_pid: u32) -> Option<String> {
    None
}

/// `pid` and all its descendants, parents before children (the shell and
/// the jobs it runs, for the process group CPU and memory of a tab).
pub fn process_tree(pid: u32) -> Vec<u32> {
    let mut tree = Vec::new();
    if pid == 0 {
        return tree;
    }
    let mut pending = vec![pid];
    // Bounded, in case the process table changes while it is walked.
    while let Some(next) = pending.pop() {
        if tree.contains(&next) || tree.len() >= 4096 {
            continue;
        }
        tree.push(next);
        pending.extend(child_pids(next));
    }
    tree
}

/// The first of `pids` listening on a TCP port: (pid, port)
/// (`DevServerMonitor.findListeningServer`). macOS runs
/// `netstat -anv -p tcp` (fast, unlike `lsof`); Linux reads `/proc/net/tcp`
/// and each process's socket inodes.
pub fn listening_port(pids: &[u32]) -> Option<(u32, u16)> {
    if pids.is_empty() {
        return None;
    }
    platform_listening_port(pids)
}

#[cfg(target_os = "macos")]
fn platform_listening_port(pids: &[u32]) -> Option<(u32, u16)> {
    let output = chau7_next_core::subprocess::run("/usr/sbin/netstat", &["-anv", "-p", "tcp"])?;
    chau7_next_core::monitoring::dev_server::listening_from_netstat(&output, pids)
}

#[cfg(target_os = "linux")]
fn platform_listening_port(pids: &[u32]) -> Option<(u32, u16)> {
    use chau7_next_core::monitoring::dev_server::{listening_from_proc_net_tcp, socket_inode};
    let mut listening = Vec::new();
    for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(text) = std::fs::read_to_string(file) {
            listening.extend(listening_from_proc_net_tcp(&text));
        }
    }
    if listening.is_empty() {
        return None;
    }
    for &pid in pids {
        let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            let Some(inode) = std::fs::read_link(fd.path())
                .ok()
                .and_then(|l| socket_inode(&l.to_string_lossy()))
            else {
                continue;
            };
            if let Some((_, port)) = listening.iter().find(|(i, _)| *i == inode) {
                return Some((pid, *port));
            }
        }
    }
    None
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_listening_port(_pids: &[u32]) -> Option<(u32, u16)> {
    None
}

/// CPU time used so far and memory in use by one process.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProcessUsage {
    /// User plus system CPU time since the process started. Sample twice and
    /// divide the difference by the wall time for a CPU percentage.
    pub cpu_time: Duration,
    /// Resident memory in bytes.
    pub resident_bytes: u64,
}

impl std::ops::Add for ProcessUsage {
    type Output = Self;

    fn add(self, other: Self) -> Self {
        Self {
            cpu_time: self.cpu_time + other.cpu_time,
            resident_bytes: self.resident_bytes + other.resident_bytes,
        }
    }
}

/// CPU time and memory of one process, when the OS exposes them.
pub fn process_usage(pid: u32) -> Option<ProcessUsage> {
    if pid == 0 {
        return None;
    }
    platform_usage(pid)
}

/// Sum of [`process_usage`] over `pid` and its descendants.
pub fn tree_usage(pid: u32) -> Option<ProcessUsage> {
    let mut total: Option<ProcessUsage> = None;
    for p in process_tree(pid) {
        if let Some(usage) = process_usage(p) {
            total = Some(total.unwrap_or_default() + usage);
        }
    }
    total
}

/// Memory used by Chau7 Next itself (memory threshold event, performance
/// logs), in bytes.
pub fn own_resident_bytes() -> Option<u64> {
    process_usage(std::process::id()).map(|u| u.resident_bytes)
}

/// Fields of `/proc/<pid>/stat` used here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LinuxStat {
    ppid: u32,
    /// utime + stime, in clock ticks.
    cpu_ticks: u64,
    /// Resident pages.
    rss_pages: u64,
}

/// Parses `/proc/<pid>/stat`. The command name (field 2) may contain spaces
/// and parentheses, so fields are counted from the last `)`.
fn parse_linux_stat(stat: &str) -> Option<LinuxStat> {
    let rest = &stat[stat.rfind(')')? + 1..];
    // `rest` starts at field 3 (state); ppid is field 4, utime 14, stime 15,
    // rss 24.
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let field = |n: usize| fields.get(n - 3).and_then(|f| f.parse::<u64>().ok());
    Some(LinuxStat {
        ppid: u32::try_from(field(4)?).ok()?,
        cpu_ticks: field(14)? + field(15)?,
        rss_pages: field(24)?,
    })
}

#[cfg(target_os = "linux")]
fn platform_usage(pid: u32) -> Option<ProcessUsage> {
    // USER_HZ and the page size are 100 and 4 KiB on the Linux targets
    // Chau7 Next builds for (x86_64, aarch64 with 4K pages).
    const TICKS_PER_SECOND: u64 = 100;
    const PAGE_SIZE: u64 = 4096;
    let stat = parse_linux_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)?;
    Some(ProcessUsage {
        cpu_time: Duration::from_millis(stat.cpu_ticks * 1000 / TICKS_PER_SECOND),
        resident_bytes: stat.rss_pages * PAGE_SIZE,
    })
}

#[cfg(target_os = "macos")]
fn platform_usage(pid: u32) -> Option<ProcessUsage> {
    use std::mem::{MaybeUninit, size_of};

    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    }

    let mut info = MaybeUninit::<libc::proc_taskinfo>::zeroed();
    let size = size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info`.
    let written = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if written != size {
        return None;
    }
    // SAFETY: fully initialized by the successful call above.
    let info = unsafe { info.assume_init() };

    // CPU times are in Mach absolute time units (nanoseconds on Intel, not
    // on Apple silicon).
    let mut timebase = Timebase { numer: 1, denom: 1 };
    // SAFETY: writes one Timebase.
    if unsafe { mach_timebase_info(&mut timebase) } != 0 || timebase.denom == 0 {
        timebase = Timebase { numer: 1, denom: 1 };
    }
    let ticks = u128::from(info.pti_total_user) + u128::from(info.pti_total_system);
    let nanos = ticks * u128::from(timebase.numer) / u128::from(timebase.denom);
    Some(ProcessUsage {
        cpu_time: Duration::from_nanos(u64::try_from(nanos).unwrap_or(u64::MAX)),
        resident_bytes: info.pti_resident_size,
    })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_usage(_pid: u32) -> Option<ProcessUsage> {
    super::log_unsupported_once("process usage");
    None
}

/// Closest ancestor (or the directory itself) containing `.git`.
pub fn git_root(dir: &Path) -> Option<PathBuf> {
    // Never look into folders macOS guards with a privacy prompt (UTL-004).
    if crate::protected_paths::should_skip(dir) {
        return None;
    }
    dir.ancestors()
        .find(|p| p.join(".git").exists())
        .map(Path::to_path_buf)
}

/// Branch name from `.git/HEAD`, or a short commit id when detached.
/// Worktrees (`.git` file with `gitdir:`) are followed.
pub fn git_branch(root: &Path) -> Option<String> {
    let dot_git = root.join(".git");
    let git_dir = if dot_git.is_file() {
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let target = text.trim().strip_prefix("gitdir:")?.trim();
        let target = PathBuf::from(target);
        if target.is_absolute() {
            target
        } else {
            root.join(target)
        }
    } else {
        dot_git
    };
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    let head = head.trim();
    if let Some(reference) = head.strip_prefix("ref:") {
        return reference
            .trim()
            .strip_prefix("refs/heads/")
            .map(String::from)
            .or_else(|| Some(reference.trim().to_string()));
    }
    Some(head.chars().take(8).collect())
}

/// `~`-abbreviated path for display.
pub fn display_path(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_path_abbreviates_home() {
        let home = Path::new("/Users/me");
        assert_eq!(display_path(Path::new("/Users/me"), home), "~");
        assert_eq!(display_path(Path::new("/Users/me/code"), home), "~/code");
        assert_eq!(display_path(Path::new("/tmp"), home), "/tmp");
    }

    #[test]
    fn git_root_and_branch() {
        let dir = std::env::temp_dir().join(format!("chau7-next-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("src/deep")).unwrap();
        std::fs::write(dir.join(".git/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
        assert_eq!(git_root(&dir.join("src/deep")), Some(dir.clone()));
        assert_eq!(git_branch(&dir).as_deref(), Some("feature/x"));
        std::fs::write(dir.join(".git/HEAD"), "0123456789abcdef\n").unwrap();
        assert_eq!(git_branch(&dir).as_deref(), Some("01234567"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn linux_stat_parsing() {
        let stat = "1234 (my (odd) cmd) S 42 1234 1234 0 -1 4194304 100 0 0 0 \
                    7 3 0 0 20 0 1 0 555 1000000 250 18446744073709551615";
        assert_eq!(
            parse_linux_stat(stat),
            Some(LinuxStat {
                ppid: 42,
                cpu_ticks: 10,
                rss_pages: 250
            })
        );
        assert_eq!(parse_linux_stat("garbage"), None);
    }

    #[test]
    fn usage_adds_up() {
        let a = ProcessUsage {
            cpu_time: Duration::from_millis(5),
            resident_bytes: 10,
        };
        assert_eq!(
            a + a,
            ProcessUsage {
                cpu_time: Duration::from_millis(10),
                resident_bytes: 20
            }
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn own_args_and_environment() {
        let pid = std::process::id();
        assert!(
            process_args_env(pid).is_some_and(|(args, env)| !args.is_empty() && !env.is_empty())
        );
    }

    #[test]
    fn pid_zero_is_nothing() {
        assert!(child_pids(0).is_empty());
        assert!(process_tree(0).is_empty());
        assert_eq!(process_usage(0), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn own_process_is_visible() {
        let pid = std::process::id();
        assert_eq!(process_tree(pid).first(), Some(&pid));
        assert!(own_resident_bytes().is_some_and(|bytes| bytes > 0));
        let mut child = std::process::Command::new("sleep")
            .arg("5")
            .spawn()
            .expect("spawn sleep");
        let child_pid = child.id();
        assert!(child_pids(pid).contains(&child_pid));
        let _ = child.kill();
        let _ = child.wait();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn own_cwd_is_readable() {
        let pid = std::process::id();
        assert_eq!(process_cwd(pid), std::env::current_dir().ok());
    }
}

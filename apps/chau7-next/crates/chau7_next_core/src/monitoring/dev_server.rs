//! Port of `Monitoring/DevServerMonitor.swift` without the timers and
//! subprocesses: what a tab knows about its dev server, and the parsers for
//! `ps -axo ppid,pid` and `netstat -anv -p tcp` (macOS) and
//! `/proc/net/tcp` (Linux).
//!
//! Detection is event driven:
//! 1. a dev server command (`npm run dev`) starts a burst of 4 port checks,
//!    2 s then every 3 s, stopping once a port is known;
//! 2. output naming a server (Vite, Next.js, ...) sets it at once (with its
//!    URL and port when printed) and schedules one check 0.5 s later;
//! 3. when a command finishes, a known server is checked again (0.3 s).
//!
//! A check lists the shell's descendants; none left means the server
//! stopped. A descendant listening on a TCP port is the server.

use std::collections::{HashMap, HashSet};

use crate::command_detection::{
    COMMON_DEV_PORTS, DEV_SERVER_MAP, detect_dev_server_from_output, extract_dev_server_url,
    extract_port,
};
use crate::escape_sanitizer;

/// Port checks of a burst.
pub const BURST_CHECKS: u32 = 4;
/// Delay before the first burst check, then between checks (seconds).
pub const BURST_FIRST_DELAY: f64 = 2.0;
pub const BURST_INTERVAL: f64 = 3.0;
/// One-shot check after an output match, and after a command finished.
pub const OUTPUT_CHECK_DELAY: f64 = 0.5;
pub const FINISH_CHECK_DELAY: f64 = 0.3;
/// Output bytes looked at per chunk (`data.prefix(2048)`).
pub const OUTPUT_SCAN_BYTES: usize = 2048;

/// `DevServerInfo`. Two servers are the same when name and port match.
#[derive(Debug, Clone)]
pub struct DevServerInfo {
    pub name: String,
    pub port: Option<u16>,
    pub url: Option<String>,
    pub pid: Option<u32>,
}

impl PartialEq for DevServerInfo {
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name && self.port == other.port
    }
}

impl DevServerInfo {
    /// Tab badge text, "Vite :5173" or "Vite".
    pub fn badge(&self) -> String {
        match self.port {
            Some(port) => format!("{} :{port}", self.name),
            None => self.name.clone(),
        }
    }

    /// URL to open: the printed one, else `http://localhost:<port>`.
    pub fn open_url(&self) -> Option<String> {
        self.url
            .clone()
            .or_else(|| self.port.map(|p| format!("http://localhost:{p}")))
    }
}

/// `shouldStopBurstChecks`.
pub fn should_stop_burst_checks(current: Option<&DevServerInfo>, remaining: u32) -> bool {
    remaining == 0 || current.is_some_and(|s| s.port.is_some())
}

/// What the tracker asks the caller to do next.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CheckRequest {
    /// Start a burst of port checks.
    Burst,
    /// One port check after this many seconds.
    Once(f64),
}

/// One tab's dev server (`DevServerMonitor` state).
#[derive(Debug, Default, Clone)]
pub struct DevServerTracker {
    current: Option<DevServerInfo>,
    hint: Option<String>,
}

impl DevServerTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn current(&self) -> Option<&DevServerInfo> {
        self.current.as_ref()
    }

    /// A dev server command ran (`setCommandHint`).
    pub fn set_command_hint(&mut self, name: Option<String>) -> Option<CheckRequest> {
        let start = name.is_some();
        self.hint = name;
        start.then_some(CheckRequest::Burst)
    }

    /// Output text (`checkOutput`). Returns whether the shown server changed
    /// and the check to schedule.
    pub fn check_output(&mut self, output: &str) -> (bool, Option<CheckRequest>) {
        if self.current.is_some() {
            return (false, None);
        }
        let cleaned = escape_sanitizer::sanitize(output);
        let Some(name) = detect_dev_server_from_output(&cleaned) else {
            return (false, None);
        };
        let url = extract_dev_server_url(&cleaned);
        let port = url
            .as_deref()
            .and_then(|u| extract_port(&format!("{u} ")))
            .or_else(|| extract_port(&cleaned))
            .and_then(|p| u16::try_from(p).ok());
        let server = DevServerInfo {
            name,
            port,
            url,
            pid: None,
        };
        if self.current.as_ref() == Some(&server) {
            return (false, None);
        }
        self.current = Some(server);
        self.hint = None;
        // Swift only announces it at once when the port is known.
        (port.is_some(), Some(CheckRequest::Once(OUTPUT_CHECK_DELAY)))
    }

    /// The prompt came back (`commandDidFinish`).
    pub fn command_did_finish(&self) -> Option<CheckRequest> {
        self.current
            .is_some()
            .then_some(CheckRequest::Once(FINISH_CHECK_DELAY))
    }

    /// Applies a port check: `descendants` of the shell, and the first of
    /// them found listening (pid, port, process name). Returns true when the
    /// server changed (`checkForListeningPorts`).
    pub fn apply_check(
        &mut self,
        descendants: &[u32],
        listening: Option<(u32, u16, String)>,
    ) -> bool {
        if descendants.is_empty() {
            self.hint = None;
            return self.current.take().is_some();
        }
        let Some((pid, port, command)) = listening else {
            return false;
        };
        // The same process on the same port keeps its name (Swift renames it
        // "Node Server" on the next check once the command hint is used up).
        let name = match &self.current {
            Some(c) if c.port == Some(port) && c.pid == Some(pid) => c.name.clone(),
            _ => determine_server_name(port, &command, self.hint.take()),
        };
        let server = DevServerInfo {
            name,
            port: Some(port),
            url: Some(format!("http://localhost:{port}")),
            pid: Some(pid),
        };
        if self.current.as_ref() == Some(&server) {
            return false;
        }
        self.current = Some(server);
        true
    }

    /// The tab closed or the shell exited (`stop`). Returns true when a
    /// server was shown.
    pub fn stop(&mut self) -> bool {
        self.hint = None;
        self.current.take().is_some()
    }
}

/// `determineServerName`: the command hint, a well-known port, the process
/// name, "Node Server" for node, else "Dev Server".
pub fn determine_server_name(port: u16, command: &str, hint: Option<String>) -> String {
    if let Some(hint) = hint {
        return hint;
    }
    if let Some((_, name)) = COMMON_DEV_PORTS.iter().find(|(p, _)| *p == port) {
        return name.to_string();
    }
    let normalized = command.to_lowercase();
    if let Some(name) = DEV_SERVER_MAP.get(normalized.as_str()) {
        return name.to_string();
    }
    if normalized == "node" {
        return "Node Server".into();
    }
    "Dev Server".into()
}

/// Descendants of `root` from `ps -axo ppid,pid` output, breadth first.
pub fn descendants_from_ps(output: &str, root: u32) -> Vec<u32> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for line in output.lines() {
        let mut cols = line.split_whitespace();
        let (Some(ppid), Some(pid)) = (cols.next(), cols.next()) else {
            continue;
        };
        if let (Ok(ppid), Ok(pid)) = (ppid.parse(), pid.parse()) {
            children.entry(ppid).or_default().push(pid);
        }
    }
    let mut result = Vec::new();
    let mut queue: std::collections::VecDeque<u32> =
        children.get(&root).cloned().unwrap_or_default().into();
    let mut seen = HashSet::new();
    while let Some(pid) = queue.pop_front() {
        if !seen.insert(pid) {
            continue;
        }
        result.push(pid);
        if let Some(grand) = children.get(&pid) {
            queue.extend(grand);
        }
    }
    result
}

/// Port of a netstat local address (`*.3000`, `127.0.0.1.5173`, `::1.8080`).
pub fn port_from_netstat_address(address: &str) -> Option<u16> {
    address.rsplit_once('.')?.1.parse().ok()
}

/// First LISTEN line of `netstat -anv -p tcp` owned by one of `pids`
/// (pid in column 11): (pid, port).
pub fn listening_from_netstat(output: &str, pids: &[u32]) -> Option<(u32, u16)> {
    let pids: HashSet<u32> = pids.iter().copied().collect();
    for line in output.lines() {
        if !line.contains("LISTEN") {
            continue;
        }
        let columns: Vec<&str> = line.split_whitespace().collect();
        if columns.len() < 11 {
            continue;
        }
        let Ok(pid) = columns[10].parse::<u32>() else {
            continue;
        };
        if !pids.contains(&pid) {
            continue;
        }
        if let Some(port) = port_from_netstat_address(columns[3]) {
            return Some((pid, port));
        }
    }
    None
}

/// Listening sockets of `/proc/net/tcp` or `tcp6`: (inode, port).
pub fn listening_from_proc_net_tcp(text: &str) -> Vec<(u64, u16)> {
    let mut result = Vec::new();
    for line in text.lines().skip(1) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 10 || cols[3] != "0A" {
            continue;
        }
        let Some(port) = cols[1]
            .rsplit_once(':')
            .and_then(|(_, p)| u16::from_str_radix(p, 16).ok())
        else {
            continue;
        };
        if let Ok(inode) = cols[9].parse::<u64>() {
            result.push((inode, port));
        }
    }
    result
}

/// Inode of a `/proc/<pid>/fd/*` link target `socket:[123]`.
pub fn socket_inode(link: &str) -> Option<u64> {
    link.strip_prefix("socket:[")?
        .strip_suffix(']')?
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(port: Option<u16>) -> DevServerInfo {
        DevServerInfo {
            name: "Vite".into(),
            port,
            url: Some("http://localhost".into()),
            pid: None,
        }
    }

    #[test]
    fn burst_stop_rules() {
        assert!(!should_stop_burst_checks(Some(&server(None)), 3));
        assert!(should_stop_burst_checks(Some(&server(Some(5173))), 3));
        assert!(should_stop_burst_checks(None, 0));
    }

    #[test]
    fn output_detection_sets_server_once() {
        let mut t = DevServerTracker::new();
        let (changed, check) =
            t.check_output("\x1b[32m  VITE v5.0.0  ready\n  ➜  Local:   http://localhost:5173/\n");
        assert!(changed);
        assert_eq!(check, Some(CheckRequest::Once(OUTPUT_CHECK_DELAY)));
        let s = t.current().unwrap();
        assert_eq!(s.port, Some(5173));
        assert_eq!(s.url.as_deref(), Some("http://localhost:5173"));
        assert_eq!(s.badge(), format!("{} :5173", s.name));
        assert_eq!(t.check_output("VITE ready"), (false, None));
        assert_eq!(
            t.command_did_finish(),
            Some(CheckRequest::Once(FINISH_CHECK_DELAY))
        );
    }

    #[test]
    fn port_checks() {
        let mut t = DevServerTracker::new();
        assert_eq!(
            t.set_command_hint(Some("Next.js".into())),
            Some(CheckRequest::Burst)
        );
        assert!(!t.apply_check(&[10], None));
        assert!(t.apply_check(&[10, 11], Some((11, 4321, "node".into()))));
        assert_eq!(t.current().unwrap().name, "Next.js");
        assert!(!t.apply_check(&[10, 11], Some((11, 4321, "node".into()))));
        assert!(t.apply_check(&[], None));
        assert!(t.current().is_none());
        assert_eq!(t.command_did_finish(), None);
    }

    #[test]
    fn server_names() {
        assert_eq!(determine_server_name(1, "x", Some("Hint".into())), "Hint");
        assert_eq!(determine_server_name(1, "node", None), "Node Server");
        assert_eq!(determine_server_name(1, "python", None), "Dev Server");
        let (port, name) = COMMON_DEV_PORTS[0];
        assert_eq!(determine_server_name(port, "x", None), name);
    }

    #[test]
    fn ps_tree() {
        let ps = "PPID PID\n1 100\n100 200\n200 300\n100 201\n5 6\n";
        assert_eq!(descendants_from_ps(ps, 100), vec![200, 201, 300]);
        assert!(descendants_from_ps(ps, 6).is_empty());
    }

    #[test]
    fn netstat_lines() {
        let out = "Active Internet connections (including servers)\n\
tcp4       0      0  *.5173                 *.*                    LISTEN      0 0 131072 131072  12345      0 0x0100 0x00000006\n\
tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN      0 0 131072 131072    222      0 0x0100 0x00000006\n";
        assert_eq!(listening_from_netstat(out, &[222]), Some((222, 3000)));
        assert_eq!(
            listening_from_netstat(out, &[12345, 222]),
            Some((12345, 5173))
        );
        assert_eq!(listening_from_netstat(out, &[1]), None);
        assert_eq!(port_from_netstat_address("::1.8080"), Some(8080));
    }

    #[test]
    fn proc_net_tcp() {
        let text = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 00000000:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 54321 1 0000000000000000 100 0 0 10 0\n\
   1: 0100007F:0CEA 0100007F:1435 01 00000000:00000000 00:00000000 00000000  1000        0 99 1\n";
        assert_eq!(listening_from_proc_net_tcp(text), vec![(54321, 5173)]);
        assert_eq!(socket_inode("socket:[54321]"), Some(54321));
        assert_eq!(socket_inode("/dev/null"), None);
    }
}

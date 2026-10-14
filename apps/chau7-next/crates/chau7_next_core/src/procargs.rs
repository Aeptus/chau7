//! Arguments and environment of another process, for the profile
//! auto-switch rules (SSH host and environment variable triggers).
//!
//! macOS gives both in one `KERN_PROCARGS2` buffer; Linux in
//! `/proc/<pid>/cmdline` and `/proc/<pid>/environ` (NUL separated).

/// A process's arguments and `KEY=VALUE` environment.
pub type ArgsEnv = (Vec<String>, Vec<(String, String)>);

/// Parses a `KERN_PROCARGS2` buffer: `argc` (native i32), the executable
/// path, NUL padding, `argc` arguments, then `KEY=VALUE` environment entries,
/// each NUL terminated.
pub fn parse_procargs2(buf: &[u8]) -> Option<ArgsEnv> {
    if buf.len() < 4 {
        return None;
    }
    let argc = i32::from_ne_bytes(buf[..4].try_into().ok()?);
    if argc < 0 {
        return None;
    }
    let mut rest = &buf[4..];
    // Executable path.
    let end = rest.iter().position(|&b| b == 0)?;
    rest = &rest[end..];
    // NUL padding.
    let start = rest.iter().position(|&b| b != 0).unwrap_or(rest.len());
    rest = &rest[start..];
    let mut fields = rest.split(|&b| b == 0);
    let mut args = Vec::new();
    for _ in 0..argc {
        args.push(String::from_utf8_lossy(fields.next()?).into_owned());
    }
    let env = fields
        .take_while(|f| !f.is_empty())
        .filter_map(|f| split_env(&String::from_utf8_lossy(f)))
        .collect();
    Some((args, env))
}

/// NUL-separated fields (`/proc/<pid>/cmdline`), the empty tail dropped.
pub fn split_nul(buf: &[u8]) -> Vec<String> {
    buf.split(|&b| b == 0)
        .filter(|f| !f.is_empty())
        .map(|f| String::from_utf8_lossy(f).into_owned())
        .collect()
}

/// `KEY=VALUE` entries of `/proc/<pid>/environ`.
pub fn parse_environ(buf: &[u8]) -> Vec<(String, String)> {
    split_nul(buf).iter().filter_map(|e| split_env(e)).collect()
}

fn split_env(entry: &str) -> Option<(String, String)> {
    let (key, value) = entry.split_once('=')?;
    (!key.is_empty()).then(|| (key.to_string(), value.to_string()))
}

/// ssh options that take a value (`ssh(1)`).
const SSH_VALUE_OPTIONS: &str = "BbcDEeFIiJLlmOopPQRSWw";

/// The host an `ssh` command line connects to: the destination with its
/// `ssh://` scheme, `user@` and `:port` removed. `None` when `args` is not an
/// ssh command or has no destination.
pub fn ssh_host_from_args(args: &[String]) -> Option<String> {
    let program = args.first()?;
    let name = program.rsplit('/').next().unwrap_or(program);
    if name != "ssh" {
        return None;
    }
    let mut iter = args[1..].iter();
    while let Some(arg) = iter.next() {
        if arg == "--" {
            return iter.next().and_then(|d| destination_host(d));
        }
        if let Some(flags) = arg.strip_prefix('-')
            && !flags.is_empty()
        {
            // Combined flags such as `-tt` or `-p22`: a value option takes the
            // rest of the word, or the next word.
            for (i, flag) in flags.char_indices() {
                // These modes print/query and exit instead of connecting. Check
                // the parsed option itself before consuming its value so a `-G`
                // or `-Q` inside an `-o` value is not mistaken for a mode.
                if matches!(flag, 'G' | 'Q' | 'V') {
                    return None;
                }
                if SSH_VALUE_OPTIONS.contains(flag) {
                    if i + flag.len_utf8() == flags.len() {
                        iter.next();
                    }
                    break;
                }
            }
            continue;
        }
        return destination_host(arg);
    }
    None
}

fn destination_host(destination: &str) -> Option<String> {
    let rest = destination.strip_prefix("ssh://").unwrap_or(destination);
    let rest = rest.rsplit_once('@').map_or(rest, |(_, host)| host);
    let host = if let Some(inner) = rest.strip_prefix('[') {
        inner.split(']').next().unwrap_or(inner)
    } else if destination.starts_with("ssh://") {
        rest.split(':').next().unwrap_or(rest)
    } else {
        rest
    };
    let host = host.trim_end_matches('/');
    (!host.is_empty() && !host.chars().any(|character| character.is_ascii_control()))
        .then(|| host.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn procargs2_buffer() {
        let mut buf = 2i32.to_ne_bytes().to_vec();
        buf.extend_from_slice(
            b"/usr/bin/ssh\0\0\0\0ssh\0prod.example.com\0HOME=/Users/me\0AWS_PROFILE=prod\0\0junk",
        );
        let (a, env) = parse_procargs2(&buf).unwrap();
        assert_eq!(a, args(&["ssh", "prod.example.com"]));
        assert_eq!(
            env,
            vec![
                ("HOME".to_string(), "/Users/me".to_string()),
                ("AWS_PROFILE".to_string(), "prod".to_string())
            ]
        );
        assert_eq!(parse_procargs2(&[1, 2]), None);
    }

    #[test]
    fn proc_files() {
        assert_eq!(
            split_nul(b"ssh\0-p\x0022\0host\0"),
            args(&["ssh", "-p", "22", "host"])
        );
        assert_eq!(
            parse_environ(b"A=1\0B=x=y\0bad\0"),
            vec![("A".into(), "1".into()), ("B".into(), "x=y".into())]
        );
    }

    #[test]
    fn ssh_hosts() {
        let host = |l: &[&str]| ssh_host_from_args(&args(l));
        assert_eq!(host(&["ssh", "prod"]).as_deref(), Some("prod"));
        assert_eq!(
            host(&["/usr/bin/ssh", "me@db.example.com"]).as_deref(),
            Some("db.example.com")
        );
        assert_eq!(
            host(&["ssh", "-p", "2222", "-i", "~/.ssh/k", "me@h"]).as_deref(),
            Some("h")
        );
        assert_eq!(
            host(&["ssh", "-P", "work", "user@actualhost"]).as_deref(),
            Some("actualhost")
        );
        assert_eq!(host(&["ssh", "-p2222", "-tt", "h2"]).as_deref(), Some("h2"));
        assert_eq!(
            host(&["ssh", "-o", "StrictHostKeyChecking=no", "h3", "ls"]).as_deref(),
            Some("h3")
        );
        assert_eq!(host(&["ssh", "ssh://me@h4:2200"]).as_deref(), Some("h4"));
        assert_eq!(host(&["ssh", "me@[::1]"]).as_deref(), Some("::1"));
        assert_eq!(host(&["ssh", "--", "h5"]).as_deref(), Some("h5"));
        assert_eq!(host(&["ssh", "--", "-G"]).as_deref(), Some("-G"));
        assert_eq!(host(&["ssh", "-v"]), None);
        assert_eq!(host(&["ssh", "-G", "prod"]), None);
        assert_eq!(host(&["ssh", "-Q", "cipher", "prod"]), None);
        assert_eq!(host(&["ssh", "-V"]), None);
        assert_eq!(host(&["ssh", "prod\nmalicious"]), None);
        assert_eq!(
            host(&["ssh", "-o", "ProxyCommand=ssh -G", "prod"]).as_deref(),
            Some("prod")
        );
        assert_eq!(host(&["ssh", "-N", "prod"]).as_deref(), Some("prod"));
        assert_eq!(host(&["scp", "a", "h:b"]), None);
    }
}

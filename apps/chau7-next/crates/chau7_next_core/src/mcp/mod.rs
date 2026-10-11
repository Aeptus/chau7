//! Pure logic of the MCP server (`apps/chau7-macos/Sources/Chau7/MCP/`):
//! the JSON-RPC session, the command filter, tool output formatting and the
//! registration of the bridge in AI CLI configs. The socket, the tabs and the
//! dialogs live in `chau7_next::mcp`; the bridge is the
//! `chau7_next_mcp_bridge` crate.

pub mod client_config;
pub mod command_filter;
pub mod output;
pub mod protocol;

use std::path::{Path, PathBuf};

/// File name of the bridge binary (next to the app binary, and installed in
/// `DataRoot::bin_dir`). The Swift app's is `chau7-mcp-bridge`.
pub const BRIDGE_BINARY_NAME: &str = "chau7-next-mcp-bridge";

/// Bridge argument naming the socket. The configs pass it so the bridge
/// reaches the socket of the app that registered it, whatever the
/// environment of the AI CLI that launches it.
pub const SOCKET_ARG: &str = "--socket";

/// Environment variable read by the bridge when no argument is given.
pub const SOCKET_ENV: &str = "CHAU7_NEXT_MCP_SOCKET";

/// Error line the bridge prints when the app is not running.
pub const NOT_RUNNING_MESSAGE: &str = "Chau7 Next is not running. Start the app to enable MCP.";

/// The arguments written in the client configs.
pub fn bridge_args(socket: &Path) -> Vec<String> {
    vec![
        SOCKET_ARG.to_string(),
        socket.to_string_lossy().into_owned(),
    ]
}

/// The socket named on a bridge command line (`--socket PATH` or
/// `--socket=PATH`), if any.
pub fn socket_from_args(args: &[String]) -> Option<PathBuf> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == SOCKET_ARG {
            return iter.next().map(PathBuf::from);
        }
        if let Some(value) = arg.strip_prefix("--socket=") {
            return Some(PathBuf::from(value));
        }
    }
    None
}

/// The JSON-RPC error line the bridge prints before exiting with status 1.
pub fn bridge_error_line(message: &str) -> String {
    let error = serde_json::json!({
        "jsonrpc": "2.0",
        "id": null,
        "error": {"code": -32000, "message": message}
    });
    format!("{error}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_argument_round_trips() {
        let args = bridge_args(Path::new("/h/.chau7-next/mcp.sock"));
        assert_eq!(args, ["--socket", "/h/.chau7-next/mcp.sock"]);
        assert_eq!(
            socket_from_args(&args),
            Some(PathBuf::from("/h/.chau7-next/mcp.sock"))
        );
        assert_eq!(
            socket_from_args(&["--socket=/x".to_string()]),
            Some(PathBuf::from("/x"))
        );
        assert_eq!(socket_from_args(&[]), None);
        assert_eq!(socket_from_args(&["--socket".to_string()]), None);
    }

    #[test]
    fn error_line_matches_swift_shape() {
        let line = bridge_error_line(NOT_RUNNING_MESSAGE);
        assert!(line.ends_with('\n'));
        let v: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(v["id"], serde_json::Value::Null);
        assert_eq!(v["error"]["code"], -32000);
        assert_eq!(v["error"]["message"], NOT_RUNNING_MESSAGE);
    }
}

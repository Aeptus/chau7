# Scripting

Swift: `apps/chau7-macos/Sources/Chau7/Scripting/` (2 files, 516 lines)
Swift tests: `Scripting/ScriptingAPITests.swift`
Wave: 3 (see README.md)
Depends on: MCP (every tab method calls `TerminalControlService`), History, Snippets, Settings

A local JSON-over-Unix-socket API so shell scripts can list tabs, run commands, read output, open and close tabs, search history and read a few settings. It is off by default (`feature.scriptingAPI`). There is no AppleScript dictionary and no `chau7` CLI; the `chau7://` URL scheme lives in the App module (see Notes).

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SCR-001 | Scripting socket at `~/Library/Application Support/Chau7/scripting.sock`, started when `feature.scriptingAPI` is true and stopped (socket removed) when it is turned off; tracks connected clients and uptime | `Scripting/ScriptingAPI.swift` | `ScriptingAPITests` | `chau7_next/src/scripting.rs`, `chau7_next/src/settings/mcp.rs`, `chau7_next/src/settings_window/mcp.rs`, `chau7_next_core/src/data_root.rs` | done | Unix sockets |
| SCR-002 | Newline-delimited JSON requests `{"method", "params", "id"}`; response is one JSON line with sorted keys and the request `id` echoed; lines over 1 MB rejected with `{"error":"request too large"}`; bad JSON gives `{"error":"invalid JSON"}` | `Scripting/ScriptingClientHandler.swift` | `ScriptingAPITests` | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-003 | `list_tabs`: all tabs (via `tab_list`) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-004 | `get_tab` (`id`): tab status (via `tab_status`) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-005 | `run_command` (`tab_id`, `command`): runs a command at the prompt (via `tab_exec`, same MCP command filter) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-006 | `get_output` (`tab_id`, `lines` default 50): scrollback tail (via `tab_output`) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-007 | `create_tab` (`directory`): opens a background MCP tab (via `tab_create`, same limits) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-008 | `close_tab` (`id`): closes a tab, always forced | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-009 | `get_history` (`query`, `limit` default 50): recent or matching commands with timestamp, directory, exit code, shell, tab id, duration | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-010 | `get_settings`: `feature.scriptingAPI`, `feature.persistentHistory`, `history.maxRecords` | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-011 | `set_setting` (`key`, `value`): only the three keys above, only Bool/Int/Double/String values | `Scripting/ScriptingAPI.swift` | `ScriptingAPITests` | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-012 | `list_snippets`: returns an empty list (stub) | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-013 | `run_snippet` (`name`): finds a snippet by title and returns its body; does not run it | `Scripting/ScriptingAPI.swift` |  | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-014 | `get_status`: version, build, uptime, connected clients, server running, history count | `Scripting/ScriptingAPI.swift` | `ScriptingAPITests` | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |
| SCR-015 | Errors: `{"error":"missing method"}`, `{"error":"unknown method: <m>"}`, `{"error":"missing param: <p>"}` | `Scripting/ScriptingAPI.swift` | `ScriptingAPITests` | `chau7_next_core/src/scripting.rs`, `chau7_next/src/scripting.rs` | done |  |

## Notes

- **The Swift app never starts this server.** `ScriptingAPI.shared` is only
  referenced inside `Scripting/` and by tests, and no settings UI writes
  `feature.scriptingAPI`. Ported as designed (user decision, 2026-10-10):
  Chau7 Next starts it from Settings > MCP > "Enable Scripting API"
  (`[next] scripting_api`, off by default), socket `DataRoot::scripting_socket()`
  (owner-only), protocol and methods in `chau7_next_core::scripting`, server in
  `chau7_next/src/scripting.rs`. Tab methods call the MCP tab tools.
- Settings mapping: `feature.scriptingAPI` is `[next] scripting_api`,
  `feature.persistentHistory` and `history.maxRecords` are the History settings.
  `set_setting` stores them in config.toml (Bool keys take a Bool, a number or
  yes/no text, as `UserDefaults.bool`; `history.maxRecords` takes a number and is
  clamped to 10,000 to 100,000 like the History settings).
- Swift bugs fixed in Chau7 Next (not copied): `list_tabs` always returned
  `{"tabs":[]}` because `tab_list` returns a JSON array and the handler only
  accepts objects (Rust returns `{"result":[tabs]}`, as the Swift test expects);
  `create_tab` documented a `command` param and ignored it (Rust runs it with
  `tab_exec` and reports a failure as `command_error`); `list_snippets` was a stub
  (Rust returns `[{title, body}]`).
- Response shapes: tab methods return the MCP tool JSON object as-is (see
  MCP.md), the rest use `{"result": ...}`, errors use `{"error": ...}`; not
  JSON-RPC envelopes. `get_history` timestamps are Unix seconds (float).
- Chau7 Next path: put the socket in the Chau7 Next state folder
  (`~/Library/Application Support/Chau7 Next/scripting.sock`, add a
  `DataRoot::scripting_socket()`), never the Swift path.
- No AppleScript: no `.sdef`, no `NSAppleScriptEnabled` in the Info.plist built
  by `Scripts/build-app.sh`. No command line tool.
- URL scheme (App module, `App/AppDelegate.swift`, registered via
  `CFBundleURLTypes` in `Scripts/build-app.sh`): `chau7://run/<base64 command>`
  (asks for confirmation, then runs), `chau7://ssh/<user@host[:port]>` (new tab
  running `ssh`), `chau7://cd/<path>` (new tab, `cd` then `clear`),
  `chau7://open/<path>` (opens the file in the editor pane). Also
  `chau7://view/<token>` is generated by Remote viewer mode. Track these in
  App.md; Chau7 Next has no URL scheme yet and must not claim `chau7://` while
  both apps are installed (use e.g. `chau7-next://`).

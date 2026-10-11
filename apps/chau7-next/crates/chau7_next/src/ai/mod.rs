//! AI CLI integration (Swift `AI/` and the AI parts of `AppModel`): the
//! unified AI event feed ([`events_out`]), the app-wide monitors ([`hub`]),
//! the AI PTY log of each session ([`session_log`]), the LLM client with
//! keys in the Keychain ([`llm`]), "Explain This Error" ([`explain`]) and
//! the log view of AI tool output ([`log_view`]).

pub mod events_out;
pub mod explain;
pub mod hub;
pub mod llm;
pub mod log_view;
pub mod session_log;

use gpui::App;

/// Starts the AI monitors (`AppModel.bootstrap`).
pub fn init(cx: &mut App) {
    hub::init(cx);
    log_view::register(cx);
}

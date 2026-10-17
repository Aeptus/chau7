//! Keyboard, mouse and clipboard logic for the terminal view: what a person
//! types or drops, turned into the bytes or state the Swift app produces.
//!
//! - [`paste_escaper`]: Paste Escaped (`PasteEscaper.swift`).
//! - [`command_history`]: Up/Down prompt history (`CommandHistoryManager.swift`)
//!   and the typed-line buffer that feeds it.
//! - [`input_lines`]: rows where commands were entered (`InputLineTracker.swift`).
//! - [`clipboard_history`]: clipboard history (`ClipboardHistoryManager.swift`).
//! - [`shortcuts`]: custom shortcuts and presets (`KeyboardShortcut`,
//!   `KeybindingsManager.swift`).
//! - [`kitty`]: Kitty keyboard protocol encoding of key events.
//! - [`local_echo`]: typed characters drawn before the shell echoes them.
//! - [`drop`]: drag and drop payloads (`RustTerminalView` drag and drop).
//! - [`cursor_moves`]: click to position and Option-click arrow sequences.

pub mod clipboard_history;
pub mod command_history;
pub mod cursor_moves;
pub mod drop;
pub mod input_lines;
pub mod kitty;
pub mod local_echo;
pub mod paste_escaper;
pub mod shortcuts;

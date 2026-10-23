//! chau7_terminal - Alacritty-based terminal emulator FFI bindings
//!
//! This crate provides C-compatible FFI bindings for terminal emulation
//! using the alacritty_terminal library and portable-pty for PTY management.

mod color;
mod ffi;
pub mod graphics;
mod metrics;
mod pool;
mod pty;
#[cfg(unix)]
mod reader_pool;
mod rust_api;
mod selection;
mod terminal;
mod types;

pub use color::*;
pub use ffi::*;
pub use metrics::*;
pub use pool::*;
pub use pty::*;
pub use rust_api::*;
pub use selection::*;
pub use terminal::*;
pub use types::*;

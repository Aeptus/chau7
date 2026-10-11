//! Isolated Next implementation of current Swift agent skill lifecycle and CLI.
pub mod cli;
pub mod inspector;
pub mod installer;
pub mod manifest;
pub mod models;
pub mod planner;
pub mod targets;
pub mod validator;
pub use models::*;

#[cfg(test)]
mod tests;

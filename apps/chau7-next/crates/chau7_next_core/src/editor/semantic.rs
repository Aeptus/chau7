//! Semantic command search (`SemanticOutputDetector` in
//! `Editor/SyntaxHighlighter.swift`): the commands recorded from shell
//! integration, searched by command text, and the failed ones.
//!
//! Chau7 Next records the blocks once, in the session's
//! [`CommandBlockList`] (OSC 133 markers); these functions search it the way
//! the detector searches its own copy in Swift. The Find bar's semantic
//! mode (TRM-054, OVL-099) calls [`search`].

use crate::command_block::{CommandBlock, CommandBlockList};

/// Blocks whose command contains `query`, case-insensitive, oldest first;
/// the running block (if it matches) comes last, as in Swift.
pub fn search<'a>(list: &'a CommandBlockList, query: &str) -> Vec<&'a CommandBlock> {
    let query = query.to_lowercase();
    let (running, done): (Vec<&CommandBlock>, Vec<&CommandBlock>) = list
        .blocks()
        .iter()
        .filter(|b| b.command.to_lowercase().contains(&query))
        .partition(|b| b.is_running());
    done.into_iter().chain(running).collect()
}

/// Blocks that ended with a non-zero exit code (`findErrors`).
pub fn errors(list: &CommandBlockList) -> Vec<&CommandBlock> {
    list.blocks().iter().filter(|b| b.is_failed()).collect()
}

/// Preview line of a match in the Find bar: the command, with its exit code
/// when known (`updateSemanticSearch`).
pub fn preview_line(block: &CommandBlock) -> String {
    match block.exit_code {
        Some(code) => format!("{} (exit {code})", block.command),
        None => block.command.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> CommandBlockList {
        let mut list = CommandBlockList::new();
        list.command_started("cargo build", 0, None);
        list.command_finished(10, 0);
        list.command_started("cargo test", 11, None);
        list.command_finished(40, 101);
        list.command_started("Cargo run", 41, None);
        list
    }

    #[test]
    fn search_is_case_insensitive_with_running_last() {
        let list = list();
        let found: Vec<_> = search(&list, "CARGO").iter().map(|b| &b.command).collect();
        assert_eq!(found, ["cargo build", "cargo test", "Cargo run"]);
        assert_eq!(search(&list, "test").len(), 1);
        assert!(search(&list, "npm").is_empty());
    }

    #[test]
    fn errors_and_previews() {
        let list = list();
        let errs = errors(&list);
        assert_eq!(errs.len(), 1);
        assert_eq!(preview_line(errs[0]), "cargo test (exit 101)");
        assert_eq!(preview_line(list.blocks().last().unwrap()), "Cargo run");
    }
}

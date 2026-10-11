//! Semantic command search (`SemanticOutputDetector.search` and
//! `TerminalSessionModel.updateSemanticSearch`): finds past commands whose
//! text contains the query (case-insensitive) and previews them with their
//! exit code. Chau7 Next takes the commands from the session's command
//! blocks (OSC 133), which hold the same command, start line and exit code.

use crate::command_block::CommandBlock;

/// One found command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticMatch {
    /// Absolute buffer line where the command starts.
    pub line: i64,
    /// Highlight length (the command text, at least 1).
    pub length: usize,
    /// The command text.
    pub command: String,
}

/// The line that shows `command`: the block's start line or one of the two
/// lines above it. Command blocks record the cursor line once the shell
/// reports the command, which is often the line after the typed one (Swift
/// records the typed line). `line_text` reads an absolute line.
pub fn locate_command_line(
    start_line: i64,
    command: &str,
    line_text: impl Fn(i64) -> Option<String>,
) -> i64 {
    let needle: String = command.trim().chars().take(40).collect();
    if needle.is_empty() {
        return start_line;
    }
    (0..3)
        .map(|back| start_line - back)
        .find(|line| line_text(*line).is_some_and(|text| text.contains(&needle)))
        .unwrap_or(start_line)
}

/// Matches (oldest first, at most `max_matches`) and the first
/// `max_preview_lines` previews ("cmd (exit N)" or "cmd").
pub fn search(
    blocks: &[CommandBlock],
    query: &str,
    max_matches: usize,
    max_preview_lines: usize,
) -> (Vec<SemanticMatch>, Vec<String>) {
    let lowered = query.to_lowercase();
    let found: Vec<&CommandBlock> = blocks
        .iter()
        .filter(|b| !b.command.is_empty() && b.command.to_lowercase().contains(&lowered))
        .take(max_matches)
        .collect();
    let matches = found
        .iter()
        .map(|b| SemanticMatch {
            line: b.start_line,
            length: b.command.chars().count().max(1),
            command: b.command.clone(),
        })
        .collect();
    let previews = found
        .iter()
        .take(max_preview_lines)
        .map(|b| match b.exit_code {
            Some(code) => format!("{} (exit {code})", b.command),
            None => b.command.clone(),
        })
        .collect();
    (matches, previews)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command_block::CommandBlockList;

    #[test]
    fn command_line_is_found_above_the_block_start() {
        let lines = |line: i64| match line {
            4 => Some("user@host:~$ cargo build --release".to_string()),
            5 => Some("   Compiling x".to_string()),
            _ => None,
        };
        assert_eq!(locate_command_line(5, "cargo build --release", lines), 4);
        assert_eq!(locate_command_line(4, "cargo build --release", lines), 4);
        assert_eq!(locate_command_line(9, "make", lines), 9);
    }

    #[test]
    fn finds_commands_with_exit_codes() {
        let mut list = CommandBlockList::new();
        list.command_started("cargo build", 10, None);
        list.command_finished(20, 101);
        list.command_started("ls", 21, None);
        list.command_finished(22, 0);
        list.command_started("cargo test", 23, None);
        let (matches, previews) = search(list.blocks(), "CARGO", 10, 10);
        assert_eq!(
            matches,
            vec![
                SemanticMatch {
                    line: 10,
                    length: 11,
                    command: "cargo build".into()
                },
                SemanticMatch {
                    line: 23,
                    length: 10,
                    command: "cargo test".into()
                }
            ]
        );
        assert_eq!(previews, vec!["cargo build (exit 101)", "cargo test"]);
        let (matches, previews) = search(list.blocks(), "cargo", 1, 0);
        assert_eq!(matches.len(), 1);
        assert!(previews.is_empty());
    }
}

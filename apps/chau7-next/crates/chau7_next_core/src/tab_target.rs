//! Port of `apps/chau7-macos/Sources/Chau7Core/TabTarget.swift`.

use uuid::Uuid;

/// Encapsulates the routing parameters needed to resolve which tab an event
/// targets (`TabTarget`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TabTarget {
    pub tool: String,
    pub directory: Option<String>,
    pub tab_id: Option<Uuid>,
    /// AI session ID (for example a Claude session ID) for disambiguation when
    /// multiple tabs run the same tool in the same directory.
    pub session_id: Option<String>,
}

impl TabTarget {
    /// Creates a target with only a tool name.
    pub fn new(tool: impl Into<String>) -> Self {
        Self {
            tool: tool.into(),
            directory: None,
            tab_id: None,
            session_id: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_target_has_only_a_tool() {
        let target = TabTarget::new("Claude");
        assert_eq!(target.tool, "Claude");
        assert_eq!(target.directory, None);
        assert_eq!(target.tab_id, None);
        assert_eq!(target.session_id, None);
    }

    #[test]
    fn equality_compares_all_fields() {
        let id = Uuid::new_v4();
        let a = TabTarget {
            tool: "Claude".into(),
            directory: Some("/tmp".into()),
            tab_id: Some(id),
            session_id: Some("s".into()),
        };
        let mut b = a.clone();
        assert_eq!(a, b);
        b.session_id = None;
        assert_ne!(a, b);
    }
}

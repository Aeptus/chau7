//! Delegated tasks and Chau7-owned limits. Network and file-write flags
//! describe intent; the agent backend must provide any sandbox guarantee.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct DelegationPolicy {
    #[serde(alias = "max_turns")]
    pub max_turns: Option<i64>,
    #[serde(alias = "max_duration_ms")]
    pub max_duration_ms: Option<i64>,
    #[serde(alias = "allow_child_delegation")]
    pub allow_child_delegation: bool,
    #[serde(alias = "max_delegation_depth")]
    pub max_delegation_depth: u32,
    #[serde(alias = "allowed_tools")]
    pub allowed_tools: Vec<String>,
    #[serde(alias = "blocked_tools")]
    pub blocked_tools: Vec<String>,
    #[serde(alias = "allow_network")]
    pub allow_network: Option<bool>,
    #[serde(alias = "allow_file_writes")]
    pub allow_file_writes: Option<bool>,
}
impl Default for DelegationPolicy {
    fn default() -> Self {
        Self {
            max_turns: None,
            max_duration_ms: None,
            allow_child_delegation: true,
            max_delegation_depth: 4,
            allowed_tools: Vec::new(),
            blocked_tools: Vec::new(),
            allow_network: None,
            allow_file_writes: None,
        }
    }
}
impl DelegationPolicy {
    pub fn validate_start(&self, turns: u64, elapsed_ms: i64, depth: u32) -> Option<String> {
        if depth > self.max_delegation_depth {
            return Some(format!(
                "Delegation depth {depth} exceeds max_delegation_depth {}.",
                self.max_delegation_depth
            ));
        }
        if self
            .max_turns
            .is_some_and(|max| turns as i128 > i128::from(max))
        {
            return Some(format!(
                "Session exceeded max_turns {}.",
                self.max_turns.unwrap()
            ));
        }
        if self.max_duration_ms.is_some_and(|max| elapsed_ms > max) {
            return Some(format!(
                "Session exceeded max_duration_ms {}.",
                self.max_duration_ms.unwrap()
            ));
        }
        None
    }
    pub fn validate_child(&self, depth: u32) -> Option<String> {
        if !self.allow_child_delegation {
            return Some("Session policy disallows child delegation.".into());
        }
        (depth > self.max_delegation_depth).then(|| {
            format!(
                "Child delegation depth {depth} exceeds max_delegation_depth {}.",
                self.max_delegation_depth
            )
        })
    }
    pub fn validate_tool(&self, tool: &str) -> Option<String> {
        let tool = tool.trim();
        if tool.is_empty() {
            return None;
        }
        if self
            .blocked_tools
            .iter()
            .any(|blocked| blocked.eq_ignore_ascii_case(tool))
        {
            return Some(format!("Tool '{tool}' is blocked by session policy."));
        }
        if !self.allowed_tools.is_empty()
            && !self
                .allowed_tools
                .iter()
                .any(|allowed| allowed.eq_ignore_ascii_case(tool))
        {
            return Some(format!("Tool '{tool}' is not in the session allowlist."));
        }
        None
    }
    pub fn summary(&self) -> Value {
        let mut out = json!({"allow_child_delegation": self.allow_child_delegation,
            "max_delegation_depth": self.max_delegation_depth, "allowed_tools": self.allowed_tools,
            "blocked_tools": self.blocked_tools});
        for (key, value) in [
            ("max_turns", self.max_turns.map(Value::from)),
            ("max_duration_ms", self.max_duration_ms.map(Value::from)),
            ("allow_network", self.allow_network.map(Value::from)),
            ("allow_file_writes", self.allow_file_writes.map(Value::from)),
        ] {
            if let Some(value) = value {
                out[key] = value;
            }
        }
        out
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnResultStatus {
    Available,
    Invalid,
    Missing,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct TurnResult {
    pub session_id: String,
    pub turn_id: String,
    pub status: TurnResultStatus,
    pub source: String,
    pub captured_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
    pub validation_errors: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_text: Option<String>,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_owned_limits() {
        let mut policy = DelegationPolicy::default();
        assert!(policy.allow_child_delegation);
        assert_eq!(policy.max_delegation_depth, 4);
        assert!(policy.validate_child(5).is_some());
        policy.max_turns = Some(1);
        assert!(policy.validate_start(1, 0, 0).is_none());
        assert!(policy.validate_start(2, 0, 0).is_some());
        policy.max_duration_ms = Some(100);
        assert!(policy.validate_start(1, 101, 0).is_some());
        policy.blocked_tools = vec!["Write".into()];
        assert!(policy.validate_tool("write").is_some());
        policy.allowed_tools = vec!["Read".into()];
        assert!(policy.validate_tool("Bash").is_some());
        assert!(policy.validate_tool(" read ").is_none());
    }
    #[test]
    fn old_partial_policy_gets_current_defaults() {
        let policy: DelegationPolicy = serde_json::from_value(json!({"max_turns": 1})).unwrap();
        assert_eq!(policy.max_turns, Some(1));
        assert!(policy.allow_child_delegation);
    }
}

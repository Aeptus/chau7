//! Current code-review task template and result contract.
use super::delegated_task::DelegationPolicy;
use serde_json::{Value, json};
pub fn default_policy() -> DelegationPolicy {
    DelegationPolicy {
        max_turns: Some(1),
        allow_child_delegation: false,
        max_delegation_depth: 0,
        blocked_tools: vec!["Write".into(), "Edit".into(), "NotebookEdit".into()],
        allow_file_writes: Some(false),
        ..Default::default()
    }
}
pub fn result_schema() -> Value {
    json!({"type":"object","required":["summary","findings","recommendations","confidence"],
    "properties":{"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","required":["severity","file","message"],
        "properties":{"severity":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"},"message":{"type":"string"},"recommendation":{"type":"string"}}}},
        "recommendations":{"type":"array","items":{"type":"string"}},"confidence":{"type":"string","enum":["low","medium","high"]}}})
}
fn preamble() -> &'static str {
    "Work read-only. Do not edit files. Do not delegate to another reviewer.\nFocus on correctness, regressions, security, and missing tests.\nReturn concise prose findings first, then end with a fenced JSON block that matches the requested schema."
}
pub fn prompt(base: &str, head: &str, extra: Option<&str>) -> String {
    let mut text = format!("Review commits {base}..{head}.\n{}", preamble());
    if let Some(extra) = extra.filter(|s| !s.trim().is_empty()) {
        text.push_str(&format!("\nAdditional instructions: {extra}"));
    }
    text
}
pub fn staged_prompt(files: &[String], diff: &str, extra: Option<&str>) -> String {
    let mut text = format!(
        "Review the staged changes that are about to be committed.\nOnly evaluate the staged diff below. Do not speculate about unstaged changes.\n{}",
        preamble()
    );
    if !files.is_empty() {
        text.push_str("\nStaged files:");
        for file in files {
            text.push_str(&format!("\n- {file}"));
        }
    }
    if let Some(extra) = extra.filter(|s| !s.trim().is_empty()) {
        text.push_str(&format!("\nAdditional instructions: {extra}"));
    }
    text.push_str(&format!("\nStaged diff:\n```diff\n{diff}\n```"));
    text
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn review_policy_and_contract_match_current_swift() {
        let policy = default_policy();
        assert!(!policy.allow_child_delegation);
        assert_eq!(policy.max_turns, Some(1));
        assert!(policy.validate_tool("Write").is_some());
        assert!(prompt("a", "b", None).contains("a..b"));
        assert!(staged_prompt(&[], "diff", None).contains("staged diff"));
        assert!(
            super::super::structured_result::validate(
                &json!({"summary":"ok","findings":[],"recommendations":[],"confidence":"high"}),
                &result_schema()
            )
            .is_empty()
        );
    }
}

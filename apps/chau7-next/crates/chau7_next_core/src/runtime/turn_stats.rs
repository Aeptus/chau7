//! Port of `Runtime/TurnStats.swift`: per-turn tool tallies and token usage,
//! flattened into `turn_completed` event data.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::telemetry::token_metrics::TokenUsage;

/// Tracks a single tool's usage during a turn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolTally {
    pub name: String,
    pub count: i64,
    /// Deduplicated paths.
    pub files: Vec<String>,
}

impl ToolTally {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            count: 0,
            files: Vec::new(),
        }
    }
}

/// Accumulates tool calls and token usage during a single agent turn.
///
/// [`summary`](Self::summary) returns a flat string map that goes straight
/// into `RuntimeEvent.data` for the `turn_completed` event.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnStats {
    tool_tallies: HashMap<String, ToolTally>,
    input_tokens: i64,
    output_tokens: i64,
    #[serde(default)]
    reasoning_output_tokens: i64,
    cache_creation_tokens: i64,
    cache_read_tokens: i64,
}

impl TurnStats {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn tool_tallies(&self) -> &HashMap<String, ToolTally> {
        &self.tool_tallies
    }

    pub fn input_tokens(&self) -> i64 {
        self.input_tokens
    }

    pub fn output_tokens(&self) -> i64 {
        self.output_tokens
    }

    pub fn cache_creation_tokens(&self) -> i64 {
        self.cache_creation_tokens
    }

    pub fn cache_read_tokens(&self) -> i64 {
        self.cache_read_tokens
    }

    pub fn reasoning_output_tokens(&self) -> i64 {
        self.reasoning_output_tokens
    }
    pub fn total_billable_tokens(&self) -> i64 {
        self.total_tokens()
            + self.cache_creation_tokens
            + self.cache_read_tokens
            + self.reasoning_output_tokens
    }
    /// Input + output.
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens
    }

    pub fn token_usage(&self) -> TokenUsage {
        TokenUsage::canonical(
            self.input_tokens,
            self.cache_creation_tokens + self.cache_read_tokens,
            self.cache_creation_tokens,
            self.cache_read_tokens,
            self.output_tokens,
            self.reasoning_output_tokens,
        )
    }

    /// Record a tool invocation, optionally with a file path.
    pub fn record_tool_use(&mut self, name: &str, file: Option<&str>) {
        let tally = self
            .tool_tallies
            .entry(name.to_string())
            .or_insert_with(|| ToolTally::new(name));
        tally.count += 1;
        if let Some(file) = file
            && !file.is_empty()
            && !tally.files.iter().any(|f| f == file)
        {
            tally.files.push(file.to_string());
        }
    }

    /// Add token counts (cumulative: call once per API response chunk).
    pub fn add_tokens(&mut self, input: i64, output: i64, cache_creation: i64, cache_read: i64) {
        self.add_tokens_with_reasoning(input, output, cache_creation, cache_read, 0);
    }
    pub fn add_tokens_with_reasoning(
        &mut self,
        input: i64,
        output: i64,
        cache_creation: i64,
        cache_read: i64,
        reasoning: i64,
    ) {
        self.reasoning_output_tokens += reasoning.max(0);
        self.input_tokens += input.max(0);
        self.output_tokens += output.max(0);
        self.cache_creation_tokens += cache_creation.max(0);
        self.cache_read_tokens += cache_read.max(0);
    }

    /// Flat map suitable for `RuntimeEvent.data`. Keys are part of the MCP API.
    pub fn summary(&self) -> BTreeMap<String, String> {
        let unique_files: BTreeSet<&String> = self
            .tool_tallies
            .values()
            .flat_map(|t| t.files.iter())
            .collect();
        let mut names: Vec<&str> = self.tool_tallies.keys().map(String::as_str).collect();
        names.sort_unstable();
        let tool_names = names.join(",");
        let total_calls: i64 = self.tool_tallies.values().map(|t| t.count).sum();

        BTreeMap::from([
            ("tool_count".to_string(), total_calls.to_string()),
            ("tools_used".to_string(), tool_names),
            ("input_tokens".to_string(), self.input_tokens.to_string()),
            ("output_tokens".to_string(), self.output_tokens.to_string()),
            (
                "cache_creation_tokens".to_string(),
                self.cache_creation_tokens.to_string(),
            ),
            (
                "cache_read_tokens".to_string(),
                self.cache_read_tokens.to_string(),
            ),
            ("total_tokens".to_string(), self.total_tokens().to_string()),
            (
                "total_billable_tokens".to_string(),
                self.total_billable_tokens().to_string(),
            ),
            (
                "reasoning_output_tokens".to_string(),
                self.reasoning_output_tokens.to_string(),
            ),
            ("files_touched".to_string(), unique_files.len().to_string()),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Tool recording

    #[test]
    fn record_tool_use_increments_count() {
        let mut stats = TurnStats::new();
        stats.record_tool_use("Write", Some("/tmp/a.swift"));
        stats.record_tool_use("Write", Some("/tmp/b.swift"));
        stats.record_tool_use("Read", None);

        assert_eq!(stats.tool_tallies()["Write"].count, 2);
        assert_eq!(stats.tool_tallies()["Read"].count, 1);
    }

    #[test]
    fn record_tool_use_deduplicates_files() {
        let mut stats = TurnStats::new();
        stats.record_tool_use("Edit", Some("/tmp/x.swift"));
        stats.record_tool_use("Edit", Some("/tmp/x.swift"));
        stats.record_tool_use("Edit", Some("/tmp/y.swift"));

        let tally = &stats.tool_tallies()["Edit"];
        assert_eq!(tally.count, 3);
        assert_eq!(tally.files, ["/tmp/x.swift", "/tmp/y.swift"]);
    }

    #[test]
    fn record_tool_use_ignores_empty_file() {
        let mut stats = TurnStats::new();
        stats.record_tool_use("Bash", Some(""));
        stats.record_tool_use("Bash", None);

        assert_eq!(stats.tool_tallies()["Bash"].count, 2);
        assert!(stats.tool_tallies()["Bash"].files.is_empty());
    }

    // MARK: Token accumulation

    #[test]
    fn add_tokens_cumulative_accumulation() {
        let mut stats = TurnStats::new();
        stats.add_tokens(100, 50, 10, 20);
        stats.add_tokens(200, 100, 5, 15);

        assert_eq!(stats.input_tokens(), 300);
        assert_eq!(stats.output_tokens(), 150);
        assert_eq!(stats.cache_creation_tokens(), 15);
        assert_eq!(stats.cache_read_tokens(), 35);
        assert_eq!(stats.total_tokens(), 450); // input + output
        assert_eq!(
            stats.token_usage(),
            TokenUsage::canonical(300, 50, 15, 35, 150, 0)
        );
    }

    // MARK: Summary

    #[test]
    fn summary_contains_all_expected_keys() {
        let mut stats = TurnStats::new();
        stats.record_tool_use("Write", Some("/a.swift"));
        stats.record_tool_use("Read", None);
        stats.add_tokens(1000, 500, 100, 200);

        let summary = stats.summary();

        assert_eq!(summary["tool_count"], "2");
        assert_eq!(summary["input_tokens"], "1000");
        assert_eq!(summary["output_tokens"], "500");
        assert_eq!(summary["cache_creation_tokens"], "100");
        assert_eq!(summary["cache_read_tokens"], "200");
        assert_eq!(summary["total_tokens"], "1500");
        assert_eq!(summary["files_touched"], "1");

        // tools_used is sorted, comma-separated
        let tools = &summary["tools_used"];
        assert!(tools.contains("Read"));
        assert!(tools.contains("Write"));
        assert_eq!(tools, "Read,Write");
    }

    #[test]
    fn summary_empty_stats() {
        let stats = TurnStats::new();
        let summary = stats.summary();

        assert_eq!(summary["tool_count"], "0");
        assert_eq!(summary["tools_used"], "");
        assert_eq!(summary["total_tokens"], "0");
        assert_eq!(summary["files_touched"], "0");
    }

    // MARK: Fresh state

    #[test]
    fn fresh_stats_all_zero() {
        let stats = TurnStats::new();
        assert!(stats.tool_tallies().is_empty());
        assert_eq!(stats.input_tokens(), 0);
        assert_eq!(stats.output_tokens(), 0);
        assert_eq!(stats.cache_creation_tokens(), 0);
        assert_eq!(stats.cache_read_tokens(), 0);
        assert_eq!(stats.total_tokens(), 0);
    }

    #[test]
    fn json_keys_match_swift_codable() {
        let mut stats = TurnStats::new();
        stats.add_tokens(1, 2, 3, 4);
        let json = serde_json::to_value(&stats).unwrap();
        assert_eq!(json["inputTokens"], 1);
        assert_eq!(json["cacheCreationTokens"], 3);
        assert!(json["toolTallies"].is_object());
    }
}

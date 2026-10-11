//! Pricing snapshot copied from current Swift ModelPricingTable (2026-04-13).
//! An estimate with versioned provenance, not an observed bill.
use super::token_metrics::TokenUsage;
pub const VERSION: &str = "2026-04-13";
#[derive(Debug, Clone, Copy)]
pub struct ModelPricing {
    pub input: f64,
    pub write: f64,
    pub read: f64,
    pub output: f64,
    pub reasoning: f64,
}
impl ModelPricing {
    pub fn estimate(self, u: &TokenUsage) -> f64 {
        (u.input_tokens as f64 * self.input
            + u.cache_creation_input_tokens as f64 * self.write
            + (u.cache_read_input_tokens + u.uncategorized_cache()) as f64 * self.read
            + u.output_tokens as f64 * self.output
            + u.reasoning_output_tokens as f64 * self.reasoning)
            / 1_000_000.
    }
}
const ENTRIES: &[(&[&str], ModelPricing)] = &[
    (
        &["gpt-5.4", "gpt-5.4-chat-latest"],
        ModelPricing {
            input: 2.50,
            write: 2.50,
            read: 0.25,
            output: 15.00,
            reasoning: 15.00,
        },
    ),
    (
        &["gpt-5.4-mini"],
        ModelPricing {
            input: 0.75,
            write: 0.75,
            read: 0.075,
            output: 4.50,
            reasoning: 4.50,
        },
    ),
    (
        &["gpt-5.4-nano"],
        ModelPricing {
            input: 0.20,
            write: 0.20,
            read: 0.02,
            output: 1.25,
            reasoning: 1.25,
        },
    ),
    (
        &["gpt-5.3-codex", "gpt-5.2-codex"],
        ModelPricing {
            input: 1.75,
            write: 1.75,
            read: 0.175,
            output: 14.00,
            reasoning: 14.00,
        },
    ),
    (
        &["gpt-5.1-codex", "gpt-5-codex", "codex-mini-latest"],
        ModelPricing {
            input: 1.25,
            write: 1.25,
            read: 0.125,
            output: 10.00,
            reasoning: 10.00,
        },
    ),
    (
        &["gpt-5.2", "gpt-5.2-chat-latest"],
        ModelPricing {
            input: 1.75,
            write: 1.75,
            read: 0.175,
            output: 14.00,
            reasoning: 14.00,
        },
    ),
    (
        &[
            "gpt-5.1",
            "gpt-5.1-chat-latest",
            "gpt-5",
            "gpt-5-chat-latest",
        ],
        ModelPricing {
            input: 1.25,
            write: 1.25,
            read: 0.125,
            output: 10.00,
            reasoning: 10.00,
        },
    ),
    (
        &["gpt-5-mini"],
        ModelPricing {
            input: 0.25,
            write: 0.25,
            read: 0.025,
            output: 2.00,
            reasoning: 2.00,
        },
    ),
    (
        &["gpt-5-nano"],
        ModelPricing {
            input: 0.05,
            write: 0.05,
            read: 0.005,
            output: 0.40,
            reasoning: 0.40,
        },
    ),
    (
        &["claude-opus-4.1", "claude-opus-4", "claude-opus-3"],
        ModelPricing {
            input: 15.00,
            write: 18.75,
            read: 1.50,
            output: 75.00,
            reasoning: 75.00,
        },
    ),
    (
        &["claude-sonnet-4", "claude-sonnet-3.7", "claude-sonnet-3.5"],
        ModelPricing {
            input: 3.00,
            write: 3.75,
            read: 0.30,
            output: 15.00,
            reasoning: 15.00,
        },
    ),
    (
        &["claude-haiku-3.5"],
        ModelPricing {
            input: 0.80,
            write: 1.00,
            read: 0.08,
            output: 4.00,
            reasoning: 4.00,
        },
    ),
    (
        &["claude-haiku-3"],
        ModelPricing {
            input: 0.25,
            write: 0.30,
            read: 0.03,
            output: 1.25,
            reasoning: 1.25,
        },
    ),
    (
        &["gemini-2.5-pro"],
        ModelPricing {
            input: 1.25,
            write: 0.125,
            read: 0.125,
            output: 10.00,
            reasoning: 10.00,
        },
    ),
    (
        &["gemini-2.5-flash", "gemini-2.5-flash-preview-09-2025"],
        ModelPricing {
            input: 0.30,
            write: 0.03,
            read: 0.03,
            output: 2.50,
            reasoning: 2.50,
        },
    ),
    (
        &[
            "gemini-2.5-flash-lite",
            "gemini-2.5-flash-lite-preview-09-2025",
        ],
        ModelPricing {
            input: 0.10,
            write: 0.01,
            read: 0.01,
            output: 0.40,
            reasoning: 0.40,
        },
    ),
];
pub fn pricing(model: Option<&str>, provider: Option<&str>) -> Option<ModelPricing> {
    let raw = model
        .filter(|m| !m.trim().is_empty())
        .or(provider)?
        .trim()
        .to_ascii_lowercase();
    let model = match raw.as_str() {
        "claude" | "anthropic" => "claude-sonnet-4",
        "codex" | "openai" | "gpt" => "gpt-5.3-codex",
        "gemini" | "google" => "gemini-2.5-flash",
        _ => &raw,
    };
    if let Some((_, p)) = ENTRIES.iter().find(|(a, _)| a.contains(&model)) {
        return Some(*p);
    }
    const RULES: &[(&str, &str)] = &[
        ("gpt-5.4-mini", "gpt-5.4-mini"),
        ("gpt-5.4-nano", "gpt-5.4-nano"),
        ("gpt-5.4", "gpt-5.4"),
        ("gpt-5.3-codex", "gpt-5.3-codex"),
        ("gpt-5.2-codex", "gpt-5.3-codex"),
        ("gpt-5.1-codex", "gpt-5.1-codex"),
        ("gpt-5-codex", "gpt-5.1-codex"),
        ("gpt-5.2", "gpt-5.2"),
        ("gpt-5.1", "gpt-5.1"),
        ("gpt-5-mini", "gpt-5-mini"),
        ("gpt-5-nano", "gpt-5-nano"),
        ("claude-opus", "claude-opus-4.1"),
        ("claude-sonnet", "claude-sonnet-4"),
        ("claude-haiku", "claude-haiku-3.5"),
        ("gemini-2.5-pro", "gemini-2.5-pro"),
        ("gemini-2.5-flash-lite", "gemini-2.5-flash-lite"),
        ("gemini-2.5-flash", "gemini-2.5-flash"),
    ];
    let (_, canonical) = RULES
        .iter()
        .filter(|(prefix, _)| model.starts_with(prefix))
        .max_by_key(|(prefix, _)| prefix.len())?;
    pricing(Some(canonical), None)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn longest_prefix_and_separate_caches() {
        assert_eq!(
            pricing(Some("gpt-5.4-mini-2026"), None).unwrap().input,
            0.75
        );
        let u = TokenUsage::provider(
            "anthropic",
            Some(100),
            Some(200),
            Some(30),
            Some(40),
            Some(10),
        );
        let p = pricing(Some("claude-sonnet-4"), None).unwrap();
        assert!((p.estimate(&u) - 0.0035745).abs() < 0.00000001);
        assert!(pricing(Some("unknown"), None).is_none());
    }
}

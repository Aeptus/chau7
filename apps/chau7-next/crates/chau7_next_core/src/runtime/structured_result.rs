//! Structured output extraction and the same JSON schema subset as Swift.
use super::delegated_task::{TurnResult, TurnResultStatus};
use serde_json::Value;

pub fn validate(value: &Value, schema: &Value) -> Vec<String> {
    if !schema.is_object() {
        return vec!["Schema must be a JSON object.".into()];
    }
    let mut errors = Vec::new();
    validate_at(value, schema, "$", &mut errors);
    errors
}
fn validate_at(value: &Value, schema: &Value, path: &str, errors: &mut Vec<String>) {
    if errors.len() >= 256 {
        return;
    }
    if let Some(kind) = schema["type"].as_str() {
        let matches = match kind {
            "object" => value.is_object(),
            "array" => value.is_array(),
            "string" => value.is_string(),
            "number" => value.is_number(),
            "integer" => {
                value.as_i64().is_some()
                    || value.as_u64().is_some()
                    || value.as_f64().is_some_and(|v| v.fract() == 0.0)
            }
            "boolean" => value.is_boolean(),
            "null" => value.is_null(),
            _ => true,
        };
        if !matches {
            errors.push(format!("{path} expected {kind}"));
            return;
        }
    }
    if let Some(options) = schema["enum"].as_array()
        && !options.contains(value)
    {
        errors.push(format!("{path} must match enum"));
    }
    if let Some(object) = value.as_object() {
        if let Some(required) = schema["required"].as_array() {
            for key in required.iter().filter_map(Value::as_str) {
                if !object.contains_key(key) {
                    errors.push(format!("{path}.{key} is required"));
                }
            }
        }
        for (key, child) in object {
            if let Some(child_schema) = schema["properties"].get(key).filter(|s| s.is_object()) {
                validate_at(child, child_schema, &format!("{path}.{key}"), errors);
            } else if schema["additionalProperties"] == false {
                errors.push(format!("{path}.{key} is not allowed"));
            }
        }
    } else if let Some(array) = value.as_array()
        && schema["items"].is_object()
    {
        for (index, child) in array.iter().enumerate() {
            validate_at(child, &schema["items"], &format!("{path}[{index}]"), errors);
        }
    }
}
pub fn capture(
    session: &str,
    turn: &str,
    summary: Option<&str>,
    output: Option<&str>,
    schema: Option<&Value>,
) -> Option<TurnResult> {
    for (prefix, text) in [("summary", summary), ("output", output)] {
        let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
            continue;
        };
        static PATTERN: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
            regex::Regex::new(r"(?is)```(?:json)?\s*([\s\S]*?)```").expect("static pattern")
        });
        let pattern = &*PATTERN;
        let mut candidates: Vec<_> = pattern
            .captures_iter(text)
            .filter_map(|c| {
                c.get(1)
                    .map(|m| (format!("{prefix}_json_fence"), m.as_str().trim()))
            })
            .collect();
        candidates.reverse();
        if text.starts_with(['{', '[']) {
            candidates.push((format!("{prefix}_raw_json"), text));
        }
        for (source, raw) in candidates {
            if let Ok(value) = serde_json::from_str::<Value>(raw) {
                let errors = schema
                    .map(|schema| validate(&value, schema))
                    .unwrap_or_default();
                return Some(TurnResult {
                    session_id: session.into(),
                    turn_id: turn.into(),
                    status: if errors.is_empty() {
                        TurnResultStatus::Available
                    } else {
                        TurnResultStatus::Invalid
                    },
                    source,
                    captured_at: crate::telemetry::date_codec::format_iso8601_fractional(
                        &chrono::Utc::now(),
                    ),
                    schema: schema.cloned(),
                    value: Some(value),
                    validation_errors: errors,
                    raw_text: Some(raw.chars().take(65536).collect()),
                });
            }
        }
    }
    schema.map(|schema| TurnResult {
        session_id: session.into(),
        turn_id: turn.into(),
        status: TurnResultStatus::Missing,
        source: "missing".into(),
        captured_at: crate::telemetry::date_codec::format_iso8601_fractional(&chrono::Utc::now()),
        schema: Some(schema.clone()),
        value: None,
        validation_errors: vec![
            "No structured JSON result matching the requested schema was found.".into(),
        ],
        raw_text: summary
            .or(output)
            .map(|s| s.trim().chars().take(65536).collect()),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn last_json_fence_wins_and_schema_validates_nested_values() {
        let schema = json!({"type":"object","required":["count"],"properties":{"count":{"type":"integer"}},"additionalProperties":false});
        let result = capture(
            "rs",
            "t",
            Some("```json\n{}\n```\n```JSON\n{\"count\":2}\n```"),
            None,
            Some(&schema),
        )
        .unwrap();
        assert_eq!(result.status, TurnResultStatus::Available);
        assert_eq!(result.value.unwrap()["count"], 2);
        assert_eq!(
            capture("rs", "t", Some("{}"), None, Some(&schema))
                .unwrap()
                .status,
            TurnResultStatus::Invalid
        );
        assert_eq!(
            capture("rs", "t", Some("no JSON"), None, Some(&schema))
                .unwrap()
                .status,
            TurnResultStatus::Missing
        );
        assert!(capture("rs", "t", Some("no JSON"), None, None).is_none());
        assert!(!validate(&json!({"count":2,"extra":1}), &schema).is_empty());
    }
}

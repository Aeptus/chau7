//! Pretty-print a JSON string.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/JSONPrettyPrinter.swift`: returns
//! `None` unless the trimmed text starts with `{` or `[` and parses as JSON.
//! The output follows Foundation's `JSONSerialization` with `.prettyPrinted`
//! and `.sortedKeys`: two-space indent, `"key" : value` (space before the
//! colon), `{}` and `[]` for empty containers, keys in sorted order and `/`
//! escaped as `\/`.

use crate::escape_sanitizer::trim_whitespaces_and_newlines;
use serde_json::Value;
use std::fmt::Write;

/// Pretty-print `text` when it is a JSON object or array, otherwise `None`.
pub fn pretty_print(text: &str) -> Option<String> {
    let trimmed = trim_whitespaces_and_newlines(text);
    if !(trimmed.starts_with('{') || trimmed.starts_with('[')) {
        return None;
    }
    let value: Value = serde_json::from_str(trimmed).ok()?;
    let mut out = String::new();
    write_value(&value, 0, &mut out);
    Some(out)
}

fn indent(level: usize, out: &mut String) {
    for _ in 0..level {
        out.push_str("  ");
    }
}

fn write_value(value: &Value, level: usize, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => match n.as_f64() {
            // Foundation prints a whole double such as 1.0 as `1`.
            Some(f) if n.is_f64() && f.fract() == 0.0 && f.abs() < 1e15 => {
                let _ = write!(out, "{}", f as i64);
            }
            _ => {
                let _ = write!(out, "{n}");
            }
        },
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                indent(level + 1, out);
                write_value(item, level + 1, out);
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(level, out);
            out.push(']');
        }
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push_str("{\n");
            for (i, key) in keys.iter().enumerate() {
                indent(level + 1, out);
                write_string(key, out);
                out.push_str(" : ");
                write_value(&map[key.as_str()], level + 1, out);
                if i + 1 < keys.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(level, out);
            out.push('}');
        }
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' => out.push_str("\\/"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pretty_print_simple_object() {
        let result = pretty_print(r#"{"name":"Alice","age":30}"#).unwrap();
        assert!(result.contains("\"age\""));
        assert!(result.contains("\"name\""));
        assert!(result.contains('\n'));
    }

    #[test]
    fn pretty_print_array() {
        let result = pretty_print("[1,2,3]").unwrap();
        assert!(result.contains('\n'));
    }

    #[test]
    fn pretty_print_nested_object() {
        let result = pretty_print(r#"{"outer":{"inner":"value"}}"#).unwrap();
        assert!(result.contains("inner"));
        assert!(result.contains("outer"));
    }

    #[test]
    fn pretty_print_sorts_keys() {
        let result = pretty_print(r#"{"zebra":1,"apple":2,"mango":3}"#).unwrap();
        let apple = result.find("apple").unwrap();
        let mango = result.find("mango").unwrap();
        let zebra = result.find("zebra").unwrap();
        assert!(apple < mango);
        assert!(mango < zebra);
    }

    #[test]
    fn pretty_print_empty_object() {
        assert_eq!(pretty_print("{}").as_deref(), Some("{}"));
    }

    #[test]
    fn pretty_print_empty_array() {
        assert_eq!(pretty_print("[]").as_deref(), Some("[]"));
    }

    #[test]
    fn pretty_print_with_whitespace() {
        assert!(pretty_print("   {\"key\":\"value\"}   ").is_some());
    }

    #[test]
    fn pretty_print_round_trip() {
        let input = r#"{"a":1,"b":"hello","c":[1,2,3],"d":true,"e":null}"#;
        let pretty = pretty_print(input).unwrap();
        let double = pretty_print(&pretty).unwrap();
        assert_eq!(pretty, double);
    }

    #[test]
    fn pretty_print_not_json() {
        assert_eq!(pretty_print("hello world"), None);
    }

    #[test]
    fn pretty_print_empty_string() {
        assert_eq!(pretty_print(""), None);
    }

    #[test]
    fn pretty_print_only_whitespace() {
        assert_eq!(pretty_print("   "), None);
    }

    #[test]
    fn pretty_print_malformed_json() {
        assert_eq!(pretty_print("{broken"), None);
    }

    #[test]
    fn pretty_print_number() {
        assert_eq!(pretty_print("42"), None);
    }

    #[test]
    fn pretty_print_boolean_string() {
        assert_eq!(pretty_print("true"), None);
    }

    #[test]
    fn pretty_print_string() {
        assert_eq!(pretty_print("\"hello\""), None);
    }

    // Branch without a Swift test: the exact layout.

    #[test]
    fn layout_matches_foundation_pretty_printing() {
        let result = pretty_print(r#"{"b":[1,{"x":"a/b"}],"a":{}}"#).unwrap();
        let expected =
            "{\n  \"a\" : {},\n  \"b\" : [\n    1,\n    {\n      \"x\" : \"a\\/b\"\n    }\n  ]\n}";
        assert_eq!(result, expected);
    }
}

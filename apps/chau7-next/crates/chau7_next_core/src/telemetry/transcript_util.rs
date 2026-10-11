//! Helpers shared by the transcript parsers, mirroring how the Swift code
//! reads `JSONSerialization` output.

use serde_json::Value;

/// `text.components(separatedBy: .newlines)`: splits on every character of
/// `CharacterSet.newlines` (LF, VT, FF, CR, NEL, LS, PS). Empty pieces are
/// kept; callers filter them like the Swift `where !line.isEmpty`.
pub(crate) fn split_newlines(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| {
        matches!(
            c,
            '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
    })
}

/// `value as? Int` on a JSON number: integers, and doubles with no fraction.
pub(crate) fn as_int(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    if let Some(i) = number.as_i64() {
        return Some(i);
    }
    let f = number.as_f64()?;
    if f.fract() == 0.0 && (-9.2e18..=9.2e18).contains(&f) {
        Some(f as i64)
    } else {
        None
    }
}

/// `value as? String`.
pub(crate) fn as_string(value: Option<&Value>) -> Option<String> {
    value?.as_str().map(str::to_string)
}

/// `value as? [[String: Any]]`: an array whose elements are all objects.
pub(crate) fn as_object_array(
    value: Option<&Value>,
) -> Option<Vec<&serde_json::Map<String, Value>>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

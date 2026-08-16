//! Tolerant JSON access + the display flattening the tool cards render.
//!
//! Swift modelled this as its own `JSONValue` enum because Foundation has no usable dynamic JSON
//! tree. Rust has one — [`serde_json::Value`] — so this module is ACCESSORS ONLY: the value type
//! itself is serde's, which is also what keeps the encode side byte-compatible for free (a
//! `tool_use.input` decoded here and re-encoded onto the wire is the same JSON the transcript
//! held).
//!
//! The one thing that had to be ported rather than inherited is [`display_string`], because its
//! output is USER-VISIBLE text in a shipped client: sorted object keys (Swift's dictionary
//! iteration order is hash-seed-randomized per process, so the Swift original sorts and so must
//! this), and whole floats rendered without a trailing `.0`.

use serde_json::Value;

/// The `f64` magnitude past which a whole number is no longer exactly representable as an integer,
/// so rendering it through `i64` would lie. Mirrors the Swift original's `abs(value) < 1e15` guard.
const INTEGRAL_RENDER_LIMIT: f64 = 1e15;

/// A human-readable flattening for display: text blocks joined by newlines, scalars stringified,
/// objects rendered `key: value` with the keys SORTED.
///
/// Used to render a tool result whose `content` is not a plain string, and as the fallback for a
/// content block carrying no `text` key — where rendering an arbitrary field (whichever the hash
/// order happened to yield) surfaced a different, often less informative, value on each run.
#[must_use]
pub fn display_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(flag) => if *flag { "true" } else { "false" }.to_owned(),
        Value::Number(number) => render_number(number),
        Value::String(text) => text.clone(),
        Value::Array(items) => items.iter().map(display_string).collect::<Vec<_>>().join("\n"),
        Value::Object(map) => {
            // `serde_json::Map` is insertion-ordered by default (not `preserve_order`), so the keys
            // must be sorted HERE to match the Swift original's `sorted { $0.key < $1.key }`.
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_unstable();
            keys.iter()
                .filter_map(|key| {
                    map.get(*key)
                        .map(|nested| format!("{key}: {}", display_string(nested)))
                })
                .collect::<Vec<_>>()
                .join("\n")
        },
    }
}

/// Renders a JSON number the way the Swift original did — which decoded EVERY number as a `Double`
/// and then printed a whole one without its `.0`. serde keeps the integer types apart, so an
/// integer already prints correctly; only the float case needs the whole-number check.
fn render_number(number: &serde_json::Number) -> String {
    number.as_f64().map_or_else(
        || number.to_string(),
        |float| {
            if number.is_f64() && float.fract() == 0.0 && float.abs() < INTEGRAL_RENDER_LIMIT {
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "guarded above: whole, and below 1e15 — inside i64's exact range"
                )]
                let integral = float as i64;
                integral.to_string()
            } else {
                number.to_string()
            }
        },
    )
}

/// The string at `key` of an object, or `None` for a missing key / a non-object / a non-string.
#[must_use]
pub fn string_at<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// The string at the FIRST of `keys` that yields one.
///
/// Claude Code spells the same field both `snake_case` and `camelCase` depending on the producer
/// and the version, and reading both is the schema-evolution valve the whole parser is built
/// around.
#[must_use]
pub fn string_at_any<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| string_at(value, key))
}

/// A JSON `true`/`false` at `key`; `false` for anything else.
///
/// "Anything else" INCLUDES the string `"true"`, which a producer that stringifies its payload
/// would send. Guessing at that was rejected in Swift and stays rejected here: the tolerant reading
/// is per-field and explicit, never type-coercing.
#[must_use]
pub fn bool_at(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// `None` for an empty string — folds `""` back to absence so optional text stays absent rather
/// than becoming an empty string that renders as a blank message bubble.
#[must_use]
pub fn non_empty(text: &str) -> Option<String> {
    if text.is_empty() {
        None
    } else {
        Some(text.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{bool_at, display_string, non_empty, string_at_any};

    #[test]
    fn whole_floats_render_without_a_trailing_point_zero() {
        assert_eq!(display_string(&json!(3.0)), "3");
        assert_eq!(display_string(&json!(3)), "3");
        assert_eq!(display_string(&json!(-0.5)), "-0.5");
    }

    #[test]
    fn a_float_too_large_for_an_exact_integer_keeps_its_own_rendering() {
        assert_eq!(display_string(&json!(1e16)), "1e+16");
    }

    #[test]
    fn object_keys_render_sorted() {
        let value = json!({"zeta": 1, "alpha": "a", "mid": true});
        assert_eq!(display_string(&value), "alpha: a\nmid: true\nzeta: 1");
    }

    #[test]
    fn arrays_join_on_newlines_and_null_renders_empty() {
        assert_eq!(display_string(&json!(["a", "b"])), "a\nb");
        assert_eq!(display_string(&json!(null)), "");
    }

    #[test]
    fn a_stringified_bool_is_not_coerced() {
        assert!(!bool_at(&json!({"is_error": "true"}), "is_error"));
        assert!(bool_at(&json!({"is_error": true}), "is_error"));
    }

    #[test]
    fn the_first_spelling_that_exists_wins() {
        let value = json!({"parentUuid": "p"});
        assert_eq!(string_at_any(&value, &["parentUuid", "parentUUID"]), Some("p"));
        assert_eq!(string_at_any(&value, &["missing"]), None);
    }

    #[test]
    fn empty_text_folds_to_absence() {
        assert_eq!(non_empty(""), None);
        assert_eq!(non_empty("x"), Some("x".to_owned()));
    }
}

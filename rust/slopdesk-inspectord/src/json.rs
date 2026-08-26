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
//!
//! ## There WAS a second flattening, and this is why it is gone
//!
//! The client held one of its own — a `JSONValue.displayString` over a tolerant JSON tree it
//! modelled itself — and the two were LIVE at once in two processes: this one rendered a tool
//! RESULT's content, that one a pending tool's INPUT. They never saw the same value, which is
//! precisely why nothing ever noticed that they answered differently.
//!
//! The cause was one line neither function contained. That tree's decoder made every JSON number a
//! `Double`, while serde keeps the integer types apart — so the divergence was in the VALUE TYPE,
//! not in the rendering, and the rendering below merely declines to throw away what it was given:
//!
//! | JSON | this module | the deleted Swift flattening |
//! | --- | --- | --- |
//! | `10000000000000000` | `10000000000000000` | `1e+16` |
//! | `9007199254740993` | `9007199254740993` | `9.007199254740992e+15` (lost at decode) |
//! | `18446744073709551615` | `18446744073709551615` | `1.8446744073709552e+19` |
//! | `{"é": …, "z": …}` | `é` first (raw UTF-8 order) | `z` first for a DECOMPOSED `é` |
//!
//! The note used to end "the obligation is a differential rather than a deletion", because the
//! Swift half could not be made to match without changing what its number type IS.
//! [`crate::tool_render`] made that change from the other end: the client asks for a card's
//! rendering with the input's RAW JSON, so serde sees the integer the transcript held and the tree
//! is gone from that side altogether. The tests below still assert the left-hand column, which is
//! now simply THE column.

use serde_json::Value;

/// The `f64` magnitude past which a whole number is no longer exactly representable as an integer,
/// so rendering it through `i64` would lie.
///
/// The same `1e15` the Swift flattening uses — but only the GUARD is shared. Swift applies it to
/// every number because every number reached it as an `f64`; here it gates the float arm alone, and
/// an integer sails past it exact. See the module note for the four inputs that separates.
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
            // must be sorted HERE — the point of sorting at all is that a rendering must not depend
            // on which order a producer happened to write its fields in.
            //
            // The order is raw UTF-8, which agrees with the Swift flattening's `String.<` on ASCII
            // keys and NOT on anything above it: Swift compares canonically, so a decomposed `é`
            // sorts after `z` there and before it here. Tool payload keys are ASCII identifiers in
            // practice, which is why this has never shown; it is in the module note's table rather
            // than fixed, because "fix" would mean one of the two adopting the other's collation and
            // neither is reachable from the other's process.
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

/// Renders a JSON number: a whole float without its `.0`, everything else as serde spells it.
///
/// The `is_f64()` guard is what makes this DIFFER from `JSONValue.displayString` rather than mirror
/// it, and the difference is deliberate. Swift's flattening had already lost an integer's identity
/// by the time it ran — its value type decodes every number to `Double` — so it re-derives one
/// through `i64` and gives up past `1e15`. serde still knows, so an integer takes the `to_string`
/// arm and prints exactly, at any width. See the module note for the inputs where the two answers
/// separate and why this one is the right of the two.
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

    /// An INTEGER past `f64`'s exact range prints exactly, which is the row of the module note's
    /// table `JSONValue.displayString` gets wrong — it would answer `1e+16`,
    /// `9.007199254740992e+15` and `1.8446744073709552e+19` for these three, having decoded
    /// each to a `Double` before the flattening ever ran.
    ///
    /// Pinned rather than described, because the divergence is not something either side can fail
    /// on: the two functions render different halves of a tool card and no input reaches both. The
    /// note above it is a claim about another language, and docs/55 §8's last bullet is about
    /// exactly how those go stale. This is the assertion behind it.
    #[test]
    fn an_integer_past_the_float_range_prints_exactly_rather_than_in_scientific_form() {
        assert_eq!(
            display_string(&json!(10_000_000_000_000_000_i64)),
            "10000000000000000"
        );
        assert_eq!(
            display_string(&json!(9_007_199_254_740_993_i64)),
            "9007199254740993"
        );
        assert_eq!(display_string(&json!(u64::MAX)), "18446744073709551615");
        // And the guard still applies where it must: a genuine float that large cannot be re-derived
        // through `i64` without lying about its low digits, so it keeps serde's own spelling.
        assert_eq!(display_string(&json!(1e16_f64)), "1e+16");
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

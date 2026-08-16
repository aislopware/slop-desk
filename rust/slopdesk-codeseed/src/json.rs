//! The two JSON habits every file in this program shares.
//!
//! Both exist because the files here are written by TWO programs — this one and the workbench —
//! so "did this change?" can never be a byte comparison of two spellings of the same object.

use serde_json::{Number, Value};

/// Sorted-keys canonical JSON for `text`, or `None` when it is not JSON at all.
///
/// The canonical form is what every drift check compares: a file the workbench rewrote with
/// different key order, indentation or spacing is the SAME file as far as this program is
/// concerned, and rewriting it would churn a watcher for nothing.
#[must_use]
pub fn canonical(text: &str) -> Option<String> {
    let value: Value = serde_json::from_str(text).ok()?;
    serde_json::to_string(&value).ok()
}

/// A number that SERIALIZES the way a human wrote it.
///
/// A raw `f64` prints round-trip noise (`1.58` → `1.5800000000000001`) and a whole value prints as
/// `14.0` — in a settings file the user opens, and has screenshotted. An integral value becomes an
/// integer and everything else keeps the shortest round-trip form, so the file reads `14` and
/// `1.58`. A non-finite value (which no decoder should ever produce) becomes `0` rather than
/// `null`: the workbench rejects a null here, and rejecting the WHOLE object over one key is worse
/// than a value the next sync overwrites.
#[must_use]
pub fn readable_number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "guarded above: integral, and inside the range an f64 represents exactly"
        )]
        return Value::Number(Number::from(value as i64));
    }
    Number::from_f64(value).map_or_else(|| Value::Number(Number::from(0)), Value::Number)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_sees_through_key_order_and_whitespace() {
        let a = canonical(r#"{ "b": 1,  "a": [2, 3] }"#);
        let b = canonical("{\n  \"a\": [2, 3],\n  \"b\": 1\n}");
        assert_eq!(a, b);
        assert_eq!(a.as_deref(), Some(r#"{"a":[2,3],"b":1}"#));
    }

    #[test]
    fn canonical_refuses_what_is_not_json() {
        assert_eq!(canonical("// a comment\n{}"), None);
        assert_eq!(canonical(""), None);
    }

    #[test]
    fn canonical_does_not_escape_slashes() {
        assert_eq!(
            canonical(r#"{"p":"./themes/a.json"}"#).as_deref(),
            Some(r#"{"p":"./themes/a.json"}"#)
        );
    }

    #[test]
    fn an_integral_size_reads_as_an_integer() {
        assert_eq!(readable_number(14.0).to_string(), "14");
        assert_eq!(readable_number(-3.0).to_string(), "-3");
    }

    #[test]
    fn a_fractional_ratio_keeps_its_shortest_round_trip() {
        assert_eq!(readable_number(1.58).to_string(), "1.58");
        assert_eq!(readable_number(1.32).to_string(), "1.32");
    }

    #[test]
    fn a_non_finite_value_becomes_zero_rather_than_null() {
        assert_eq!(readable_number(f64::NAN).to_string(), "0");
        assert_eq!(readable_number(f64::INFINITY).to_string(), "0");
    }
}

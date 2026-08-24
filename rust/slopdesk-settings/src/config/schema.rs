//! The JSON Schema for `config.toml`, written out of the same table the app reads.
//!
//! A schema is what makes a file-only settings system usable: the editor completes the key, shows
//! the sentence, offers the tokens and underlines a value outside its range — which is every
//! affordance a settings window had except the window. It is generated rather than maintained,
//! because a hand-written schema is a second declaration of the same keys and would drift the day
//! somebody added one.
//!
//! Draft 2020-12, `additionalProperties: false` at every level, so a typo is an error where the
//! user typed it rather than a key that silently does nothing.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::config::table::{KEYS, Kind};
use crate::config::{ENV_SECTION, KEYBIND_SECTION, quoted};

/// Where the schema is published, and the `$id` a config file points at.
pub const SCHEMA_ID: &str = "https://slopdesk.dev/schema/config.schema.json";

/// The whole schema, pretty-printed with two-space indentation and a trailing newline.
///
/// Deterministic to the byte: sections and keys are emitted in table order, so a diff of two builds
/// is a diff of the table. That is what lets the checked-in copy be gated by a staleness test
/// rather than by a reviewer noticing.
#[must_use]
pub fn json_schema() -> String {
    let mut sections: BTreeMap<&str, Vec<(&str, &Kind, &str)>> = BTreeMap::new();
    let mut order: Vec<&str> = Vec::new();
    for declared in KEYS {
        let (section, leaf) = split(declared.path);
        if !order.contains(&section) {
            order.push(section);
        }
        sections
            .entry(section)
            .or_default()
            .push((leaf, &declared.kind, declared.doc));
    }

    let mut out = String::new();
    out.push_str("{\n");
    let _ = writeln!(
        out,
        "  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\","
    );
    let _ = writeln!(out, "  \"$id\": {},", quoted(SCHEMA_ID));
    let _ = writeln!(out, "  \"title\": \"slopdesk configuration\",");
    let _ = writeln!(
        out,
        "  \"description\": {},",
        quoted(
            "Every setting slopdesk understands. Everything has a best-by-default answer; a key is only \
             written here to disagree with it."
        )
    );
    let _ = writeln!(out, "  \"type\": \"object\",");
    let _ = writeln!(out, "  \"additionalProperties\": false,");
    out.push_str("  \"properties\": {\n");
    for (index, section) in order.iter().enumerate() {
        let leaves = sections.get(section).map_or(&[][..], Vec::as_slice);
        write_section(&mut out, section, leaves);
        if index + 1 < order.len() {
            out.push(',');
        }
        out.push('\n');
    }
    out.pop();
    out.push_str(",\n");
    write_open_table(
        &mut out,
        KEYBIND_SECTION,
        "Chord to action, one per line: \"cmd+t\" = \"new-tab\".",
    );
    out.push_str(",\n");
    write_open_table(
        &mut out,
        ENV_SECTION,
        "Raw SLOPDESK_* overrides, applied last and above every typed key above.",
    );
    out.push('\n');
    out.push_str("  }\n}\n");
    out
}

/// One `[section]` as a schema object.
fn write_section(out: &mut String, section: &str, leaves: &[(&str, &Kind, &str)]) {
    let _ = writeln!(out, "    {}: {{", quoted(section));
    let _ = writeln!(out, "      \"type\": \"object\",");
    let _ = writeln!(out, "      \"additionalProperties\": false,");
    let _ = writeln!(out, "      \"properties\": {{");
    for (index, (leaf, kind, doc)) in leaves.iter().enumerate() {
        let _ = writeln!(out, "        {}: {{", quoted(leaf));
        let _ = writeln!(out, "          \"description\": {},", quoted(doc));
        write_kind(out, kind);
        let _ = write!(out, "        }}");
        if index + 1 < leaves.len() {
            out.push(',');
        }
        out.push('\n');
    }
    let _ = writeln!(out, "      }}");
    let _ = write!(out, "    }}");
}

/// The type, domain and default of one key.
fn write_kind(out: &mut String, kind: &Kind) {
    match *kind {
        Kind::Flag { default } => {
            let _ = write!(out, "          \"type\": \"boolean\"");
            if let Some(value) = default {
                let _ = write!(out, ",\n          \"default\": {value}");
            }
            out.push('\n');
        },
        Kind::Int { default, min, max } => {
            let _ = writeln!(out, "          \"type\": \"integer\",");
            let _ = writeln!(out, "          \"minimum\": {min},");
            let _ = write!(out, "          \"maximum\": {max}");
            if let Some(value) = default {
                let _ = write!(out, ",\n          \"default\": {value}");
            }
            out.push('\n');
        },
        Kind::Float { default, min, max } => {
            let _ = writeln!(out, "          \"type\": \"number\",");
            let _ = writeln!(out, "          \"minimum\": {min},");
            let _ = write!(out, "          \"maximum\": {max}");
            if let Some(value) = default {
                let _ = write!(out, ",\n          \"default\": {value}");
            }
            out.push('\n');
        },
        Kind::Choice { default, options } => {
            let _ = writeln!(out, "          \"type\": \"string\",");
            let _ = write!(out, "          \"enum\": [{}]", tokens(options));
            if let Some(value) = default {
                let _ = write!(out, ",\n          \"default\": {}", quoted(value));
            }
            out.push('\n');
        },
        Kind::Text { default } => {
            let _ = writeln!(out, "          \"type\": \"string\",");
            let _ = writeln!(out, "          \"default\": {}", quoted(default));
        },
        Kind::List => {
            let _ = writeln!(out, "          \"type\": \"array\",");
            let _ = writeln!(out, "          \"items\": {{ \"type\": \"string\" }},");
            let _ = writeln!(out, "          \"default\": []");
        },
        Kind::Scale {
            default,
            options,
            min,
            max,
        } => {
            let _ = writeln!(out, "          \"oneOf\": [");
            let _ = writeln!(
                out,
                "            {{ \"type\": \"string\", \"enum\": [{}] }},",
                tokens(options)
            );
            let _ = writeln!(
                out,
                "            {{ \"type\": \"number\", \"minimum\": {min}, \"maximum\": {max} }}"
            );
            let _ = writeln!(out, "          ],");
            let _ = writeln!(out, "          \"default\": {}", quoted(default));
        },
    }
}

/// One of the two free tables — any key, string values.
fn write_open_table(out: &mut String, section: &str, doc: &str) {
    let _ = writeln!(out, "    {}: {{", quoted(section));
    let _ = writeln!(out, "      \"type\": \"object\",");
    let _ = writeln!(out, "      \"description\": {},", quoted(doc));
    let _ = writeln!(out, "      \"additionalProperties\": {{ \"type\": \"string\" }}");
    let _ = write!(out, "    }}");
}

/// `"a", "b"` for an enum body.
fn tokens(options: &[&str]) -> String {
    options
        .iter()
        .map(|token| quoted(token))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A path as its section and its leaf.
fn split(path: &'static str) -> (&'static str, &'static str) {
    path.split_once('.').unwrap_or((path, path))
}

#[cfg(test)]
mod tests {
    use super::json_schema;

    #[test]
    fn the_schema_is_one_object_per_section_and_closes_every_one() {
        let schema = json_schema();
        assert!(schema.starts_with("{\n  \"$schema\""));
        assert!(schema.ends_with("}\n"));
        assert_eq!(
            schema.matches('{').count(),
            schema.matches('}').count(),
            "braces do not balance"
        );
        assert_eq!(schema.matches('[').count(), schema.matches(']').count());
    }

    #[test]
    fn a_key_carries_its_sentence_its_domain_and_its_default() {
        let schema = json_schema();
        assert!(schema.contains("\"copy-on-select\": {"));
        assert!(schema.contains("Copy the selection to the pasteboard as soon as it is made."));
        assert!(schema.contains("\"clipboard-read\": {"));
        assert!(schema.contains("\"enum\": [\"ask\", \"allow\", \"deny\"]"));
    }

    #[test]
    fn a_typo_is_an_error_where_it_was_typed() {
        let schema = json_schema();
        assert!(schema.contains("\"additionalProperties\": false"));
        assert_eq!(
            schema.matches("\"additionalProperties\": false").count(),
            11,
            "the root and every declared section"
        );
    }

    #[test]
    fn the_two_free_tables_take_any_key() {
        let schema = json_schema();
        assert!(schema.contains("\"keybind\": {"));
        assert!(schema.contains("\"env\": {"));
        assert!(schema.contains("\"additionalProperties\": { \"type\": \"string\" }"));
    }

    #[test]
    fn a_key_without_a_default_advertises_none() {
        let schema = json_schema();
        let video = schema
            .split("\"qp-sharp\": {")
            .nth(1)
            .unwrap_or_default()
            .split("},")
            .next()
            .unwrap_or_default();
        assert!(video.contains("\"minimum\": 1"));
        assert!(!video.contains("\"default\""), "{video}");
    }

    #[test]
    fn two_runs_write_the_same_bytes() {
        assert_eq!(json_schema(), json_schema());
    }
}

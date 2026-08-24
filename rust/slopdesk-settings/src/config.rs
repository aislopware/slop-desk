//! The configuration file: what it may say, what it means, and what it is when it says nothing.
//!
//! One TOML document at `~/.config/slopdesk/config.toml`, one table describing every key it may
//! carry ([`table`]), one resolver that turns the two into the values the app runs on, and one
//! JSON Schema written out of the same table ([`schema`]) so an editor can complete and validate
//! the file while it is being typed. [`path`] answers where the file IS, and reads it.
//!
//! ## The contract
//!
//! * **Best by default.** A missing file is not a lesser install: every key has an answer, and the
//!   answer is the one a good terminal would have picked. Nothing asks the user anything at first
//!   launch, and there is no window to change any of this in.
//! * **The file is the truth.** No GUI writes here, so nothing can be set two ways and disagree. A
//!   value the app resolves is either what this file says or what the table says.
//! * **A bad line is REPORTED, never silently dropped.** An unknown key, a value outside its
//!   domain, a token nothing accepts — each becomes a diagnostic the CLI prints and the app logs,
//!   and the key falls back to its default rather than taking a value nobody meant.
//!
//! ## What crosses to Swift
//!
//! One JSON snapshot per load ([`Resolved::snapshot_json`]), five maps by type plus the two open
//! tables. The near side reads it once at launch and once per reload — not per draw — so the
//! crossing cost is a launch cost, and no Swift file holds a default of its own to disagree with.

pub mod path;
pub mod schema;
pub mod table;

use std::collections::BTreeMap;
use std::fmt::Write as _;

pub use table::{KEYS, Key, Kind};

/// The persisted token for the comfortable chrome density.
pub const DENSITY_COMFORTABLE: &str = "comfortable";
/// The persisted token for the compact one.
pub const DENSITY_COMPACT: &str = "compact";

/// The free table of chord → action bindings.
pub const KEYBIND_SECTION: &str = "keybind";
/// The free table of raw `SLOPDESK_*` environment overrides.
pub const ENV_SECTION: &str = "env";

/// One resolved value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// A boolean.
    Flag(bool),
    /// A whole number.
    Int(i64),
    /// A real number.
    Float(f64),
    /// A string.
    Text(String),
    /// A list of strings.
    List(Vec<String>),
}

/// Everything the app runs on: the resolved keys, the two open tables, and what was wrong with the
/// file.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Resolved {
    /// Every key that HAS a value — the file's, else the table's default. A key whose default is
    /// deliberately absent (the video flags, whose numbers belong to the daemon) is missing here
    /// until somebody sets it, which is what keeps an untouched install's env overlay empty.
    values: BTreeMap<&'static str, Value>,
    /// The `[keybind]` table, chord → action, in file order made stable by the map.
    keybinds: BTreeMap<String, String>,
    /// The `[env]` table, raw name → value.
    env: BTreeMap<String, String>,
    /// One line per thing wrong with the file, in reading order.
    diagnostics: Vec<String>,
}

impl Resolved {
    /// The defaults alone — what a machine with no file runs on.
    #[must_use]
    pub fn defaults() -> Self {
        let mut resolved = Self::default();
        for declared in KEYS {
            if let Some(value) = default_value(declared.kind) {
                drop(resolved.values.insert(declared.path, value));
            }
        }
        resolved
    }

    /// The value at `path`, or `None` for a key nothing has answered.
    #[must_use]
    pub fn value(&self, path: &str) -> Option<&Value> {
        self.values.get(path)
    }

    /// The `[keybind]` table.
    #[must_use]
    pub const fn keybinds(&self) -> &BTreeMap<String, String> {
        &self.keybinds
    }

    /// The `[env]` table.
    #[must_use]
    pub const fn env(&self) -> &BTreeMap<String, String> {
        &self.env
    }

    /// What was wrong with the file, one line each.
    #[must_use]
    pub fn diagnostics(&self) -> &[String] {
        &self.diagnostics
    }

    /// The snapshot the near side decodes: five maps by type, then the two open tables, then every
    /// DECLARED path, then the diagnostics.
    ///
    /// Typed maps rather than one nested document because the near side's reads are typed: a
    /// `bool` key read as a string is a bug the shape itself refuses, and a reader that had to walk
    /// a tree per read would pay for the nesting on every one.
    ///
    /// `declared` is the whole table's paths and NOT the union of the five maps, which is a
    /// different set: a key declared with no default (the video and agent flags) is absent from the
    /// maps until somebody sets it. Without this list the near side could not tell "this key does
    /// not exist" from "this key is unset" — precisely the two answers `slopdesk config get` has to
    /// separate, and precisely the keys the "unset" answer was written for.
    #[must_use]
    pub fn snapshot_json(&self) -> String {
        let mut flags = BTreeMap::new();
        let mut ints = BTreeMap::new();
        let mut floats = BTreeMap::new();
        let mut texts = BTreeMap::new();
        let mut lists: BTreeMap<&str, &[String]> = BTreeMap::new();
        for (path, value) in &self.values {
            match value {
                Value::Flag(flag) => drop(flags.insert(*path, *flag)),
                Value::Int(number) => drop(ints.insert(*path, *number)),
                Value::Float(number) => drop(floats.insert(*path, *number)),
                Value::Text(text) => drop(texts.insert(*path, text.as_str())),
                Value::List(items) => drop(lists.insert(*path, items.as_slice())),
            }
        }
        let mut out = String::from("{\"flag\":");
        write_map(&mut out, flags.iter().map(|(k, v)| (*k, bool_json(*v))));
        out.push_str(",\"int\":");
        write_map(&mut out, ints.iter().map(|(k, v)| (*k, v.to_string())));
        out.push_str(",\"float\":");
        write_map(&mut out, floats.iter().map(|(k, v)| (*k, float_json(*v))));
        out.push_str(",\"text\":");
        write_map(&mut out, texts.iter().map(|(k, v)| (*k, quoted(v))));
        out.push_str(",\"list\":");
        write_map(&mut out, lists.iter().map(|(k, v)| (*k, list_json(v))));
        out.push_str(",\"keybind\":");
        write_map(
            &mut out,
            self.keybinds
                .iter()
                .map(|(k, v)| (k.as_str(), quoted(v.as_str()))),
        );
        out.push_str(",\"env\":");
        write_map(&mut out, self.env.iter().map(|(k, v)| (k.as_str(), quoted(v))));
        out.push_str(",\"declared\":");
        out.push_str(&list_json(
            &KEYS.iter().map(|key| key.path.to_owned()).collect::<Vec<_>>(),
        ));
        out.push_str(",\"diagnostics\":");
        out.push_str(&list_json(&self.diagnostics));
        out.push('}');
        out
    }
}

/// Resolves `text` — the whole config file — against the table.
///
/// Never fails: a document that is not TOML at all resolves to the defaults plus one diagnostic
/// saying where the parse stopped, because a syntax error in a config file must not be the reason
/// a terminal will not open.
#[must_use]
pub fn resolve(text: &str) -> Resolved {
    let mut resolved = Resolved::defaults();
    let document = match text.parse::<toml::Table>() {
        Ok(document) => document,
        Err(error) => {
            resolved
                .diagnostics
                .push(format!("config.toml is not valid TOML: {error}"));
            return resolved;
        },
    };
    for (section, body) in &document {
        match section.as_str() {
            KEYBIND_SECTION => {
                read_open_table(
                    &mut resolved.keybinds,
                    body,
                    KEYBIND_SECTION,
                    &mut resolved.diagnostics,
                );
            },
            ENV_SECTION => read_open_table(&mut resolved.env, body, ENV_SECTION, &mut resolved.diagnostics),
            _ => read_section(&mut resolved, section, body),
        }
    }
    resolved
}

/// Reads one `[section]` of declared keys.
fn read_section(resolved: &mut Resolved, section: &str, body: &toml::Value) {
    let Some(entries) = body.as_table() else {
        resolved.diagnostics.push(format!("[{section}] must be a table"));
        return;
    };
    for (leaf, written) in entries {
        let path = format!("{section}.{leaf}");
        let Some(declared) = table::key(&path) else {
            resolved
                .diagnostics
                .push(format!("{path} is not a setting slopdesk knows"));
            continue;
        };
        match read_value(declared, written) {
            Ok(value) => drop(resolved.values.insert(declared.path, value)),
            Err(complaint) => resolved.diagnostics.push(format!("{path}: {complaint}")),
        }
    }
}

/// Reads one free table — `[keybind]` or `[env]` — whose keys are the user's own.
fn read_open_table(
    into: &mut BTreeMap<String, String>,
    body: &toml::Value,
    section: &str,
    diagnostics: &mut Vec<String>,
) {
    let Some(entries) = body.as_table() else {
        diagnostics.push(format!("[{section}] must be a table"));
        return;
    };
    for (name, written) in entries {
        match written.as_str() {
            Some(text) => drop(into.insert(name.clone(), text.to_owned())),
            None => diagnostics.push(format!("{section}.{name} must be a string")),
        }
    }
}

/// Reads one written value against the key that declares it.
fn read_value(declared: &Key, written: &toml::Value) -> Result<Value, String> {
    match declared.kind {
        Kind::Flag { .. } => {
            written
                .as_bool()
                .map(Value::Flag)
                .ok_or_else(|| "expected true or false".to_owned())
        },
        Kind::Int { min, max, .. } => {
            let number = written
                .as_integer()
                .ok_or_else(|| "expected a whole number".to_owned())?;
            if (min..=max).contains(&number) {
                Ok(Value::Int(number))
            } else {
                Err(format!("{number} is outside {min}…{max}"))
            }
        },
        Kind::Float { min, max, .. } => {
            let number = float_of(written).ok_or_else(|| "expected a number".to_owned())?;
            if number >= min && number <= max {
                Ok(Value::Float(number))
            } else {
                Err(format!("{number} is outside {min}…{max}"))
            }
        },
        Kind::Choice { options, .. } => {
            let token = written
                .as_str()
                .ok_or_else(|| format!("expected one of {}", options.join(", ")))?;
            if options.contains(&token) {
                Ok(Value::Text(token.to_owned()))
            } else {
                Err(format!("\"{token}\" is not one of {}", options.join(", ")))
            }
        },
        Kind::Text { .. } => {
            written
                .as_str()
                .map(|text| Value::Text(text.to_owned()))
                .ok_or_else(|| "expected a string".to_owned())
        },
        Kind::List => {
            let items = written
                .as_array()
                .ok_or_else(|| "expected a list of strings".to_owned())?;
            let mut read = Vec::with_capacity(items.len());
            for item in items {
                let text = item
                    .as_str()
                    .ok_or_else(|| "every entry must be a string".to_owned())?;
                read.push(text.to_owned());
            }
            Ok(Value::List(read))
        },
        Kind::Scale {
            options, min, max, ..
        } => {
            if let Some(token) = written.as_str() {
                return if options.contains(&token) {
                    Ok(Value::Text(token.to_owned()))
                } else {
                    Err(format!(
                        "\"{token}\" is neither a multiplier nor one of {}",
                        options.join(", ")
                    ))
                };
            }
            let number = float_of(written)
                .ok_or_else(|| format!("expected a multiplier or one of {}", options.join(", ")))?;
            if number >= min && number <= max {
                Ok(Value::Float(number))
            } else {
                Err(format!("{number} is outside {min}…{max}"))
            }
        },
    }
}

/// A TOML number as `f64`, whether it was written `1` or `1.0`.
fn float_of(written: &toml::Value) -> Option<f64> {
    written.as_float().or_else(|| {
        written.as_integer().map(|number| {
            #[expect(
                clippy::cast_precision_loss,
                reason = "every declared range is far inside f64's exact integers"
            )]
            let widened = number as f64;
            widened
        })
    })
}

/// What a key is when the file is silent, or `None` for the keys whose reader decides.
fn default_value(kind: Kind) -> Option<Value> {
    match kind {
        Kind::Flag { default } => default.map(Value::Flag),
        Kind::Int { default, .. } => default.map(Value::Int),
        Kind::Float { default, .. } => default.map(Value::Float),
        Kind::Choice { default, .. } => default.map(|token| Value::Text(token.to_owned())),
        // Text and Scale share a body on purpose: an unset scale IS its stop's token, and the
        // near side reads the two the same way.
        Kind::Text { default } | Kind::Scale { default, .. } => Some(Value::Text(default.to_owned())),
        Kind::List => Some(Value::List(Vec::new())),
    }
}

/// `{"a":1,"b":2}` from already-encoded values.
fn write_map<'a>(out: &mut String, entries: impl Iterator<Item = (&'a str, String)>) {
    out.push('{');
    let mut first = true;
    for (name, encoded) in entries {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(&quoted(name));
        out.push(':');
        out.push_str(&encoded);
    }
    out.push('}');
}

/// `true` / `false`.
fn bool_json(flag: bool) -> String {
    if flag {
        "true".to_owned()
    } else {
        "false".to_owned()
    }
}

/// A finite `f64` as JSON. Nothing here can be NaN — every float went through a range check — but
/// the encoder answers `0` rather than writing a token no JSON reader accepts.
fn float_json(number: f64) -> String {
    if number.is_finite() {
        let mut text = format!("{number}");
        if !text.contains('.') && !text.contains('e') {
            text.push_str(".0");
        }
        text
    } else {
        "0.0".to_owned()
    }
}

/// A JSON array of strings.
fn list_json(items: &[String]) -> String {
    let mut out = String::from("[");
    for (index, item) in items.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str(&quoted(item));
    }
    out.push(']');
    out
}

/// A JSON string, escaped the way the spec asks and no further.
pub(crate) fn quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if control < ' ' => {
                let _ = write!(out, "\\u{:04x}", u32::from(control));
            },
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::{Resolved, Value, resolve};

    #[test]
    fn an_empty_file_is_the_whole_default_install() {
        let resolved = resolve("");
        assert!(resolved.diagnostics().is_empty());
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(false))
        );
        assert_eq!(
            resolved.value("terminal.font-family"),
            Some(&Value::Text("SF Mono".to_owned()))
        );
        assert_eq!(resolved, Resolved::defaults());
    }

    #[test]
    fn a_set_key_wins_over_its_default() {
        let resolved = resolve("[controls]\ncopy-on-select = true\n");
        assert!(resolved.diagnostics().is_empty());
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(true))
        );
    }

    #[test]
    fn an_unknown_key_is_reported_and_changes_nothing() {
        let resolved = resolve("[controls]\ncopyOnSelect = true\n");
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(false))
        );
        assert!(
            resolved
                .diagnostics()
                .iter()
                .any(|line| line.contains("controls.copyOnSelect")),
            "{:?}",
            resolved.diagnostics()
        );
    }

    #[test]
    fn a_value_outside_its_range_keeps_the_default() {
        let resolved = resolve("[terminal]\nfont-size = 900\n");
        assert_eq!(resolved.value("terminal.font-size"), Some(&Value::Float(13.0)));
        assert!(resolved.diagnostics().iter().any(|line| line.contains("outside")));
    }

    #[test]
    fn a_token_nothing_accepts_keeps_the_default() {
        let resolved = resolve("[controls]\nclipboard-read = \"maybe\"\n");
        assert_eq!(
            resolved.value("controls.clipboard-read"),
            Some(&Value::Text("ask".to_owned()))
        );
        assert!(resolved.diagnostics().iter().any(|line| line.contains("maybe")));
    }

    #[test]
    fn a_wrong_type_is_reported_rather_than_coerced() {
        let resolved = resolve("[controls]\ncopy-on-select = \"yes\"\n");
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(false))
        );
        assert!(
            resolved
                .diagnostics()
                .iter()
                .any(|line| line.contains("true or false"))
        );
    }

    #[test]
    fn a_video_flag_stays_absent_until_it_is_set() {
        assert!(resolve("").value("video.qp-sharp").is_none());
        assert_eq!(
            resolve("[video]\nqp-sharp = 30\n").value("video.qp-sharp"),
            Some(&Value::Int(30))
        );
    }

    #[test]
    fn the_scale_key_takes_a_stop_or_a_multiplier() {
        assert_eq!(
            resolve("[terminal]\nline-height = \"loose\"\n").value("terminal.line-height"),
            Some(&Value::Text("loose".to_owned()))
        );
        assert_eq!(
            resolve("[terminal]\nline-height = 1.15\n").value("terminal.line-height"),
            Some(&Value::Float(1.15))
        );
        assert!(
            !resolve("[terminal]\nline-height = \"roomy\"\n")
                .diagnostics()
                .is_empty()
        );
    }

    #[test]
    fn the_two_open_tables_are_the_users_own_words() {
        let resolved = resolve("[keybind]\n\"cmd+t\" = \"new-tab\"\n\n[env]\nSLOPDESK_QP_SHARP = \"30\"\n");
        assert!(resolved.diagnostics().is_empty());
        assert_eq!(
            resolved.keybinds().get("cmd+t").map(String::as_str),
            Some("new-tab")
        );
        assert_eq!(
            resolved.env().get("SLOPDESK_QP_SHARP").map(String::as_str),
            Some("30")
        );
    }

    #[test]
    fn a_file_that_is_not_toml_still_opens_a_terminal() {
        let resolved = resolve("this is not a config file");
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(false))
        );
        assert_eq!(resolved.diagnostics().len(), 1);
    }

    /// A key declared WITHOUT a default is in `declared` even though no map carries it — the whole
    /// reason the list is on the wire. `video.qp-sharp` is one; an untouched file must still report
    /// it as a real key that is unset, not as a typo.
    #[test]
    fn the_snapshot_declares_keys_that_have_no_default() {
        let snapshot = Resolved::defaults().snapshot_json();
        assert!(
            snapshot.contains("\"video.qp-sharp\""),
            "the declared list carries a default-less key"
        );
        assert!(
            !snapshot.contains("\"int\":{\"video.qp-sharp\""),
            "and it is absent from the typed maps, which is what keeps the env overlay empty"
        );
    }

    #[test]
    fn an_integer_reads_as_a_float_where_the_key_wants_one() {
        assert_eq!(
            resolve("[terminal]\nfont-size = 15\n").value("terminal.font-size"),
            Some(&Value::Float(15.0))
        );
    }

    #[test]
    fn the_snapshot_carries_every_map_and_escapes_what_it_must() {
        let snapshot = resolve("[terminal]\nfont-family = \"He said \\\"hi\\\"\"\n").snapshot_json();
        assert!(snapshot.starts_with("{\"flag\":{"));
        assert!(snapshot.contains("\"terminal.font-family\":\"He said \\\"hi\\\"\""));
        for section in [
            "\"int\":",
            "\"float\":",
            "\"text\":",
            "\"list\":",
            "\"keybind\":",
            "\"env\":",
            "\"declared\":",
            "\"diagnostics\":",
        ] {
            assert!(snapshot.contains(section), "{section} missing");
        }
    }

    #[test]
    fn a_float_always_carries_its_point_so_the_near_side_reads_a_double() {
        let snapshot = resolve("").snapshot_json();
        assert!(snapshot.contains("\"terminal.font-size\":13.0"), "{snapshot}");
    }
}

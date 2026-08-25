//! Reading the resolved configuration BACK out: one value bare, the whole thing as TOML, and every
//! complaint the file earns.
//!
//! The reading half of `slopdesk config` — `get`, `show` and `validate`. It lives beside the table
//! rather than in the CLI for the reason the path resolution does: the app reads the same file, and
//! a renderer in the CLI would be a second opinion about what a value IS.
//!
//! There is no writing half, and there will not be one. The file is the truth, and a program that
//! writes a user's config file makes a setting the user cannot see in their own file.

use std::collections::BTreeMap;

use crate::config::{ENV_SECTION, KEYBIND_SECTION, KEYS, Resolved, Value};

/// Every path the table declares, in table order.
///
/// This is the whole table and NOT the set of keys that have values — a key declared with no
/// default (the video and agent flags, whose numbers belong to the daemon) is absent from the
/// second set until somebody sets it. Without the distinction `config get` could not tell "this key
/// does not exist" from "this key is unset", which are the two answers it exists to separate.
#[must_use]
pub fn declared_paths() -> Vec<&'static str> {
    KEYS.iter().map(|key| key.path).collect()
}

/// True when the table declares `path`.
#[must_use]
pub fn is_declared(path: &str) -> bool {
    KEYS.iter().any(|key| key.path == path)
}

/// One resolved value, rendered bare — no quotes, no `key =` — so a shell can capture it.
///
/// `None` for a key nothing has answered. The caller reports "unset" rather than printing a zero
/// nobody chose.
#[must_use]
pub fn value_text(resolved: &Resolved, path: &str) -> Option<String> {
    resolved.value(path).map(|value| {
        match value {
            Value::Flag(flag) => bare_bool(*flag),
            Value::Int(number) => number.to_string(),
            Value::Float(number) => float_text(*number),
            Value::Text(text) => text.clone(),
            Value::List(items) => items.join(","),
        }
    })
}

/// The WHOLE resolved configuration as TOML — every key with the value this machine is actually
/// running on, grouped under its section header in path order.
///
/// Deliberately re-pasteable: `slopdesk config show > ~/.config/slopdesk/config.toml` yields a file
/// that resolves to exactly what was printed. That is the one honest way to answer "what am I
/// running on" for a program whose whole point is that it never wrote the file. The starter file
/// the app creates is the opposite shape — comments only — because a file full of defaults PINS
/// them, and then a retuned default never reaches the person who took the sample.
///
/// No trailing newline: the caller adds the one its stream wants.
#[must_use]
pub fn to_toml(resolved: &Resolved) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut section = "";
    // `values` is a `BTreeMap`, so the walk is already in path order — which is what makes the
    // section headers fall out of the iteration rather than needing a grouping pass.
    for (path, value) in &resolved.values {
        let head = path.split('.').next().unwrap_or(path);
        if head != section {
            section = head;
            if !lines.is_empty() {
                lines.push(String::new());
            }
            lines.push(format!("[{section}]"));
        }
        // `head` came out of `path`, so the leaf is what follows it and its dot.
        let leaf = path.get(section.len().saturating_add(1)..).unwrap_or(path);
        lines.push(format!("{leaf} = {}", toml_value(value)));
    }
    append_free_table(KEYBIND_SECTION, resolved.keybinds(), true, &mut lines);
    append_free_table(ENV_SECTION, resolved.env(), false, &mut lines);
    lines.join("\n")
}

/// Everything wrong with the file, in reading order — one sentence per problem.
///
/// Empty means the file is fine, AND empty means there is no file: an install without one is the
/// supported shape, so it cannot be an error.
///
/// Two sources, because they are two different kinds of wrong. The table's own diagnostics are
/// per-ROW — an undeclared key, a value outside its range — and the resolver answers them as it
/// parses. The `[keybind]` conflicts are per-PAIR: no single row is wrong, and the problem only
/// exists once both have been folded to a canonical chord.
#[must_use]
pub fn diagnostics(resolved: &Resolved) -> Vec<String> {
    let mut all = resolved.diagnostics().to_vec();
    all.extend(keybind_conflicts(resolved.keybinds()));
    all
}

/// Two `[keybind]` rows that fold to the same chord, so only one of them can bind.
///
/// `cmd+shift+h` and `CMD+Shift+H` are the same chord written twice; nothing about either ROW is
/// wrong, which is why the resolver cannot report it and this walks the folded spellings instead.
/// An unparseable row is skipped rather than reported here — the resolver already said so.
#[must_use]
pub fn keybind_conflicts(table: &BTreeMap<String, String>) -> Vec<String> {
    /// The action whose grammar puts the chord on the RIGHT of the colon.
    const UNBIND: &str = "unbind";

    let mut spellings: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for (chord, action) in table {
        if chord.is_empty() || action.is_empty() {
            continue;
        }
        let line = if action == UNBIND {
            format!("{action}:{chord}")
        } else {
            format!("{chord}:{action}")
        };
        let Some(parsed) = slopdesk_terminal::keybind::parse_line(&line) else {
            continue;
        };
        spellings
            .entry(slopdesk_terminal::keybind::canonical_chord(&parsed.chord))
            .or_default()
            .push(chord.as_str());
    }
    spellings
        .into_iter()
        .filter(|(_, written)| written.len() > 1)
        .map(|(canonical, written)| {
            let named: Vec<String> = written.iter().map(|spelling| format!("\"{spelling}\"")).collect();
            format!(
                "[{KEYBIND_SECTION}]: {} are the same chord ({canonical}) — only one of them binds",
                named.join(" and ")
            )
        })
        .collect()
}

/// The `[keybind]` / `[env]` tables, whose keys are the USER's own rather than the table's.
///
/// Omitted entirely when empty — printing an empty header would invite somebody to fill it in under
/// a section name they then have to guess the grammar of.
fn append_free_table(
    name: &str,
    table: &BTreeMap<String, String>,
    quoting_keys: bool,
    lines: &mut Vec<String>,
) {
    if table.is_empty() {
        return;
    }
    if !lines.is_empty() {
        lines.push(String::new());
    }
    lines.push(format!("[{name}]"));
    for (key, value) in table {
        let rendered_key = if quoting_keys { quoted(key) } else { key.clone() };
        lines.push(format!("{rendered_key} = {}", quoted(value)));
    }
}

/// One value as TOML — strings and list members quoted, numbers and booleans bare.
fn toml_value(value: &Value) -> String {
    match value {
        Value::Flag(flag) => bare_bool(*flag),
        Value::Int(number) => number.to_string(),
        Value::Float(number) => float_text(*number),
        Value::Text(text) => quoted(text),
        Value::List(items) => {
            let members: Vec<String> = items.iter().map(|item| quoted(item)).collect();
            format!("[{}]", members.join(", "))
        },
    }
}

fn bare_bool(flag: bool) -> String {
    if flag {
        "true".to_owned()
    } else {
        "false".to_owned()
    }
}

/// A float with its point kept.
///
/// `1` and `1.0` are the same TOML float, but only one of them round-trips through a reader that
/// types the key as an integer — and `config show`'s whole promise is that its output can be pasted
/// back. Matches [`crate::config::Resolved::snapshot_json`]'s rendering for the same reason.
fn float_text(number: f64) -> String {
    if !number.is_finite() {
        return "0.0".to_owned();
    }
    let mut text = format!("{number}");
    if !text.contains('.') && !text.contains('e') {
        text.push_str(".0");
    }
    text
}

/// A TOML basic string: the two characters that can end it early, escaped, and nothing else — every
/// value that reaches here came back OUT of the parser, so it is already well-formed text.
fn quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len().saturating_add(2));
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{declared_paths, diagnostics, is_declared, keybind_conflicts, to_toml, value_text};
    use crate::config::resolve;

    fn table(rows: &[(&str, &str)]) -> BTreeMap<String, String> {
        rows.iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn the_declared_set_is_the_whole_table_and_holds_a_key_that_has_no_default() {
        let paths = declared_paths();
        assert!(paths.len() > 20, "{} declared", paths.len());
        for path in &paths {
            assert!(is_declared(path), "{path} declared but not found");
        }
        assert!(!is_declared("terminal.no-such-key"));
    }

    /// The distinction `config get` is built on: declared-and-unset is not the same answer as
    /// undeclared, and only one of them is the user's typo.
    #[test]
    fn a_declared_key_with_no_answer_reads_as_absent_rather_than_as_a_zero() {
        let resolved = resolve("");
        let unset: Vec<&'static str> = declared_paths()
            .into_iter()
            .filter(|path| value_text(&resolved, path).is_none())
            .collect();
        assert!(
            !unset.is_empty(),
            "the table declares at least one key whose number belongs to the daemon"
        );
        for path in unset {
            assert!(is_declared(path), "{path}");
        }
    }

    #[test]
    fn show_renders_re_pasteable_toml_that_resolves_to_what_it_printed() {
        let source = "[terminal]\nfont-size = 15.0\n\n[keybind]\n\"cmd+shift+h\" = \
                      \"split_left\"\n\n[env]\nSLOPDESK_X = \"1\"\n";
        let first = resolve(source);
        let printed = to_toml(&first);
        assert!(printed.contains("[terminal]"), "{printed}");
        assert!(printed.contains("[keybind]"), "{printed}");
        assert!(
            printed.contains("\"cmd+shift+h\" = \"split_left\""),
            "a keybind key is quoted: {printed}"
        );
        assert!(
            printed.contains("SLOPDESK_X = \"1\""),
            "an env key is bare: {printed}"
        );

        // THE PROMISE: paste it back and nothing moves.
        let second = resolve(&printed);
        assert_eq!(to_toml(&second), printed);
        assert!(second.diagnostics().is_empty(), "{:?}", second.diagnostics());
    }

    #[test]
    fn a_float_keeps_its_point_so_the_paste_back_does_not_retype_the_key() {
        let resolved = resolve("[terminal]\nfont-size = 14.0\n");
        assert_eq!(
            value_text(&resolved, "terminal.font-size"),
            Some("14.0".to_owned())
        );
        assert!(to_toml(&resolved).contains("font-size = 14.0"));
    }

    #[test]
    fn a_quote_or_a_backslash_in_a_value_survives_the_round_trip() {
        let resolved = resolve("[env]\nSLOPDESK_Q = \"a\\\"b\\\\c\"\n");
        let printed = to_toml(&resolved);
        assert!(printed.contains(r#"SLOPDESK_Q = "a\"b\\c""#), "{printed}");
        assert_eq!(resolve(&printed).env(), resolved.env());
    }

    #[test]
    fn two_spellings_of_one_chord_are_reported_as_a_pair_and_one_spelling_is_not() {
        let clash = keybind_conflicts(&table(&[
            ("cmd+shift+h", "split_left"),
            ("CMD+Shift+H", "split_right"),
        ]));
        assert_eq!(clash.len(), 1, "{clash:?}");
        let reported = clash.first().map_or("", String::as_str);
        assert!(reported.contains("are the same chord"), "{clash:?}");
        assert!(
            reported.contains("\"CMD+Shift+H\" and \"cmd+shift+h\""),
            "{clash:?}"
        );

        assert!(keybind_conflicts(&table(&[("cmd+shift+h", "split_left")])).is_empty());
        assert!(keybind_conflicts(&table(&[])).is_empty());
    }

    /// The `unbind` row's grammar puts the chord on the RIGHT, and folding it the other way would
    /// make every unbind unparseable — so a clash between an unbind and a binding would go unseen.
    #[test]
    fn an_unbind_row_folds_the_same_way_a_binding_does() {
        let clash = keybind_conflicts(&table(&[("cmd+q", "unbind"), ("CMD+q", "split_left")]));
        assert_eq!(clash.len(), 1, "{clash:?}");
    }

    #[test]
    fn an_unparseable_row_is_the_resolvers_complaint_and_not_repeated_here() {
        assert!(keybind_conflicts(&table(&[("not a chord", "split_left")])).is_empty());
    }

    #[test]
    fn the_two_kinds_of_wrong_arrive_together_and_an_empty_file_earns_neither() {
        assert!(diagnostics(&resolve("")).is_empty());

        let both = diagnostics(&resolve(
            "[terminal]\nno-such-key = 1\n\n[keybind]\n\"cmd+shift+h\" = \"split_left\"\n\"CMD+SHIFT+H\" = \
             \"split_right\"\n",
        ));
        assert!(both.len() >= 2, "{both:?}");
        assert!(both.iter().any(|line| line.contains("no-such-key")), "{both:?}");
        assert!(
            both.iter().any(|line| line.contains("are the same chord")),
            "{both:?}"
        );
    }
}

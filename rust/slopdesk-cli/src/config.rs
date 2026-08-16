//! `slopdesk config path | edit | validate` — the LOCAL, no-socket config-file operations.
//!
//! These act on the optional user config FILE under `~/.config/slopdesk/`, which the launch-time
//! bridge reads. The RUNNING-app config operations — `get`, `set`, `unset`, `show`, `reload` — go
//! over the control socket instead, so only path resolution and validation are pure file logic and
//! live here. The `$EDITOR` spawn belongs to the shell.
//!
//! ## Not every `config` subcommand acts on the same file
//! The launch bridge reads ONLY the `keybind = <chord>:<action>` lines of `config.toml`; every
//! other key — `font-size`, `theme` — is silently ignored there and lives in the running app's
//! preferences instead. So `validate` checks the file against the grammar the app actually honours:
//! a line that is not a parseable `keybind` directive is FLAGGED rather than silently called valid,
//! because the app would ignore it.

/// The environment variable that overrides the config-file location. The `--config-file` flag takes
/// precedence over it.
pub const CONFIG_FILE_ENV_KEY: &str = "SLOPDESK_CONFIG_FILE";

/// Resolves the config-file path: an explicit `--config-file`, else
/// [`CONFIG_FILE_ENV_KEY`], else the XDG default.
///
/// The environment is injected — `lookup` answers a variable or `None` — so the resolution ORDER is
/// testable without mutating a real process env, which is the part that was worth porting.
#[must_use]
pub fn resolve_path(
    explicit: Option<&str>,
    lookup: &dyn Fn(&str) -> Option<String>,
    home_fallback: &str,
) -> String {
    if let Some(explicit) = explicit.filter(|path| !path.is_empty()) {
        return explicit.to_owned();
    }
    if let Some(from_env) = lookup(CONFIG_FILE_ENV_KEY).filter(|path| !path.is_empty()) {
        return from_env;
    }
    default_path(lookup, home_fallback)
}

/// `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `<home>/.config/slopdesk/config.toml`.
///
/// `home_fallback` stands in for the platform's home directory when `$HOME` is unset or empty —
/// the caller supplies it because asking the OS is I/O, and this module does none.
#[must_use]
pub fn default_path(lookup: &dyn Fn(&str) -> Option<String>, home_fallback: &str) -> String {
    if let Some(xdg) = lookup("XDG_CONFIG_HOME").filter(|path| !path.is_empty()) {
        return format!("{xdg}/slopdesk/config.toml");
    }
    let home = lookup("HOME")
        .filter(|path| !path.is_empty())
        .unwrap_or_else(|| home_fallback.to_owned());
    format!("{home}/.config/slopdesk/config.toml")
}

/// What one line of the config file is.
///
/// The file has exactly one reader, and it is read TWICE for different purposes: the client loads
/// the bindings it declares, and `config validate` reports why a line will be ignored. Both
/// readings come from here, so the validator cannot call a line good that the loader will silently
/// drop — which is the whole point of validating against the grammar the app honours rather than
/// against a generic `key = value` shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigLine<'a> {
    /// Blank, a `#` comment, or a `[section]` header — nothing to load and nothing to report.
    Ignorable,
    /// A `keybind` directive, with its value unquoted. Whether the value is a BINDING is the
    /// keybind grammar's question, not this one's.
    Keybind(&'a str),
    /// No `=` at all, so the line assigns nothing.
    MissingEquals,
    /// An assignment to some other key, which the app reads nothing from.
    UnknownKey(&'a str),
    /// A `keybind` with nothing after the `=`.
    EmptyValue,
}

/// Reads one line of the config file.
///
/// The trim is the file's, not the language's: spaces, tabs and a CARRIAGE RETURN, so a file with
/// CRLF endings reads the same as one without. That last byte is why this is shared rather than
/// spelled twice — a reader that keeps the `\r` hands it to the keybind grammar, which refuses it,
/// and the line is dropped by a validator that already called it fine.
#[must_use]
pub fn classify_line(raw: &str) -> ConfigLine<'_> {
    let line = raw.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\r');
    if line.is_empty() || line.starts_with('#') || line.starts_with('[') {
        return ConfigLine::Ignorable;
    }
    let Some((key, value)) = line.split_once('=') else {
        return ConfigLine::MissingEquals;
    };
    let key = key.trim();
    if key != "keybind" {
        return ConfigLine::UnknownKey(key);
    }
    // Lenient quoting: one surrounding pair of double quotes is stripped, so both the TOML-looking
    // form and the bare one name the same binding.
    let trimmed = value.trim();
    let unquoted = trimmed
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .unwrap_or(trimmed);
    if unquoted.is_empty() {
        ConfigLine::EmptyValue
    } else {
        ConfigLine::Keybind(unquoted)
    }
}

/// The `keybind` value one line declares, or [`None`] for every other line — the loader's reading
/// of [`classify_line`], which does not care WHY a line carries no binding.
#[must_use]
pub fn keybind_value(raw: &str) -> Option<&str> {
    match classify_line(raw) {
        ConfigLine::Keybind(value) => Some(value),
        _ => None,
    }
}

/// One config-file syntax problem.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationError {
    /// The 1-based line number.
    pub line: usize,
    /// What is wrong with it, phrased for a user reading a terminal.
    pub message: String,
}

/// Validates `contents` against the keybind grammar the launch bridge actually honours.
///
/// Blank lines, `#` comments and `[section]` headers are skipped. Every OTHER line must be a
/// `keybind = <value>` assignment whose value parses as a binding directive. A non-`keybind` key, a
/// missing `=`, an empty value or a malformed `<chord>:<action>` is reported with its line number.
/// An empty result means the file is valid.
///
/// The grammar itself is injected as `is_valid_keybind_value`, so this module needs no dependency
/// on the keybind parser and the validator's verdict tracks exactly what the app will honour.
#[must_use]
pub fn validate(contents: &str, is_valid_keybind_value: &dyn Fn(&str) -> bool) -> Vec<ValidationError> {
    let mut errors = Vec::new();
    for (index, raw) in contents.split('\n').enumerate() {
        let line = index + 1;
        let message = match classify_line(raw) {
            ConfigLine::Ignorable => continue,
            ConfigLine::MissingEquals => "missing '=' (expected keybind = <chord>:<action>)".to_owned(),
            ConfigLine::UnknownKey(key) => {
                let shown = if key.is_empty() { "(empty)" } else { key };
                format!(
                    "unknown key '{shown}': the app reads only 'keybind' lines from this file, so this line \
                     has no effect (set app config via `slopdesk config set`)"
                )
            },
            ConfigLine::EmptyValue => "empty keybind value".to_owned(),
            ConfigLine::Keybind(value) => {
                if is_valid_keybind_value(value) {
                    continue;
                }
                format!("malformed keybind '{value}' (expected <chord>:<action>)")
            },
        };
        errors.push(ValidationError { line, message });
    }
    errors
}

#[cfg(test)]
mod tests {
    use super::{CONFIG_FILE_ENV_KEY, default_path, keybind_value, resolve_path, validate};

    /// An environment built from pairs, so each test states exactly what is set.
    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| {
            pairs
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| (*value).to_owned())
        }
    }

    #[test]
    fn a_line_reads_the_same_whether_or_not_the_file_came_from_a_windows_editor() {
        assert_eq!(keybind_value("keybind = cmd+t:new_tab"), Some("cmd+t:new_tab"));
        assert_eq!(
            keybind_value("keybind = cmd+t:new_tab\r"),
            Some("cmd+t:new_tab"),
            "a CRLF file declares the same binding — the reader that keeps the \\r hands it to a grammar \
             that refuses it"
        );
        assert_eq!(
            keybind_value("  keybind\t=\t\"cmd+t:new_tab\"  "),
            Some("cmd+t:new_tab")
        );
        for line in [
            "",
            "   ",
            "# a comment",
            "[section]",
            "font-size = 14",
            "keybind =",
            "no equals",
        ] {
            assert_eq!(keybind_value(line), None, "{line}");
        }
    }

    /// A stand-in grammar: `<chord>:<action>` with both halves non-empty.
    fn grammar(value: &str) -> bool {
        value
            .split_once(':')
            .is_some_and(|(chord, action)| !chord.is_empty() && !action.is_empty())
    }

    #[test]
    fn the_explicit_flag_beats_the_env_which_beats_the_default() {
        let full = env(&[(CONFIG_FILE_ENV_KEY, "/from/env.toml"), ("HOME", "/Users/me")]);
        assert_eq!(
            resolve_path(Some("/explicit.toml"), &full, "/fallback"),
            "/explicit.toml"
        );
        assert_eq!(resolve_path(None, &full, "/fallback"), "/from/env.toml");
        assert_eq!(
            resolve_path(None, &env(&[("HOME", "/Users/me")]), "/fallback"),
            "/Users/me/.config/slopdesk/config.toml"
        );
    }

    #[test]
    fn an_empty_override_or_env_value_is_treated_as_unset() {
        let empty_env = env(&[(CONFIG_FILE_ENV_KEY, ""), ("HOME", "/Users/me")]);
        assert_eq!(
            resolve_path(Some(""), &empty_env, "/fallback"),
            "/Users/me/.config/slopdesk/config.toml"
        );
    }

    #[test]
    fn xdg_config_home_wins_over_home_and_an_absent_home_uses_the_fallback() {
        assert_eq!(
            default_path(
                &env(&[("XDG_CONFIG_HOME", "/xdg"), ("HOME", "/Users/me")]),
                "/fallback"
            ),
            "/xdg/slopdesk/config.toml"
        );
        assert_eq!(
            default_path(&env(&[("HOME", "")]), "/fallback"),
            "/fallback/.config/slopdesk/config.toml"
        );
        assert_eq!(
            default_path(&env(&[]), "/fallback"),
            "/fallback/.config/slopdesk/config.toml"
        );
    }

    #[test]
    fn a_file_of_only_skippable_lines_is_valid() {
        let contents = "\n# a comment\n[section]\n   \n\t\n";
        assert!(validate(contents, &grammar).is_empty());
        assert!(validate("", &grammar).is_empty());
    }

    #[test]
    fn a_well_formed_keybind_passes_quoted_or_not() {
        let contents = "keybind = cmd+t:new-tab\nkeybind = \"cmd+w:close-tab\"\n";
        assert!(validate(contents, &grammar).is_empty());
    }

    #[test]
    fn a_key_the_app_ignores_is_flagged_rather_than_called_valid() {
        let errors = validate("font-size = 14\n", &grammar);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors.first().map(|error| error.line), Some(1));
        assert!(errors.first().is_some_and(|error| {
            error.message.contains("font-size") && error.message.contains("no effect")
        }));
    }

    #[test]
    fn a_missing_equals_is_reported_with_its_line_number() {
        let errors = validate("# fine\nnonsense\n", &grammar);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors.first().map(|error| error.line), Some(2));
        assert!(
            errors
                .first()
                .is_some_and(|error| error.message.contains("missing '='"))
        );
    }

    #[test]
    fn an_empty_value_and_an_empty_key_each_get_their_own_message() {
        let errors = validate("keybind =\n= something\n", &grammar);
        assert_eq!(errors.len(), 2);
        assert!(
            errors
                .first()
                .is_some_and(|error| error.message == "empty keybind value")
        );
        assert!(
            errors
                .get(1)
                .is_some_and(|error| error.message.contains("(empty)"))
        );
    }

    #[test]
    fn an_empty_quoted_value_is_empty_too() {
        let errors = validate("keybind = \"\"\n", &grammar);
        assert_eq!(errors.len(), 1);
        assert!(
            errors
                .first()
                .is_some_and(|error| error.message == "empty keybind value")
        );
    }

    #[test]
    fn a_malformed_directive_is_reported_with_the_value_it_saw() {
        let errors = validate("keybind = cmd+t\n", &grammar);
        assert_eq!(errors.len(), 1);
        assert!(
            errors
                .first()
                .is_some_and(|error| error.message.contains("malformed keybind 'cmd+t'"))
        );
    }

    #[test]
    fn every_problem_in_a_file_is_reported_not_just_the_first() {
        let contents = "keybind = ok:action\nfont-size = 14\nkeybind = broken\nnonsense\n";
        let errors = validate(contents, &grammar);
        assert_eq!(errors.iter().map(|error| error.line).collect::<Vec<_>>(), [
            2, 3, 4
        ]);
    }

    #[test]
    fn a_value_containing_an_equals_keeps_everything_after_the_first_one() {
        // `split_once` mirrors Swift's `firstIndex(of:)`: the key is up to the FIRST `=`.
        let errors = validate("keybind = cmd+t:set-var=1\n", &grammar);
        assert!(errors.is_empty(), "{errors:?}");
    }

    #[test]
    fn a_file_without_a_trailing_newline_still_validates_its_last_line() {
        let errors = validate("keybind = broken", &grammar);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors.first().map(|error| error.line), Some(1));
    }
}

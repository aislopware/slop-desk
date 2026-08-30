//! Where the config file is, and reading it.
//!
//! One resolution order, shared by everything that opens the file: the `slopdesk` CLI, the app at
//! launch, and the app again on every reload. It used to live beside the CLI's argument parsing,
//! which was the wrong home the moment the app started reading the same file for more than
//! keybinds — the path belongs with the table that says what is IN the file.
//!
//! The environment is INJECTED rather than read here, so the order is testable without mutating a
//! real process env; [`resolve_path_from_env`] is the one caller that reads the real one.

use std::path::Path;

use crate::config::{Resolved, resolve};

/// The environment variable that overrides the config-file location. An explicit path — the CLI's
/// `--config-file` — takes precedence over it.
pub const CONFIG_FILE_ENV_KEY: &str = "SLOPDESK_CONFIG_FILE";

/// Resolves the config-file path: an explicit override, else [`CONFIG_FILE_ENV_KEY`], else the XDG
/// default under `home_fallback`.
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
/// `home_fallback` stands in for the platform's home directory when `$HOME` is unset or empty. The
/// caller supplies it because asking the OS is I/O, and because on iOS the answer is the app's own
/// container rather than anything the environment names.
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

/// The path this PROCESS would read, against the real environment.
#[must_use]
pub fn resolve_path_from_env(explicit: Option<&str>, home_fallback: &str) -> String {
    resolve_path(explicit, &|key| std::env::var(key).ok(), home_fallback)
}

/// What a brand-new `config.toml` says: how to find the schema, and that saying nothing is fine.
///
/// A COMMENT and a schema pointer, never a dump of the defaults. A file pre-filled with every key
/// at its default value is a file that pins today's answers forever — the next release improves a
/// default and nobody gets it, because their file already says the old number. Every key is absent
/// on purpose, and absent means "whatever this build thinks is best".
pub const STARTER: &str = "\
#:schema ./config.schema.json

# slopdesk configuration.
#
# Everything has a best-by-default answer already applied — this file exists to disagree with
# one. An empty file is a complete file; a key is only written here to change it.
#
# `slopdesk config show` prints every setting as resolved, `slopdesk config schema` prints the
# schema this points at, and an editor with JSON-Schema support completes the key, shows what it
# does and underlines a value outside its range.
";

/// The name of the schema written beside the config file, and what [`STARTER`]'s `#:schema` line
/// resolves to. Relative, so a reader who moves the directory keeps a working pointer.
pub const SCHEMA_FILE_NAME: &str = "config.schema.json";

/// Makes `path` openable: its directory, the schema beside it, and a starter file if there is none.
///
/// A fresh install has no `~/.config/slopdesk` and no file in it, and a "open my settings" that
/// opens nothing is a shortcut that looks broken. So this runs first, and answers whether it SEEDED
/// the file — which is the only part a caller can act on, the rest being idempotent.
///
/// The schema is rewritten every time rather than only on the first run: it is derived from this
/// build's table, so a stale one beside a file is worse than none — the editor would complete keys
/// the running binary no longer has.
///
/// Every step is best-effort, because the only caller's fallback for a failure is the same thing
/// that would have happened anyway: an editor opens nothing. A read-only home is not this
/// function's problem to report.
#[must_use]
pub fn prepare(path: &Path) -> bool {
    if let Some(directory) = path.parent() {
        drop(std::fs::create_dir_all(directory));
        drop(std::fs::write(
            directory.join(SCHEMA_FILE_NAME),
            crate::config::schema::json_schema(),
        ));
    }
    if path.exists() {
        return false;
    }
    std::fs::write(path, STARTER).is_ok()
}

/// Reads and resolves the file at `path`.
///
/// A file that is not there is not an error and not a diagnostic: an install with no config file is
/// the SUPPORTED shape, and the defaults are what it runs on. A file that cannot be READ — a
/// permission the user set, a directory where a file should be — IS a diagnostic, because that one
/// is a surprise worth printing.
#[must_use]
pub fn load(path: &Path) -> Resolved {
    match std::fs::read_to_string(path) {
        Ok(text) => resolve(&text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Resolved::defaults(),
        Err(error) => {
            let mut resolved = Resolved::defaults();
            resolved
                .diagnostics
                .push(format!("{} could not be read: {error}", path.display()));
            resolved
        },
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{CONFIG_FILE_ENV_KEY, SCHEMA_FILE_NAME, STARTER, default_path, load, prepare, resolve_path};
    use crate::config::{Resolved, Value, resolve};

    /// A directory of this test's own under the temp dir, empty on entry.
    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("slopdesk-config-prepare-{name}"));
        drop(std::fs::remove_dir_all(&directory));
        directory
    }

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
    fn the_explicit_path_beats_the_env_which_beats_the_default() {
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
        let empty = env(&[(CONFIG_FILE_ENV_KEY, ""), ("HOME", "/Users/me")]);
        assert_eq!(
            resolve_path(Some(""), &empty, "/fallback"),
            "/Users/me/.config/slopdesk/config.toml"
        );
    }

    #[test]
    fn preparing_a_fresh_install_makes_the_directory_the_schema_and_a_starter() {
        let directory = scratch("fresh");
        let path = directory.join("config.toml");
        assert!(prepare(&path), "a path with no file behind it is seeded");
        assert_eq!(std::fs::read_to_string(&path).unwrap_or_default(), STARTER);
        let schema = std::fs::read_to_string(directory.join(SCHEMA_FILE_NAME)).unwrap_or_default();
        assert_eq!(schema, crate::config::schema::json_schema());
        assert!(
            STARTER.contains(SCHEMA_FILE_NAME),
            "the starter's #:schema line has to point at the file written beside it"
        );
        drop(std::fs::remove_dir_all(&directory));
    }

    /// The whole reason the seed and the schema are two decisions: a reader's file is theirs, and a
    /// schema is this BUILD's. Re-running must not touch the first or skip the second.
    #[test]
    fn preparing_again_keeps_the_readers_file_and_still_refreshes_the_schema() {
        let directory = scratch("again");
        let path = directory.join("config.toml");
        assert!(
            prepare(&path),
            "the first run seeds, so the second has a file to keep"
        );
        drop(std::fs::write(&path, "[controls]\ncopy-on-select = true\n"));
        drop(std::fs::write(
            directory.join(SCHEMA_FILE_NAME),
            "{\"stale\":true}",
        ));

        assert!(!prepare(&path), "a file that is already there is not seeded");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap_or_default(),
            "[controls]\ncopy-on-select = true\n",
            "the reader's own settings survive"
        );
        assert_eq!(
            std::fs::read_to_string(directory.join(SCHEMA_FILE_NAME)).unwrap_or_default(),
            crate::config::schema::json_schema(),
            "a schema from an older build would complete keys this one does not have"
        );
        drop(std::fs::remove_dir_all(&directory));
    }

    #[test]
    fn the_starter_resolves_to_the_defaults_rather_than_pinning_them() {
        let resolved = resolve(STARTER);
        assert!(resolved.diagnostics.is_empty(), "{:?}", resolved.diagnostics);
        assert_eq!(
            resolved.snapshot_json(),
            Resolved::defaults().snapshot_json(),
            "a starter that set a key would pin today's answer forever"
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
    fn a_missing_file_is_the_default_install_and_says_nothing_about_it() {
        let resolved = load(&PathBuf::from("/nowhere/slopdesk/config.toml"));
        assert_eq!(resolved, Resolved::defaults());
        assert!(resolved.diagnostics().is_empty());
    }

    #[test]
    fn a_file_that_is_a_directory_is_a_diagnostic_rather_than_a_silent_default() {
        let resolved = load(&PathBuf::from("/tmp"));
        assert!(!resolved.diagnostics().is_empty());
        assert_eq!(
            resolved.value("controls.copy-on-select"),
            Some(&Value::Flag(false))
        );
    }
}

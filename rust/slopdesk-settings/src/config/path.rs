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

    use super::{CONFIG_FILE_ENV_KEY, default_path, load, resolve_path};
    use crate::config::{Resolved, Value};

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

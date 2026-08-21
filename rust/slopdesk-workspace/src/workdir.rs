//! Where a freshly-opened pane starts.
//!
//! The `working-directory` config, which a new window, tab or split reads to pick its initial cwd.
//! Three answers hide behind one stored string, and the string is the user's, so this is a
//! validate-then-repair parse: it never rejects and never traps.
//!
//! ## Naming no directory is an answer
//!
//! [`Policy::Home`] resolves to NO cwd, which the host turns into `$HOME` — it must, because the
//! child is forked and `execve`d rather than logged in, so without an explicit change it would
//! silently inherit whatever directory the daemon happened to be launched from. That is a different
//! thing from "leave the child where it lands", and the difference is why the absent answer is
//! spelled rather than defaulted.

/// How a freshly-opened pane chooses its initial working directory.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Policy {
    /// Start in the ACTIVE pane's last-known cwd.
    Inherit,
    /// Start in the shell's login directory — no cwd of its own.
    #[default]
    Home,
    /// Start in a fixed path the user configured.
    Path(String),
}

impl Policy {
    /// Decodes a stored `working-directory` config string.
    ///
    /// The value is trimmed first, so a config file with a stray newline still names the directory
    /// its author meant. A trimmed-empty string is [`Home`](Self::Home) rather than a path to
    /// nowhere: an unset setting and an explicit `home` mean the same thing.
    #[must_use]
    pub fn parse(raw: &str) -> Self {
        match raw.trim() {
            "inherit" => Self::Inherit,
            "" | "home" => Self::Home,
            path => Self::Path(path.to_owned()),
        }
    }

    /// The stored config string for this policy — the inverse of [`parse`](Self::parse).
    #[must_use]
    pub fn raw_config(&self) -> &str {
        match self {
            Self::Inherit => "inherit",
            Self::Home => "home",
            Self::Path(path) => path,
        }
    }

    /// Which of the three answers this policy is, without its payload.
    #[must_use]
    pub const fn kind(&self) -> Kind {
        match self {
            Self::Inherit => Kind::Inherit,
            Self::Home => Kind::Home,
            Self::Path(_) => Kind::Path,
        }
    }
}

/// A policy without its payload — what a caller that holds the strings itself needs to name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Kind {
    /// [`Policy::Inherit`].
    Inherit,
    /// [`Policy::Home`].
    #[default]
    Home,
    /// [`Policy::Path`].
    Path,
}

/// WHERE a new pane's cwd comes from, named rather than copied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Nowhere — send no change, and let the host resolve the login directory.
    None,
    /// The path the config named.
    ConfiguredPath,
    /// The active pane's last-known cwd.
    ActivePaneCwd,
}

/// Which string a new pane's cwd comes from.
///
/// Answering with a NAME rather than the text means a caller that already holds both strings —
/// every caller does — copies nothing to ask.
#[must_use]
pub const fn source(kind: Kind, active_pane_cwd_known: bool) -> Source {
    match kind {
        Kind::Inherit if active_pane_cwd_known => Source::ActivePaneCwd,
        Kind::Inherit | Kind::Home => Source::None,
        Kind::Path => Source::ConfiguredPath,
    }
}

#[cfg(test)]
mod tests {
    use super::{Kind, Policy, Source, source};

    #[test]
    fn an_unset_setting_and_an_explicit_home_are_the_same_answer() {
        assert_eq!(Policy::parse(""), Policy::Home);
        assert_eq!(Policy::parse("   \n"), Policy::Home);
        assert_eq!(Policy::parse("home"), Policy::Home);
    }

    #[test]
    fn a_path_keeps_its_trimmed_self_and_round_trips() {
        let parsed = Policy::parse("  /Users/me/src\n");
        assert_eq!(parsed, Policy::Path("/Users/me/src".to_owned()));
        assert_eq!(parsed.raw_config(), "/Users/me/src");
        assert_eq!(Policy::parse(parsed.raw_config()), parsed);
        assert_eq!(Policy::parse(Policy::Inherit.raw_config()), Policy::Inherit);
        assert_eq!(Policy::parse(Policy::Home.raw_config()), Policy::Home);
    }

    #[test]
    fn a_near_miss_is_a_path_rather_than_a_repair() {
        // The two keywords are exact: anything else is a directory the user named, even where it
        // looks like a typo, because guessing would open the pane somewhere they did not ask for.
        assert_eq!(Policy::parse("Inherit"), Policy::Path("Inherit".to_owned()));
        assert_eq!(Policy::parse("~/home"), Policy::Path("~/home".to_owned()));
    }

    /// Including the one rule a caller could get wrong on its own: inheriting an UNKNOWN directory
    /// inherits nothing, rather than falling through to the configured path.
    #[test]
    fn the_source_names_the_string_rather_than_copying_it() {
        assert_eq!(source(Kind::Inherit, true), Source::ActivePaneCwd);
        assert_eq!(source(Kind::Inherit, false), Source::None);
        assert_eq!(source(Kind::Home, true), Source::None, "home names no directory");
        assert_eq!(source(Kind::Path, false), Source::ConfiguredPath);
        assert_eq!(
            source(Policy::Path("/srv".to_owned()).kind(), true),
            Source::ConfiguredPath
        );
    }
}

//! What a pane's login shell is HANDED — the curated child environment, the shell to exec, and the
//! `argv[0]` that makes it a login shell.
//!
//! The spawn itself is hostd's: it holds the PTY master and calls `posix_spawn`. What is here is
//! everything it had to DECIDE first, expressed over plain strings so it can be exercised without a
//! descriptor — the same split [`crate::resize_fold`] makes for the grid ioctl.
//!
//! ## Why the parent's environment is an ALLOWLIST and not a filter
//! hostd is launched from whatever shell, `launchd` job or CI runner the user happened to use, and
//! its environment carries that provenance. A child that inherits it wholesale reports the
//! LAUNCHER's identity: `TERM_PROGRAM=Apple_Terminal` makes Amazon-Q/Fig's shell hooks
//! `cwterm`-exec a nested pseudo-terminal mid-`.zshrc`, and a `PATH` assembled by a CI image is not
//! one a user's login profile expects to extend. So nothing crosses that is not named here, and the
//! four things that MUST be ours are set unconditionally afterwards.
//!
//! ## Why `TERMINFO`/`TERMINFO_DIRS` are among the named
//! The host's terminfo probe runs with hostd's OWN environment and honours them when deciding
//! whether `xterm-ghostty` resolves. If hostd was launched from a shell whose `TERMINFO` points at
//! a Nix/Homebrew/per-user directory holding the ghostty entry, the probe says "resolvable" and the
//! host advertises `TERM=xterm-ghostty` — but a child lacking those vars searches only the default
//! directories, fails to find the entry, and every TUI degrades. Forwarding them makes the child's
//! ncurses search the SAME directories the probe used, so a "resolvable" verdict is honoured.
//!
//! ## What is NOT decided here
//! `TERM` and `TERM_PROGRAM_VERSION` are PARAMETERS. The version is a release-owned site — `make
//! release` rewrites every place the marketing version is typed — and minting a second one inside a
//! crate the release tool does not know about would break the bump silently. `TERM` is a parameter
//! because the caller picks between the ghostty entry and the `xterm-256color` fallback on the
//! probe's verdict, which is a filesystem question and not this module's.

use std::collections::BTreeMap;

/// The parent variables mirrored into the child WHEN PRESENT.
///
/// Identity, locale, and the two terminfo search paths the module doc argues for. `TERM_PROGRAM` is
/// deliberately absent: the child must report OURS.
pub const MIRRORED_KEYS: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "TERMINFO",
    "TERMINFO_DIRS",
];

/// The shell-integration opt-outs, forwarded from hostd's parent into the child when set.
///
/// Each is read DOWNSTREAM of hostd — `SLOPDESK_SHELL_INTEGRATION` by superd, which decides whether
/// to generate the shim at all, and the other two by the generated `.zshrc` inside the spawned zsh
/// (`${SLOPDESK_OSC133:-1}`, `${SLOPDESK_SHELL_CURSOR:-1}`). None of them is hostd's to interpret;
/// hostd's only job is not to drop them, which an allowlist would otherwise do.
pub const SHELL_INTEGRATION_KEYS: &[&str] = &[
    "SLOPDESK_SHELL_INTEGRATION",
    "SLOPDESK_OSC133",
    "SLOPDESK_SHELL_CURSOR",
];

/// The terminal-program identity advertised as `TERM_PROGRAM`, and as the Amazon-Q/Fig `CW_TERM`.
///
/// Setting `CW_TERM` is what tells those hooks they are on a supported host, so they do NOT re-exec
/// a nested pseudo-terminal mid-`.zshrc`.
pub const TERM_PROGRAM: &str = "slopdesk";

/// The `PATH` a child gets when the parent has none.
///
/// Deliberately conservative rather than inherited: the login shell re-derives its own from its
/// profile a moment later, and this only has to be enough to FIND that profile.
pub const FALLBACK_PATH: &str = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// The locale a child gets when the parent named none. UTF-8 end-to-end is not a preference here —
/// the wire, the replay passes and the client's renderer all assume it.
pub const FALLBACK_LANG: &str = "en_US.UTF-8";

/// The login shell used when `$SHELL` is unset or not absolute.
pub const FALLBACK_SHELL: &str = "/bin/zsh";

/// The PTY env var carrying the agent-hook listener socket path (Muxy's `MUXY_SOCKET_PATH` analog).
/// The installed hook relay POSTs to it; absent makes the hook a silent no-op.
pub const AGENT_SOCKET_KEY: &str = "SLOPDESK_SOCKET_PATH";

/// The PTY env var carrying the pane id a hook event should be tagged with (`MUXY_PANE_ID`).
pub const AGENT_PANE_ID_KEY: &str = "SLOPDESK_PANE_ID";

/// The agent-control socket path, exported only into panes of a host that CLAIMED that listener.
pub const AGENT_CONTROL_SOCKET_KEY: &str = "SLOPDESK_CONTROL_SOCKET";

/// The optional exports a curated environment carries on top of the defaults, each absent unless
/// the caller has one.
#[derive(Debug, Clone, Copy, Default)]
pub struct Exports<'a> {
    /// `SLOPDESK_SOCKET_PATH` — where an installed hook relay POSTs.
    pub agent_socket_path: Option<&'a str>,
    /// `SLOPDESK_PANE_ID` — which pane a hook event belongs to.
    pub pane_id: Option<&'a str>,
    /// `SLOPDESK_CONTROL_SOCKET` — the ctl socket, when hostd claimed the listener.
    pub control_socket_path: Option<&'a str>,
}

/// The curated child environment: the allowlist off `parent`, then the terminal defaults, then
/// whatever of [`Exports`] the caller has.
///
/// A `BTreeMap` rather than a `HashMap` so the answer has ONE ordering. The map crosses to Swift as
/// a flat blob and a `posix_spawn` `envp` is an array either way — an order that varied per run
/// would make two spawns of the same pane differ in a diff for no reason anybody could act on.
#[must_use]
pub fn curated(
    parent: &BTreeMap<String, String>,
    term: &str,
    version: &str,
    exports: Exports<'_>,
) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = BTreeMap::new();

    for key in MIRRORED_KEYS {
        if let Some(value) = parent.get(*key) {
            env.insert((*key).to_owned(), value.clone());
        }
    }

    env.entry("LANG".to_owned())
        .or_insert_with(|| FALLBACK_LANG.to_owned());
    env.insert("TERM".to_owned(), term.to_owned());
    env.insert("COLORTERM".to_owned(), "truecolor".to_owned());
    env.insert("NCURSES_NO_UTF8_ACS".to_owned(), "1".to_owned());

    env.insert("TERM_PROGRAM".to_owned(), TERM_PROGRAM.to_owned());
    env.insert("TERM_PROGRAM_VERSION".to_owned(), version.to_owned());
    env.insert("CW_TERM".to_owned(), TERM_PROGRAM.to_owned());

    let path = parent
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| FALLBACK_PATH.to_owned());
    env.insert("PATH".to_owned(), path);

    for key in SHELL_INTEGRATION_KEYS {
        if let Some(value) = parent.get(*key) {
            env.insert((*key).to_owned(), value.clone());
        }
    }

    for (key, value) in [
        (AGENT_SOCKET_KEY, exports.agent_socket_path),
        (AGENT_PANE_ID_KEY, exports.pane_id),
        (AGENT_CONTROL_SOCKET_KEY, exports.control_socket_path),
    ] {
        if let Some(value) = value {
            env.insert(key.to_owned(), value.to_owned());
        }
    }

    env
}

/// The user's login shell: `$SHELL` when it is set and ABSOLUTE, else [`FALLBACK_SHELL`].
///
/// Absolute rather than merely non-empty because this string is handed to `posix_spawn`, which does
/// no `PATH` search — a relative `$SHELL` would be resolved against a working directory nobody
/// promised, and the failure would be a pane that opens and immediately dies.
#[must_use]
pub fn login_shell(parent: &BTreeMap<String, String>) -> &str {
    match parent.get("SHELL") {
        Some(shell) if shell.starts_with('/') => shell,
        _ => FALLBACK_SHELL,
    }
}

/// The login shell's `argv[0]`: the basename with a leading `-`, which is the only thing that makes
/// zsh/bash source `.zprofile`/`.zshrc` instead of starting as a plain interactive shell.
///
/// A trailing slash yields `-`, which is what a caller handing this a directory deserves and is
/// still a valid argv entry — an empty string would make `posix_spawn` exec a shell that cannot
/// tell what it was invoked as.
#[must_use]
pub fn login_argv0(shell: &str) -> String {
    let base = shell.rsplit('/').next().unwrap_or(shell);
    format!("-{base}")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{
        AGENT_CONTROL_SOCKET_KEY, AGENT_PANE_ID_KEY, AGENT_SOCKET_KEY, Exports, FALLBACK_LANG, FALLBACK_PATH,
        FALLBACK_SHELL, TERM_PROGRAM, curated, login_argv0, login_shell,
    };

    fn parent(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn an_empty_parent_still_yields_a_usable_shell_environment() {
        let env = curated(&parent(&[]), "xterm-ghostty", "9.9.9", Exports::default());
        assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-ghostty"));
        assert_eq!(env.get("LANG").map(String::as_str), Some(FALLBACK_LANG));
        assert_eq!(env.get("PATH").map(String::as_str), Some(FALLBACK_PATH));
        assert_eq!(env.get("COLORTERM").map(String::as_str), Some("truecolor"));
        assert_eq!(env.get("NCURSES_NO_UTF8_ACS").map(String::as_str), Some("1"));
        assert_eq!(env.get("TERM_PROGRAM").map(String::as_str), Some(TERM_PROGRAM));
        assert_eq!(env.get("CW_TERM").map(String::as_str), Some(TERM_PROGRAM));
        assert_eq!(env.get("TERM_PROGRAM_VERSION").map(String::as_str), Some("9.9.9"));
        assert!(!env.contains_key("HOME"), "nothing invented for an absent parent");
    }

    #[test]
    fn the_launchers_identity_never_crosses() {
        let env = curated(
            &parent(&[
                ("TERM_PROGRAM", "Apple_Terminal"),
                ("TERM_PROGRAM_VERSION", "455"),
                ("CW_TERM", "iTerm.app"),
                ("TERM", "xterm-256color"),
                ("SSH_AUTH_SOCK", "/private/tmp/agent"),
                ("EDITOR", "vim"),
            ]),
            "xterm-ghostty",
            "0.0.1",
            Exports::default(),
        );
        assert_eq!(env.get("TERM_PROGRAM").map(String::as_str), Some(TERM_PROGRAM));
        assert_eq!(env.get("TERM_PROGRAM_VERSION").map(String::as_str), Some("0.0.1"));
        assert_eq!(env.get("CW_TERM").map(String::as_str), Some(TERM_PROGRAM));
        assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-ghostty"));
        assert!(!env.contains_key("SSH_AUTH_SOCK"), "not on the allowlist");
        assert!(!env.contains_key("EDITOR"), "not on the allowlist");
    }

    #[test]
    fn the_mirrored_keys_cross_including_both_terminfo_paths() {
        let env = curated(
            &parent(&[
                ("HOME", "/Users/x"),
                ("USER", "x"),
                ("LOGNAME", "x"),
                ("SHELL", "/bin/fish"),
                ("TMPDIR", "/tmp/x/"),
                ("LC_ALL", "C"),
                ("TERMINFO", "/nix/terminfo"),
                ("TERMINFO_DIRS", "/nix/terminfo:/usr/share/terminfo"),
                ("PATH", "/opt/homebrew/bin"),
            ]),
            "xterm-ghostty",
            "0.0.1",
            Exports::default(),
        );
        assert_eq!(env.get("HOME").map(String::as_str), Some("/Users/x"));
        assert_eq!(env.get("TERMINFO").map(String::as_str), Some("/nix/terminfo"));
        assert_eq!(
            env.get("TERMINFO_DIRS").map(String::as_str),
            Some("/nix/terminfo:/usr/share/terminfo")
        );
        assert_eq!(env.get("PATH").map(String::as_str), Some("/opt/homebrew/bin"));
        assert_eq!(
            env.get("LANG").map(String::as_str),
            Some(FALLBACK_LANG),
            "LC_ALL is not LANG"
        );
    }

    #[test]
    fn a_parents_lang_is_kept_rather_than_defaulted() {
        let env = curated(&parent(&[("LANG", "fr_FR.UTF-8")]), "t", "v", Exports::default());
        assert_eq!(env.get("LANG").map(String::as_str), Some("fr_FR.UTF-8"));
    }

    #[test]
    fn the_shell_integration_opt_outs_survive_the_allowlist() {
        let env = curated(
            &parent(&[("SLOPDESK_OSC133", "0"), ("SLOPDESK_AGENT_CONTROL", "1")]),
            "t",
            "v",
            Exports::default(),
        );
        assert_eq!(env.get("SLOPDESK_OSC133").map(String::as_str), Some("0"));
        assert!(
            !env.contains_key("SLOPDESK_AGENT_CONTROL"),
            "a hostd-side gate is not a child's business"
        );
    }

    #[test]
    fn each_export_appears_only_when_the_caller_has_one() {
        let bare = curated(&parent(&[]), "t", "v", Exports::default());
        assert!(!bare.contains_key(AGENT_SOCKET_KEY));
        assert!(!bare.contains_key(AGENT_PANE_ID_KEY));
        assert!(!bare.contains_key(AGENT_CONTROL_SOCKET_KEY));

        let full = curated(&parent(&[]), "t", "v", Exports {
            agent_socket_path: Some("/tmp/hook.sock"),
            pane_id: Some("ABC"),
            control_socket_path: Some("/tmp/ctl.sock"),
        });
        assert_eq!(
            full.get(AGENT_SOCKET_KEY).map(String::as_str),
            Some("/tmp/hook.sock")
        );
        assert_eq!(full.get(AGENT_PANE_ID_KEY).map(String::as_str), Some("ABC"));
        assert_eq!(
            full.get(AGENT_CONTROL_SOCKET_KEY).map(String::as_str),
            Some("/tmp/ctl.sock")
        );
    }

    #[test]
    fn only_an_absolute_shell_is_believed() {
        assert_eq!(login_shell(&parent(&[("SHELL", "/bin/fish")])), "/bin/fish");
        assert_eq!(login_shell(&parent(&[("SHELL", "fish")])), FALLBACK_SHELL);
        assert_eq!(login_shell(&parent(&[("SHELL", "")])), FALLBACK_SHELL);
        assert_eq!(login_shell(&parent(&[])), FALLBACK_SHELL);
    }

    #[test]
    fn argv0_is_the_basename_with_the_login_dash() {
        assert_eq!(login_argv0("/bin/zsh"), "-zsh");
        assert_eq!(login_argv0("/opt/homebrew/bin/fish"), "-fish");
        assert_eq!(login_argv0("zsh"), "-zsh");
        assert_eq!(login_argv0("/bin/"), "-");
    }
}

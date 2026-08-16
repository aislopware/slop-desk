//! Who is holding a pane's PTY foreground: is it `claude`, or something that commonly WRAPS one?
//!
//! Pure string logic on a process name, validate-then-drop: every input is tolerated — empty, huge,
//! hostile, non-ASCII — and nothing here can fail.
//!
//! ## It reads a process name and nothing else
//! This used to read SCREENS too — a coarse status over three tables of literal Claude TUI cues,
//! the herdr-style no-hooks fallback from docs/41. That was a second screen matcher living beside
//! the manifest rule ladder, and it lost: the ladder covers nineteen agents with upstream's own
//! rules and a differential harness proving it, while the cue tables covered one agent by hand. The
//! ladder is `slopdesk-screend` (docs/52) and this module kept the half that was never about a
//! screen. [`ClaudeSignal::ManifestVerdict`](crate::signal::ClaudeSignal::ManifestVerdict) — the
//! signal those cues fed — is still in the state machine, because a coarse verdict from ANY source
//! folds through it.

/// Known wrapper and runtime basenames, matched exactly like the `claude` presence match.
const WRAPPER_BASENAMES: [&str; 5] = ["node", "npx", "bun", "deno", "mise"];

/// True when the foreground process basename is exactly `claude`.
///
/// An exact basename match, so there is no substring false positive: `claudefoo` is not claude.
#[must_use]
pub fn is_claude_running(process_name: &str) -> bool {
    basename(process_name) == "claude"
}

/// True when the foreground basename is a known LAUNCHER or RUNTIME that commonly hosts a *wrapped*
/// `claude`.
///
/// The npm-installed `claude` bin is a `#!/usr/bin/env node` shebang, so the PTY foreground
/// resolves to `node`; the `npx` / `bun` / `deno` runtimes and `mise` shims likewise never classify
/// as `claude`.
///
/// A wrapper is **NOT presence** — it must never lift the presence floor, or any `node` dev server
/// would light the agent dot. It only makes an ABSENCE *indeterminate*, so the ~1 Hz foreground
/// poll does not terminate a hook-established status while the wrapper holds the PTY foreground.
///
/// Shells are deliberately NOT listed: the shell returning to the foreground is the classic "the
/// agent exited" signal.
#[must_use]
pub fn is_likely_wrapper(process_name: &str) -> bool {
    WRAPPER_BASENAMES.contains(&basename(process_name))
}

/// The basenames a foreground process must NOT be asked to do anything to: credential prompts and
/// remote-shell entry points. Matched CASE-SENSITIVELY against the basename, because that is how a
/// Unix host spells a program name — `SSH` is a different file from `ssh`.
///
/// The set is the whole rule: the gate that reads it refuses the RPC outright, so a name added here
/// closes a door for every caller at once. Deliberately bounded — a heuristic that guessed would
/// either block a pane a user meant to drive, or miss the one that mattered.
const SENSITIVE_BASENAMES: [&str; 11] = [
    "ssh",
    "sshpass",
    "ssh-agent",
    "ssh-add",
    "sudo",
    "doas",
    "su",
    "login",
    "passwd",
    "gpg",
    "security",
];

/// The layout components a version-named executable hides behind: none of them names a program.
const LAYOUT_COMPONENTS: [&str; 4] = ["versions", "bin", "current", "libexec"];

/// Whether `process_name` names a session the control RPC must not touch.
///
/// An EMPTY / unresolved name is NOT sensitive: the host could not prove a sensitive session, the
/// send-keys gate already guards the mutating path, and failing closed on an unresolved probe would
/// refuse a pane nobody is protecting.
#[must_use]
pub fn is_sensitive(process_name: &str) -> bool {
    SENSITIVE_BASENAMES.contains(&basename(process_name))
}

/// The CANONICAL name of an executable path: its basename, except when the executable is NAMED BY
/// ITS VERSION, in which case the owning app directory names it.
///
/// The Claude Code native installer lays the binary out as `…/.local/share/claude/versions/2.1.218`
/// — the executable file IS the version string. The raw basename would defeat the exact-basename
/// `claude` match AND read as a meaningless `2.1.218` in the sidebar's shell-label slot. A version
/// string names a RELEASE, not a program, so walk up past it and past the layout components until a
/// real name appears. Any non-version basename is returned untouched, so every other program keeps
/// exact-basename semantics.
#[must_use]
pub fn canonical_name(path: &str) -> &str {
    let base = basename(path);
    if !is_version_shaped(base) {
        return base;
    }
    let mut components: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    components.pop();
    for component in components.into_iter().rev() {
        if is_version_shaped(component) {
            continue;
        }
        if LAYOUT_COMPONENTS
            .iter()
            .any(|layout| layout.eq_ignore_ascii_case(component))
        {
            continue;
        }
        return component;
    }
    base
}

/// Whether `text` is a pure version string (`2.1.218`, `v1.0`): digits and dots after an optional
/// leading `v`, with at least one dot so a bare numeral (`7z`-style names, `2`) stays a name.
#[must_use]
pub fn is_version_shaped(text: &str) -> bool {
    let rest = text.strip_prefix(['v', 'V']).unwrap_or(text);
    !rest.is_empty() && rest.contains('.') && rest.chars().all(|c| c.is_ascii_digit() || c == '.')
}

/// The last NON-EMPTY `/`-separated component, falling back to the whole input when there is none.
///
/// Deliberately `/`-only rather than the `kind` module's two-separator split: this answers what the
/// PTY foreground poll reported on a Unix host, and a backslash there is a filename character.
///
/// Empty components are skipped, so a trailing slash does not hide the name behind it — an exec'd
/// path is spelled by whoever exec'd it, and `/usr/local/bin/claude/` is still claude. `"/"` has no
/// component, so it answers `"/"`: total on every input, and the answer that matters is that it
/// equals no program name, so it can never be an agent nor a sensitive session. The fallback is
/// what makes this usable as a LABEL too — a pane titled with the raw input beats one titled with
/// nothing.
#[must_use]
pub fn basename(process_name: &str) -> &str {
    process_name
        .split('/')
        .rfind(|component| !component.is_empty())
        .unwrap_or(process_name)
}

#[cfg(test)]
mod tests {
    use super::{canonical_name, is_claude_running, is_likely_wrapper, is_sensitive, is_version_shaped};

    #[test]
    fn a_trailing_slash_does_not_hide_the_name_behind_it() {
        assert!(is_claude_running("/usr/local/bin/claude/"));
        assert!(is_likely_wrapper("/opt/homebrew/bin/node//"));
        // A path with no component at all is nobody: the root must never read as an agent.
        assert!(!is_claude_running("/"));
        assert!(!is_claude_running("///"));
        assert!(!is_claude_running(""));
    }

    #[test]
    fn a_bare_name_and_a_full_path_both_name_claude() {
        assert!(is_claude_running("claude"));
        assert!(is_claude_running("/usr/local/bin/claude"));
        assert!(is_claude_running("/opt/homebrew/bin/claude"));
    }

    #[test]
    fn a_substring_never_passes_for_the_agent() {
        for stranger in ["", "claudefoo", "myclaude", "claude-code", "Claude", "claude "] {
            assert!(!is_claude_running(stranger), "{stranger:?}");
        }
    }

    #[test]
    fn the_runtimes_that_host_a_wrapped_agent_are_wrappers() {
        for wrapper in ["node", "npx", "bun", "deno", "mise", "/usr/local/bin/node"] {
            assert!(is_likely_wrapper(wrapper), "{wrapper}");
        }
    }

    #[test]
    fn a_shell_is_not_a_wrapper_because_a_shell_returning_is_the_exit_signal() {
        for shell in ["zsh", "bash", "sh", "fish", "", "claude", "python3"] {
            assert!(!is_likely_wrapper(shell), "{shell:?}");
        }
    }

    #[test]
    fn a_version_named_executable_is_named_by_the_directory_that_owns_it() {
        assert_eq!(
            canonical_name("/Users/a/.local/share/claude/versions/2.1.218"),
            "claude"
        );
        assert_eq!(canonical_name("/opt/foo/versions/v1.2/bin/3.0.1"), "foo");
        // A name that is not a version is returned untouched, whatever sits above it.
        assert_eq!(canonical_name("/usr/local/bin/claude"), "claude");
        assert_eq!(canonical_name("zsh"), "zsh");
        assert_eq!(canonical_name(""), "");
        assert_eq!(
            canonical_name("/"),
            "/",
            "the root is its own answer, and it names no program"
        );
        // Nothing but layout and versions above it: the version string is the best answer left.
        assert_eq!(canonical_name("/versions/bin/2.0"), "2.0");
    }

    #[test]
    fn a_version_is_digits_and_dots_and_a_bare_numeral_is_a_name() {
        for version in ["2.1.218", "v1.0", "V0.0.1", "1.2"] {
            assert!(is_version_shaped(version), "{version}");
        }
        for name in ["", "v", "2", "7z", "claude", "1.2.3-beta", "node", "python3.11"] {
            assert!(!is_version_shaped(name), "{name}");
        }
        // Dots alone pass: nothing real is named `.` or `v.`, and tightening it would be a rule
        // change rather than a port. Pinned so a future tightening is a deliberate edit.
        assert!(is_version_shaped("."));
        assert!(is_version_shaped("v."));
    }

    #[test]
    fn the_sensitive_set_is_matched_on_the_basename_exactly() {
        for sensitive in ["ssh", "/usr/bin/sudo", "/opt/homebrew/bin/gpg", "ssh-add"] {
            assert!(is_sensitive(sensitive), "{sensitive}");
        }
        // Not sensitive: an unresolved probe, a substring, a different case, a lookalike.
        for benign in [
            "",
            "/",
            "zsh",
            "sshfs",
            "SSH",
            "sudoedit",
            "claude",
            "security-tool",
        ] {
            assert!(!is_sensitive(benign), "{benign}");
        }
    }
}

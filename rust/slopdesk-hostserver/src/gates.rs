//! hostd's own `SLOPDESK_*` gates, resolved ONCE, plus the two `TERM` names it advertises.
//!
//! `HostEnvironment.swift` is 350 lines of which almost everything is already
//! Rust: the curated allowlist and the two login-shell answers are
//! [`slopdesk_muxsession::spawn_env`]'s, the terminfo search order is `slopdesk-probe`'s, and the
//! five keys hostd EXPORTS into a spawned pane are named in `spawn_env` too
//! ([`slopdesk_muxsession::spawn_env::AGENT_SOCKET_KEY`] and its four neighbours). What was left
//! typed in Swift is what is here: the seven gates hostd READS about itself, and the pair of `TERM`
//! names.
//!
//! ## Why they are one table
//!
//! Each gate was a `static func` beside its own key, hand-writing one of the project's two polarity
//! idioms — `env[key] != "0"` for default-ON, `env[key] == "1"` for default-OFF (`docs/58`). Seven
//! hand-written comparisons is seven chances to write the wrong one, and the wrong one is silent:
//! a default-OFF gate spelled `!= "0"` ships ENABLED to every user who never set it, which for
//! `SLOPDESK_IPC_ALLOW_SEND_KEYS` means key injection into a live PTY. As a table the polarity is
//! declared once per row and `the_unset_environment_is_the_shipped_default` prints the whole
//! shipped answer in one place.
//!
//! ## The lookup is the caller's, exactly as `slopdesk_video::host_gates` has it
//!
//! [`KEYS`] is the list of names, in the order [`HostAgentGates::from_env`] expects their values.
//! The caller resolves each through the env → settings-overlay precedence (`docs/58`) and hands the
//! texts back. That is deliberately NOT `std::env::var` here: the overlay is a process-wide table
//! hostd folds `video-prefs.json` into at launch, and a gate that read the environment directly
//! would quietly stop honouring the setting the moment a user set one.
//!
//! ## What is NOT here, on purpose
//!
//! The build version. `HostEnvironment.buildVersion` is passed INTO `spawn_env` rather than minted
//! behind it because `just release` rewrites every site the marketing version is typed, and a copy
//! inside a crate the release tool does not scan is a version that silently stops being bumped.
//! That argument does not change by moving language, so it stays an argument here too.

/// The `TERM` a spawned shell advertises: the native libghostty entry the client renders, which
/// unlocks the kitty keyboard protocol and DEC 2026 synchronized output.
pub const DEFAULT_TERM: &str = "xterm-ghostty";

/// The entry every fallback lands on, present on effectively every Unix host.
///
/// This is the answer when the machine has no terminfo record for [`DEFAULT_TERM`] — Ghostty ships
/// that one, the base OS does not. Advertising an entry nobody verified is a guess; this one is
/// right either way.
pub const FALLBACK_TERM: &str = "xterm-256color";

// Both names live HERE rather than in `slopdesk_muxsession::spawn_env` because `spawn_env` resolves
// what it is handed and knows neither of them — the choice of what to advertise is hostd's, and
// hostd is what this crate composes.

/// The environment keys, in the order [`HostAgentGates::from_env`] reads their values.
///
/// One list, so a key cannot be resolved under one spelling and read under another.
pub const KEYS: [&str; 7] = [
    "SLOPDESK_AGENT_CONTROL",
    "SLOPDESK_BLOCKS",
    "SLOPDESK_AUTO_PROGRESS_COMMANDS",
    "SLOPDESK_IPC_ALLOW_SEND_KEYS",
    "SLOPDESK_IPC_ALLOW_SENSITIVE",
    "SLOPDESK_AGENT_PREVENT_SLEEP",
    "SLOPDESK_AGENT_RESUME_ON_RECOVERY",
];

/// hostd's resolved gates.
///
/// Borrowed rather than owned: the one non-boolean gate crosses to superd as-is, so copying it
/// here would buy nothing but an allocation on a path that already has the text.
// Six of the seven gates ARE switches, which is how they read on the wire, in `docs/58` and in the
// operator's head. Folding pairs into two-variant enums would name types nobody mentions twice.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a table of switches IS mostly switches"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostAgentGates<'a> {
    /// Whether hostd CLAIMS the agent-control listener — the ctl socket's `listen` for the
    /// `control` kind. Default-OFF: writing to PTYs and spawning shells is not something to enable
    /// silently. superd binds that socket either way and knows nothing about this flag; off means a
    /// spawned child sees no `SLOPDESK_CONTROL_SOCKET` at all (`docs/51` §6.6).
    pub agent_control: bool,
    /// Whether the host segments the outbound PTY stream into Warp-style Blocks — the additive
    /// `commandblocks` tap and the type-28/29 wire. Default-ON: with it off the byte pipeline and
    /// the live sniffer stay byte-identical, which is what makes the gate safe to leave on.
    pub blocks: bool,
    /// The client's "Auto Progress-Bar Commands" list, UNPARSED, for the spawn request to carry
    /// across as-is.
    ///
    /// Deliberately not a list: superd owns the parse AND the built-in slow-command table, and
    /// resolving either here would be the second copy of both. All three states survive the
    /// crossing — `None` UNSET means the built-ins, `Some("")` means DISABLED (the "clear the
    /// field" behaviour), anything else is the entries superd parses out.
    pub auto_progress_commands: Option<&'a str>,
    /// Whether the ctl socket may run its MUTATING verbs (`write`/`run`/`spawn`/`kill`/`resize`).
    /// Default-OFF; read-only verbs are always allowed regardless. Enforced host-side on the
    /// existing NDJSON socket — no new socket, no tokens, no crypto, because the `WireGuard` mesh
    /// is the security boundary.
    pub ipc_allow_send_keys: bool,
    /// Whether a mutating ctl verb may target a SENSITIVE foreground session (`ssh`/`sudo`/`login`
    /// and friends). Default-OFF, and independent of [`Self::ipc_allow_send_keys`]: this one is
    /// asked only once that one has already said yes.
    pub ipc_allow_sensitive: bool,
    /// Whether the host holds a system-sleep assertion while ANY agent is processing. Default-OFF:
    /// blocking system sleep is not something to enable silently. Driven off the `working`
    /// aggregate hostd already computes.
    pub agent_prevent_sleep: bool,
    /// Whether the host re-arms a detached agent session on connection recovery. Default-ON:
    /// re-arming a recovered session is the helpful default, opt-OUT only. AND-ed into the detach
    /// machinery, so OFF makes a recovered terminal spawn a fresh shell instead of reattaching the
    /// still-running agent.
    pub agent_resume_on_recovery: bool,
}

/// A switch that is ON unless the value is exactly `"0"` — the project's default-ON idiom.
fn default_on(raw: Option<&str>) -> bool {
    raw != Some("0")
}

/// A switch that is OFF unless the value is exactly `"1"` — the project's default-OFF idiom.
fn default_off(raw: Option<&str>) -> bool {
    raw == Some("1")
}

impl<'a> HostAgentGates<'a> {
    /// Resolves the gates from the texts of [`KEYS`], in that order.
    ///
    /// A value list shorter than [`KEYS`], or a `None` entry, is an unset key — so a caller that
    /// has not caught up with a new gate gets that gate's default rather than a panic.
    #[must_use]
    pub fn from_env(values: &[Option<&'a str>]) -> Self {
        let at = |key: &str| -> Option<&'a str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };

        Self {
            agent_control: default_off(at("SLOPDESK_AGENT_CONTROL")),
            blocks: default_on(at("SLOPDESK_BLOCKS")),
            auto_progress_commands: at("SLOPDESK_AUTO_PROGRESS_COMMANDS"),
            ipc_allow_send_keys: default_off(at("SLOPDESK_IPC_ALLOW_SEND_KEYS")),
            ipc_allow_sensitive: default_off(at("SLOPDESK_IPC_ALLOW_SENSITIVE")),
            agent_prevent_sleep: default_off(at("SLOPDESK_AGENT_PREVENT_SLEEP")),
            agent_resume_on_recovery: default_on(at("SLOPDESK_AGENT_RESUME_ON_RECOVERY")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_TERM, FALLBACK_TERM, HostAgentGates, KEYS};

    fn resolve<'a>(pairs: &[(&str, &'a str)]) -> HostAgentGates<'a> {
        let values: Vec<Option<&'a str>> = KEYS
            .iter()
            .map(|key| {
                pairs
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, value)| *value)
            })
            .collect();
        HostAgentGates::from_env(&values)
    }

    /// The whole shipped answer, in one place. If one of these flips, hostd's out-of-the-box
    /// behaviour flipped with it — and the three that must stay `false` are the ones that let a
    /// remote caller type into somebody's shell.
    #[test]
    fn the_unset_environment_is_the_shipped_default() {
        let gates = resolve(&[]);
        assert!(!gates.agent_control, "claiming the ctl listener is opt-in");
        assert!(gates.blocks, "the Blocks tap is on and costs nothing off");
        assert_eq!(
            gates.auto_progress_commands, None,
            "unset means superd's built-in slow-command list, not an empty one"
        );
        assert!(!gates.ipc_allow_send_keys, "key injection is opt-in");
        assert!(!gates.ipc_allow_sensitive, "an ssh prompt is opt-in twice");
        assert!(!gates.agent_prevent_sleep, "blocking sleep is opt-in");
        assert!(gates.agent_resume_on_recovery, "resuming is the helpful default");
    }

    /// EVERY key is wired to a field: each one, set alone to a value that must move the answer,
    /// moves it. A key resolved under a name no arm reads would silently answer its default here,
    /// which is exactly the failure a positional table invites.
    #[test]
    fn every_key_reaches_a_field() {
        let flipping: [(&str, &str); 7] = [
            ("SLOPDESK_AGENT_CONTROL", "1"),
            ("SLOPDESK_BLOCKS", "0"),
            ("SLOPDESK_AUTO_PROGRESS_COMMANDS", "git push"),
            ("SLOPDESK_IPC_ALLOW_SEND_KEYS", "1"),
            ("SLOPDESK_IPC_ALLOW_SENSITIVE", "1"),
            ("SLOPDESK_AGENT_PREVENT_SLEEP", "1"),
            ("SLOPDESK_AGENT_RESUME_ON_RECOVERY", "0"),
        ];
        let defaults = resolve(&[]);
        for (key, value) in flipping {
            assert!(KEYS.contains(&key), "{key} is not in the key list");
            assert_ne!(
                resolve(&[(key, value)]),
                defaults,
                "{key}={value} changed nothing — no arm reads that name",
            );
        }
        assert_eq!(
            flipping.len(),
            KEYS.len(),
            "one flipping value per key, and no more"
        );
    }

    /// The default-OFF idiom, at the values that are NOT `"1"`. `"true"`, `"yes"` and `"0"` all
    /// leave the gate shut — an operator who typed one of those has not enabled key injection, and
    /// a table that answered otherwise would be generous in the one direction that costs.
    #[test]
    fn a_default_off_gate_opens_only_for_exactly_one() {
        for value in ["", "0", "true", "yes", "2", "1 ", " 1"] {
            assert!(
                !resolve(&[("SLOPDESK_IPC_ALLOW_SEND_KEYS", value)]).ipc_allow_send_keys,
                "{value:?} is not the literal 1"
            );
        }
        assert!(resolve(&[("SLOPDESK_IPC_ALLOW_SEND_KEYS", "1")]).ipc_allow_send_keys);
    }

    /// The default-ON idiom, at the values that are NOT `"0"`. Only the literal `"0"` disables —
    /// including the empty string, which is what an `export SLOPDESK_BLOCKS=` leaves behind.
    #[test]
    fn a_default_on_gate_shuts_only_for_exactly_zero() {
        for value in ["", "1", "false", "no", "00", "0 "] {
            assert!(
                resolve(&[("SLOPDESK_BLOCKS", value)]).blocks,
                "{value:?} is not the literal 0"
            );
        }
        assert!(!resolve(&[("SLOPDESK_BLOCKS", "0")]).blocks);
    }

    /// The one gate with three states rather than two, and the middle one is the reason it is not a
    /// boolean: an empty value is a user who CLEARED the field, which disables auto-progress
    /// entirely, and is a different answer from never having set it.
    #[test]
    fn an_empty_command_list_is_disabled_rather_than_unset() {
        assert_eq!(resolve(&[]).auto_progress_commands, None);
        assert_eq!(
            resolve(&[("SLOPDESK_AUTO_PROGRESS_COMMANDS", "")]).auto_progress_commands,
            Some("")
        );
        assert_eq!(
            resolve(&[("SLOPDESK_AUTO_PROGRESS_COMMANDS", "git push\ncargo build")]).auto_progress_commands,
            Some("git push\ncargo build"),
            "the newlines cross UNPARSED — superd owns the split"
        );
    }

    /// A caller that has not caught up with a new key gets that key's default, not a panic.
    #[test]
    fn a_short_value_list_resolves_to_defaults() {
        let gates = HostAgentGates::from_env(&[Some("1")]);
        assert!(gates.agent_control, "the value it DID pass is still read");
        assert!(
            gates.agent_resume_on_recovery,
            "and everything past its end is unset"
        );
    }

    /// The fallback is not the default, and both are the spellings terminfo actually indexes. A
    /// typo in either is a host where every curses app either refuses to start or picks the wrong
    /// key sequences, which no test downstream of here would catch.
    #[test]
    fn the_two_term_names_are_distinct_and_spelled_as_terminfo_has_them() {
        assert_eq!(DEFAULT_TERM, "xterm-ghostty");
        assert_eq!(FALLBACK_TERM, "xterm-256color");
        assert_ne!(DEFAULT_TERM, FALLBACK_TERM);
    }
}

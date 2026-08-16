//! The one badge a sidebar tab row shows, fused from everything the pane reports.
//!
//! A row has four independent signals — the agent's status, the stored exit-code badge, the live
//! busy bit, and the `OSC 9;4` progress mirror — plus the foreground process name, which can mark a
//! privileged or sleep-blocking session. Any of them can be true at once, and there is ONE slot.
//!
//! ## Fixed precedence
//!
//! ```text
//! awaitingInput > error > running(agent) > AGENT completed/finished > commandRunning >
//!   commandBusy > sudo > caffeinate > COMMAND completed/finished > nothing
//! ```
//!
//! The two placements that are not obvious, and are the whole reason this is a rule rather than a
//! sort: the AGENT finish sits ABOVE the busy tiers, because the `claude` process holds the shell's
//! OSC-133 block open for its entire interactive lifetime — checked later, a finished turn would be
//! shadowed by `is_busy` for hours and never show. A plain COMMAND's clean exit sits BELOW them,
//! because there a newly-running command genuinely supersedes the previous exit.
//!
//! Clock-free: whether a completion is still a fresh flash or has settled into the persistent
//! unread marker is an INPUT, decided by the store against its own `completedAt` mirror.

use crate::process;
use crate::status::ClaudeStatus;

/// Basenames that mark a PRIVILEGED session (the shield). Matched exactly against the lowercased
/// basename — never a substring, or `sudoedit-helper` would wear the shield.
const SUDO_BASENAMES: [&str; 2] = ["sudo", "su"];

/// Basenames that mark a SLEEP-BLOCKING session (the coffee cup).
const CAFFEINATE_BASENAMES: [&str; 1] = ["caffeinate"];

/// The fused state a tab row carries.
///
/// Declaration order is the FFI discriminant order, which `scripts/check-supervisor.sh` pins
/// against the Swift enum; it is deliberately not the precedence order, which is a rule and lives
/// in [`resolve`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TabBadge {
    /// A WORKING code agent — the agent-is-thinking tier.
    Running,
    /// An active `OSC 9;4;1`/`3` progress report with no agent working.
    CommandRunning,
    /// A plain busy shell: a foreground command runs, nothing more is known.
    CommandBusy,
    /// The brief success FLASH of a clean finish.
    Completed,
    /// The persistent unread marker a settled clean finish decays to.
    Finished,
    /// A non-zero exit, or a held-red `OSC 9;4;2`.
    Error,
    /// An agent blocked on a human. The most urgent state.
    AwaitingInput,
    /// A sleep-blocking session, shown only when the shell is otherwise at rest.
    Caffeinate,
    /// A privileged session, shown only when the shell is otherwise at rest.
    Sudo,
}

impl TabBadge {
    /// Every badge in declaration order — the discriminant order the FFI and the Swift enum share.
    pub const ALL: [Self; 9] = [
        Self::Running,
        Self::CommandRunning,
        Self::CommandBusy,
        Self::Completed,
        Self::Finished,
        Self::Error,
        Self::AwaitingInput,
        Self::Caffeinate,
        Self::Sudo,
    ];

    /// Whether this badge is ATTENTION-class — "finished, or waiting on you". The live activity
    /// tiers and the at-rest privilege markers are NOT attention: attention means unread, not busy.
    #[must_use]
    pub const fn needs_attention(self) -> bool {
        matches!(
            self,
            Self::AwaitingInput | Self::Completed | Self::Error | Self::Finished
        )
    }

    /// Whether this badge is a BUSY tier — something is in flight. The disjoint complement of
    /// [`needs_attention`](Self::needs_attention) minus the two privilege markers.
    #[must_use]
    pub const fn is_busy_tier(self) -> bool {
        matches!(self, Self::CommandBusy | Self::CommandRunning | Self::Running)
    }
}

/// The stored exit-code badge a background pane carries until it is looked at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Completion {
    /// Exited 0 (or with no exit code at all).
    Success,
    /// Exited non-zero.
    Failure,
}

/// Whether a clean completion is still showing its brief flash or has settled into the persistent
/// unread marker. An input, not a clock reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Freshness {
    /// Just completed — the brief [`TabBadge::Completed`] flash.
    Fresh,
    /// Settled past the flash, and the default for a completion with no recorded stamp.
    Settled,
}

/// The live `OSC 9;4` mirror. The percent never reaches this rule — only whether the indicator is
/// still going or has gone red — so it is not carried here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    /// `OSC 9;4;3` or `OSC 9;4;1;<pct>` — still going.
    Running,
    /// `OSC 9;4;2` — held red.
    Error,
}

/// Everything a row reports, in one value. Grouped rather than passed as seven positional arguments
/// so a caller cannot silently transpose two booleans.
#[derive(Clone, Copy, Debug)]
pub struct Signals<'a> {
    /// The rolled-up agent status for the pane.
    pub agent: ClaudeStatus,
    /// The stored exit-code badge, or `None`.
    pub completion: Option<Completion>,
    /// The live "a command is running" bit.
    pub is_busy: bool,
    /// The last foreground-process string the host reported. UNTRUSTED: a bare name, a full path,
    /// or anything at all.
    pub foreground: &'a str,
    /// Whether a clean completion still flashes.
    pub freshness: Freshness,
    /// The live progress mirror, or `None` when there is no indicator.
    pub progress: Option<Progress>,
    /// The client's UNREAD agent-finish latch: true from a `.done` edge the user was not watching,
    /// until the pane is visited. Keeps the finished marker alive across the host's own done→idle
    /// decay — the host forgets, the client remembers until seen.
    pub unseen_agent_done: bool,
}

/// The one badge for a row, or `None` when it is all-clear.
#[must_use]
pub fn resolve(signals: Signals<'_>) -> Option<TabBadge> {
    // 1. A blocked agent demands a human; highest urgency.
    if signals.agent == ClaudeStatus::NeedsPermission {
        return Some(TabBadge::AwaitingInput);
    }

    // 2. A failed command, or a held-red progress error. Either sits above a running spinner and above
    //    a stale completion dot.
    if signals.completion == Some(Completion::Failure) || signals.progress == Some(Progress::Error) {
        return Some(TabBadge::Error);
    }

    // 3. A working agent takes the agent tier.
    if signals.agent == ClaudeStatus::Working {
        return Some(TabBadge::Running);
    }

    // 3a. A finished agent turn, live or latched — ABOVE the busy tiers, per the module note.
    if signals.agent == ClaudeStatus::Done || signals.unseen_agent_done {
        return Some(settled_or_flash(signals.freshness));
    }

    // 3b. The quieter activity tiers: a progress report outranks a bare busy shell.
    if signals.progress == Some(Progress::Running) {
        return Some(TabBadge::CommandRunning);
    }
    if signals.is_busy {
        return Some(TabBadge::CommandBusy);
    }

    // 4 + 5. Privilege markers, only once the shell is at rest. Shield outranks coffee cup.
    if let Some(privilege) = privilege_badge(signals.foreground) {
        return Some(privilege);
    }

    // 6. A plain command's clean exit, below everything that is still happening.
    if signals.completion == Some(Completion::Success) {
        return Some(settled_or_flash(signals.freshness));
    }

    // 7. All clear.
    None
}

/// A clean finish as either its flash or its persistent marker.
const fn settled_or_flash(freshness: Freshness) -> TabBadge {
    match freshness {
        Freshness::Fresh => TabBadge::Completed,
        Freshness::Settled => TabBadge::Finished,
    }
}

/// The privilege marker for a foreground process name, or `None` for anything unknown.
///
/// Classified by an allow-set on the LOWERCASED basename, so a name that merely contains `sudo`
/// never wears the shield. Validate-then-default: an empty or unresolved name earns no badge.
fn privilege_badge(process: &str) -> Option<TabBadge> {
    let trimmed = process.trim();
    if trimmed.is_empty() {
        return None;
    }
    let base = process::basename(trimmed).to_lowercase();
    if SUDO_BASENAMES.contains(&base.as_str()) {
        return Some(TabBadge::Sudo);
    }
    if CAFFEINATE_BASENAMES.contains(&base.as_str()) {
        return Some(TabBadge::Caffeinate);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{Completion, Freshness, Progress, Signals, TabBadge, resolve};
    use crate::status::ClaudeStatus;

    /// A row with nothing happening on it.
    const fn quiet() -> Signals<'static> {
        Signals {
            agent: ClaudeStatus::None,
            completion: None,
            is_busy: false,
            foreground: "",
            freshness: Freshness::Settled,
            progress: None,
            unseen_agent_done: false,
        }
    }

    #[test]
    fn a_quiet_row_wears_nothing() {
        assert_eq!(resolve(quiet()), None);
    }

    #[test]
    fn a_blocked_agent_outranks_every_other_signal_at_once() {
        let everything = Signals {
            agent: ClaudeStatus::NeedsPermission,
            completion: Some(Completion::Failure),
            is_busy: true,
            foreground: "/usr/bin/sudo",
            freshness: Freshness::Fresh,
            progress: Some(Progress::Error),
            unseen_agent_done: true,
        };
        assert_eq!(resolve(everything), Some(TabBadge::AwaitingInput));
    }

    #[test]
    fn an_agent_finish_is_not_shadowed_by_the_shell_it_keeps_busy() {
        // The whole reason 3a sits above the busy tiers: `claude` holds the block open for hours.
        let done = Signals {
            agent: ClaudeStatus::Done,
            is_busy: true,
            ..quiet()
        };
        assert_eq!(resolve(done), Some(TabBadge::Finished));
        assert_eq!(
            resolve(Signals {
                freshness: Freshness::Fresh,
                ..done
            }),
            Some(TabBadge::Completed)
        );
        // The client's unread latch keeps it alive after the host has decayed done→idle.
        let latched = Signals {
            agent: ClaudeStatus::Idle,
            unseen_agent_done: true,
            is_busy: true,
            ..quiet()
        };
        assert_eq!(resolve(latched), Some(TabBadge::Finished));
    }

    #[test]
    fn a_commands_clean_exit_yields_to_anything_still_running() {
        let exited = Signals {
            completion: Some(Completion::Success),
            ..quiet()
        };
        assert_eq!(resolve(exited), Some(TabBadge::Finished));
        assert_eq!(
            resolve(Signals {
                is_busy: true,
                ..exited
            }),
            Some(TabBadge::CommandBusy)
        );
        assert_eq!(
            resolve(Signals {
                progress: Some(Progress::Running),
                ..exited
            }),
            Some(TabBadge::CommandRunning)
        );
        // …and to a privilege marker, which is itself only shown at rest.
        assert_eq!(
            resolve(Signals {
                foreground: "sudo",
                ..exited
            }),
            Some(TabBadge::Sudo)
        );
    }

    #[test]
    fn an_error_outranks_the_activity_tiers_but_not_a_blocked_agent() {
        assert_eq!(
            resolve(Signals {
                completion: Some(Completion::Failure),
                is_busy: true,
                ..quiet()
            }),
            Some(TabBadge::Error)
        );
        assert_eq!(
            resolve(Signals {
                progress: Some(Progress::Error),
                agent: ClaudeStatus::Working,
                ..quiet()
            }),
            Some(TabBadge::Error)
        );
    }

    #[test]
    fn a_privilege_marker_is_an_exact_lowercased_basename_and_nothing_else() {
        for shield in ["sudo", "/usr/bin/sudo", "  SUDO  ", "su", "/bin/SU"] {
            assert_eq!(
                resolve(Signals {
                    foreground: shield,
                    ..quiet()
                }),
                Some(TabBadge::Sudo),
                "{shield}"
            );
        }
        assert_eq!(
            resolve(Signals {
                foreground: "/usr/bin/caffeinate",
                ..quiet()
            }),
            Some(TabBadge::Caffeinate)
        );
        // A substring, a lookalike, an unresolved probe: no marker at all.
        for stranger in ["", "   ", "/", "sudoedit-helper", "pseudo", "zsh", "caffeinated"] {
            assert_eq!(
                resolve(Signals {
                    foreground: stranger,
                    ..quiet()
                }),
                None,
                "{stranger}"
            );
        }
    }

    #[test]
    fn attention_means_unread_and_busy_means_in_flight_and_they_never_overlap() {
        for badge in TabBadge::ALL {
            assert!(!(badge.needs_attention() && badge.is_busy_tier()), "{badge:?}");
        }
        assert!(TabBadge::AwaitingInput.needs_attention());
        assert!(TabBadge::Running.is_busy_tier());
        // The privilege markers are neither: they say what a session IS, not what it is doing.
        assert!(!TabBadge::Sudo.needs_attention() && !TabBadge::Sudo.is_busy_tier());
        assert!(!TabBadge::Caffeinate.needs_attention() && !TabBadge::Caffeinate.is_busy_tier());
    }
}

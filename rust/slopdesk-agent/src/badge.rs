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
/// Declaration order is the FFI discriminant order, which `rust/slopdesk-invariants` pins
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

    /// The state's WORD — the row title's accessibility value, the roll-up's spoken label.
    ///
    /// Three surfaces read it — the Mac's `AppKit` rows, the phone's `UIKit` rows and the
    /// collapsed-sidebar strip — and a word spelled twice is a state `VoiceOver` reads two ways on
    /// two devices. The colours are NOT here: a role resolves to an ink in the design floor.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Running => "Agent working",
            Self::CommandRunning => "Loading",
            Self::CommandBusy => "Running",
            Self::Completed => "Completed",
            Self::Finished => "Finished",
            Self::Error => "Error",
            Self::AwaitingInput => "Awaiting input",
            Self::Caffeinate => "Caffeinated",
            Self::Sudo => "Privileged",
        }
    }
}

/// The three states that WAIT ON YOU, as roles rather than hues.
///
/// The ink each takes is the view floor's answer; the ORDER they rank in is this module's, because
/// the collapsed-group roll-up has to pick a loudest one and both halves must pick the same.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attention {
    /// A question is blocking the agent. The most urgent — someone is waiting on a person.
    Awaiting,
    /// Something broke.
    Failed,
    /// A turn ended and the news is unread.
    Finished,
}

impl Attention {
    /// Every role, loudest first — the order [`rollup`] walks.
    pub const ALL: [Self; 3] = [Self::Awaiting, Self::Failed, Self::Finished];

    /// The code this role crosses as. `0` is reserved for "no role at all".
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Awaiting => 1,
            Self::Failed => 2,
            Self::Finished => 3,
        }
    }
}

/// A finished command's OUTCOME — the two readings the trailing slot has.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Exit 0, or a completion the shell reported no code for.
    Succeeded,
    /// A non-zero exit, or a held-red `OSC 9;4;2`.
    Failed,
}

impl Outcome {
    /// The code this outcome crosses as. `0` is reserved for "no outcome".
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Succeeded => 1,
            Self::Failed => 2,
        }
    }
}

/// The badge's attention role, or [`None`] for the states that are merely BUSY or merely
/// privileged.
///
/// Busy is not attention: a spinning agent is not waiting for anyone. This is the ROLE behind
/// [`TabBadge::needs_attention`], which answers the same question as a bare bit.
#[must_use]
pub const fn attention(badge: TabBadge) -> Option<Attention> {
    match badge {
        TabBadge::AwaitingInput => Some(Attention::Awaiting),
        TabBadge::Error => Some(Attention::Failed),
        // The completed/finished split is the freshness machinery's, not the reader's: a fresh
        // flash and a settled unread finish are the same news at two ages.
        TabBadge::Completed | TabBadge::Finished => Some(Attention::Finished),
        TabBadge::Caffeinate
        | TabBadge::CommandBusy
        | TabBadge::CommandRunning
        | TabBadge::Running
        | TabBadge::Sudo => None,
    }
}

/// The subset of [`attention`] that means *something is wrong or stopped and it is waiting on you*
/// — the two roles that take their hue across a whole row title.
///
/// A FINISH is deliberately absent: green is the "nothing is wrong, come look when you can" end of
/// the ramp, and spending the row on it would leave the urgent pair nothing louder to be.
#[must_use]
pub const fn urgent(badge: TabBadge) -> Option<Attention> {
    match attention(badge) {
        Some(Attention::Awaiting) => Some(Attention::Awaiting),
        Some(Attention::Failed) => Some(Attention::Failed),
        Some(Attention::Finished) | None => None,
    }
}

/// The strongest attention role among a collapsed group's hidden rows.
///
/// A waiting question outranks a failure outranks an unread finish, which is [`Attention::ALL`]'s
/// own order. [`None`] when nothing inside waits, so the header's count keeps the muted metadata
/// ink and folding a group never hides an agent that needs the eye.
#[must_use]
pub fn rollup(badges: &[Option<TabBadge>]) -> Option<Attention> {
    Attention::ALL.into_iter().find(|role| {
        badges
            .iter()
            .flatten()
            .copied()
            .filter_map(attention)
            .any(|found| found == *role)
    })
}

/// Whether a badge is a COMMAND's outcome, and which one.
///
/// The finish tiers fuse both speakers, so `agent_finish` decides: the agent's turn ending is the
/// mark column's check, a command's exit is the trailing slot's. An error is always a command's —
/// the agent status vocabulary has no error case.
#[must_use]
pub const fn command_outcome(badge: Option<TabBadge>, agent_finish: bool) -> Option<Outcome> {
    match badge {
        Some(TabBadge::Error) => Some(Outcome::Failed),
        Some(TabBadge::Completed | TabBadge::Finished) => {
            if agent_finish {
                None
            } else {
                Some(Outcome::Succeeded)
            }
        },
        Some(
            TabBadge::AwaitingInput
            | TabBadge::Caffeinate
            | TabBadge::CommandBusy
            | TabBadge::CommandRunning
            | TabBadge::Running
            | TabBadge::Sudo,
        )
        | None => None,
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

/// Which badges the user has left switched on, by SOURCE.
///
/// Two independent families: an agent's own chatter, and what a plain command's exit reports. They
/// are separate settings because silencing a thinking agent must not also silence the shell — so
/// the gates mask the INPUTS below and the ladder itself never learns a preference exists.
///
/// A sixth toggle exists in Settings — "when command awaits input" — and is absent here on purpose:
/// nothing yet produces that signal (the host-side quiescence detector is a deferred ceiling), so a
/// field for it would be a mask over a value that is never set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "five independent user switches; a bit field would trade five named fields for five bit \
              positions spelled on both sides of the boundary"
)]
pub struct Gates {
    /// Show the agent's thinking spinner. Ships OFF, unlike every other gate.
    pub agent_while_processing: bool,
    /// Show an agent's finished turn, live or latched unread.
    pub agent_when_complete: bool,
    /// Show the hand when an agent is blocked on a human.
    pub agent_when_awaiting_input: bool,
    /// Show a plain command's clean exit.
    pub command_when_finishes: bool,
    /// Show a plain command's non-zero exit.
    pub command_when_fails: bool,
}

impl Gates {
    /// Every badge shown — the shape a caller with no preferences to apply passes.
    pub const ALL_ON: Self = Self {
        agent_while_processing: true,
        agent_when_complete: true,
        agent_when_awaiting_input: true,
        command_when_finishes: true,
        command_when_fails: true,
    };
}

/// The one badge for a row once the user's toggles have had their say.
///
/// Each gate silences ONLY its own family's signal, by masking it to the value that contributes
/// nothing, and then the unchanged ladder runs. That is what keeps a silenced agent spinner from
/// also hiding a program's `OSC 9;4` progress or a busy shell: `is_busy` and `progress` are not
/// gated at all — they are the program speaking, which the spec gives no opt-out.
#[must_use]
pub fn resolve_gated(signals: Signals<'_>, gates: Gates) -> Option<TabBadge> {
    resolve(masked(signals, gates))
}

/// `signals` with everything the user switched off reduced to its no-contribution value.
const fn masked(signals: Signals<'_>, gates: Gates) -> Signals<'_> {
    let agent = match signals.agent {
        ClaudeStatus::Working if !gates.agent_while_processing => ClaudeStatus::Idle,
        ClaudeStatus::Done if !gates.agent_when_complete => ClaudeStatus::Idle,
        ClaudeStatus::NeedsPermission if !gates.agent_when_awaiting_input => ClaudeStatus::Idle,
        status => status,
    };
    let completion = match signals.completion {
        Some(Completion::Success) if !gates.command_when_finishes => None,
        Some(Completion::Failure) if !gates.command_when_fails => None,
        completion => completion,
    };
    Signals {
        agent,
        completion,
        // The unread latch is the SAME agent-finish the live `Done` is, so one toggle owns both.
        unseen_agent_done: signals.unseen_agent_done && gates.agent_when_complete,
        ..signals
    }
}

/// The one badge for a row, or `None` when it is all-clear.
#[must_use]
pub fn resolve(signals: Signals<'_>) -> Option<TabBadge> {
    // 1. A blocked agent demands a human; highest urgency.
    if signals.agent == ClaudeStatus::NeedsPermission {
        return Some(TabBadge::AwaitingInput);
    }

    // 2. A failed command, or a held-red progress error. Either sits above a running spinner and
    //    above a stale completion dot.
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
    use super::{
        Attention, Completion, Freshness, Gates, Outcome, Progress, Signals, TabBadge, attention,
        command_outcome, resolve, resolve_gated, rollup, urgent,
    };
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
    fn every_gate_off_silences_its_own_family_and_nothing_else() {
        let all_off = Gates {
            agent_while_processing: false,
            agent_when_complete: false,
            agent_when_awaiting_input: false,
            command_when_finishes: false,
            command_when_fails: false,
        };
        for (agent, badge) in [
            (ClaudeStatus::Working, TabBadge::Running),
            (ClaudeStatus::Done, TabBadge::Finished),
            (ClaudeStatus::NeedsPermission, TabBadge::AwaitingInput),
        ] {
            let row = Signals { agent, ..quiet() };
            assert_eq!(resolve_gated(row, Gates::ALL_ON), Some(badge));
            assert_eq!(resolve_gated(row, all_off), None, "{agent:?}");
        }
        for (completion, badge) in [
            (Completion::Success, TabBadge::Finished),
            (Completion::Failure, TabBadge::Error),
        ] {
            let row = Signals {
                completion: Some(completion),
                ..quiet()
            };
            assert_eq!(resolve_gated(row, Gates::ALL_ON), Some(badge));
            assert_eq!(resolve_gated(row, all_off), None, "{completion:?}");
        }
    }

    #[test]
    fn a_silenced_agent_still_lets_the_program_speak() {
        let quiet_agent = Gates {
            agent_while_processing: false,
            ..Gates::ALL_ON
        };
        let working_and_busy = Signals {
            agent: ClaudeStatus::Working,
            is_busy: true,
            progress: Some(Progress::Running),
            ..quiet()
        };
        assert_eq!(
            resolve_gated(working_and_busy, quiet_agent),
            Some(TabBadge::CommandRunning),
            "the program's own progress has no opt-out"
        );
        let error = Signals {
            progress: Some(Progress::Error),
            ..quiet()
        };
        assert_eq!(
            resolve_gated(error, Gates {
                command_when_fails: false,
                ..Gates::ALL_ON
            }),
            Some(TabBadge::Error),
            "a held-red OSC 9;4;2 is not a command's exit code"
        );
    }

    #[test]
    fn the_unread_finish_latch_answers_to_the_completion_toggle() {
        let latched = Signals {
            unseen_agent_done: true,
            ..quiet()
        };
        assert_eq!(resolve_gated(latched, Gates::ALL_ON), Some(TabBadge::Finished));
        assert_eq!(
            resolve_gated(latched, Gates {
                agent_when_complete: false,
                ..Gates::ALL_ON
            }),
            None,
            "the latch is the same finish the live status is"
        );
    }

    #[test]
    fn all_gates_on_is_the_ungated_ladder() {
        let busy_row = Signals {
            agent: ClaudeStatus::Working,
            completion: Some(Completion::Failure),
            is_busy: true,
            ..quiet()
        };
        assert_eq!(resolve_gated(busy_row, Gates::ALL_ON), resolve(busy_row));
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

    #[test]
    fn every_badge_says_something_and_no_two_share_a_word() {
        let mut words: Vec<&str> = TabBadge::ALL.iter().map(|badge| badge.label()).collect();
        for word in &words {
            assert!(!word.is_empty());
        }
        words.sort_unstable();
        let count = words.len();
        words.dedup();
        assert_eq!(words.len(), count, "a shared word is one state read as another");
    }

    /// The bit and the role must agree, or a row that raises the queue speaks no reason for it.
    #[test]
    fn the_attention_role_is_present_exactly_where_the_attention_bit_is() {
        for badge in TabBadge::ALL {
            assert_eq!(attention(badge).is_some(), badge.needs_attention(), "{badge:?}");
        }
        assert_eq!(attention(TabBadge::AwaitingInput), Some(Attention::Awaiting));
        assert_eq!(attention(TabBadge::Error), Some(Attention::Failed));
        assert_eq!(attention(TabBadge::Completed), Some(Attention::Finished));
        assert_eq!(attention(TabBadge::Finished), Some(Attention::Finished));
    }

    /// A finish is news, not an alarm — it never takes the whole title.
    #[test]
    fn a_finish_is_never_urgent() {
        assert_eq!(urgent(TabBadge::Finished), None);
        assert_eq!(urgent(TabBadge::Completed), None);
        assert_eq!(urgent(TabBadge::AwaitingInput), Some(Attention::Awaiting));
        assert_eq!(urgent(TabBadge::Error), Some(Attention::Failed));
    }

    #[test]
    fn the_rollup_picks_the_loudest_role_present() {
        assert_eq!(rollup(&[]), None);
        assert_eq!(rollup(&[None, Some(TabBadge::Running)]), None);
        assert_eq!(rollup(&[Some(TabBadge::Finished)]), Some(Attention::Finished));
        assert_eq!(
            rollup(&[Some(TabBadge::Finished), Some(TabBadge::Error)]),
            Some(Attention::Failed),
        );
        assert_eq!(
            rollup(&[
                Some(TabBadge::Error),
                Some(TabBadge::AwaitingInput),
                Some(TabBadge::Finished),
            ]),
            Some(Attention::Awaiting),
        );
    }

    /// The one fork the finish tiers force: whose ending this is.
    #[test]
    fn a_finish_is_a_command_outcome_only_when_it_is_not_the_agents() {
        assert_eq!(
            command_outcome(Some(TabBadge::Finished), false),
            Some(Outcome::Succeeded)
        );
        assert_eq!(command_outcome(Some(TabBadge::Finished), true), None);
        assert_eq!(
            command_outcome(Some(TabBadge::Completed), false),
            Some(Outcome::Succeeded)
        );
        assert_eq!(command_outcome(Some(TabBadge::Completed), true), None);
        // An error is a command's however the finish is attributed.
        assert_eq!(
            command_outcome(Some(TabBadge::Error), true),
            Some(Outcome::Failed)
        );
        assert_eq!(command_outcome(None, false), None);
    }

    #[test]
    fn no_role_or_outcome_crosses_as_the_absent_code() {
        for role in Attention::ALL {
            assert_ne!(role.code(), 0, "{role:?}");
        }
        for outcome in [Outcome::Succeeded, Outcome::Failed] {
            assert_ne!(outcome.code(), 0, "{outcome:?}");
        }
    }
}

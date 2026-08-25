//! When a watch on the pane under the user's eyes starts, is abandoned or SETTLES — plus the two
//! smaller supervision decisions that were spelled out in place beside it.
//!
//! [`crate::pane_facts`] answers what one status LANDING moves. What is here is the other half of
//! the same cockpit: the fold that runs over every pane a dwell clock is (or should be) ticking on,
//! the candidacy test that fold is written against, and the two one-line policies — what an empty
//! label means, and when an explicit acknowledge is allowed to settle a status — that had three and
//! two copies respectively in the store.
//!
//! ## No pane identity crosses
//!
//! The fold is handed one ROW per pane, in whatever order the caller unioned its watch map with its
//! candidate list, and answers one VERDICT per row in that same order. It never learns which pane a
//! row is, because it never needs to: the caller is holding the ids it built the rows from.
//!
//! ## No clock, and no window of its own
//!
//! `watched` and `window` both arrive as seconds from the caller, the same discipline
//! [`crate::pane_facts::settle_due`] keeps one layer down. A rule that read the wall clock could
//! not be asked about a chosen moment, and the whole of this one is about comparing two instants.

use slopdesk_agent::status::ClaudeStatus;

use crate::pane_facts::settle_due;

/// One pane's standing in the focused-finish watch, as the fold needs to see it.
///
/// The caller builds one of these per pane in the UNION of "has a clock running" and "is a
/// candidate right now" — the two halves the old spelling looped over separately, which is what let
/// a pane fall out of one loop and stay in the other.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Watch {
    /// Whether a dwell clock is already running on this pane.
    pub watching: bool,
    /// How long that clock has run, in the caller's own timebase. Meaningless — and ignored — when
    /// [`watching`](Self::watching) is `false`.
    pub watched: f64,
    /// Whether the pane is one a watch may run on at all right now, as
    /// [`settle_candidate`] answers it.
    pub candidate: bool,
}

/// What the fold says about ONE row.
///
/// Four cases rather than a pair of booleans because they are exclusive: a row that starts a clock
/// cannot also be settling one, and a caller handed two flags would have to know that.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettleVerdict {
    /// Nothing to do: the clock keeps running, or there was never one to run.
    Hold,
    /// START a clock at the caller's instant. The pane just became a candidate.
    Start,
    /// DROP the clock. The pane stopped being a candidate — focus left, the app went behind, or the
    /// marker cleared — and the window measures an UNBROKEN watch, so a later return starts fresh.
    Drop,
    /// The window elapsed under an unbroken watch: ACKNOWLEDGE the pane. Reading it is seeing it.
    Settle,
}

impl SettleVerdict {
    /// Every verdict, in the order their bytes are numbered.
    pub const ALL: [Self; 4] = [Self::Hold, Self::Start, Self::Drop, Self::Settle];

    /// The byte this verdict crosses as — its position in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Hold => 0,
            Self::Start => 1,
            Self::Drop => 2,
            Self::Settle => 3,
        }
    }

    /// The inverse of [`code`](Self::code). An unnamed byte reads as [`Hold`](Self::Hold) — the
    /// verdict that changes nothing, which is the only safe thing to do with an answer this build
    /// cannot name.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Start,
            2 => Self::Drop,
            3 => Self::Settle,
            _ => Self::Hold,
        }
    }
}

/// The whole focused-finish fold: one verdict per row, in the caller's order.
///
/// A row that is watched and no longer a candidate is dropped BEFORE anything else is decided,
/// which is what makes the window an unbroken one. A row that is a candidate with no clock starts
/// one — and starting even a single clock is what arms the caller's one-shot, since a finished
/// agent stops mutating the store and nothing else would ever look again.
#[must_use]
pub fn settle_step(watches: &[Watch], window: f64) -> Vec<SettleVerdict> {
    watches
        .iter()
        .map(|watch| {
            match (watch.watching, watch.candidate) {
                (true, false) => SettleVerdict::Drop,
                (false, true) => SettleVerdict::Start,
                (true, true) if settle_due(watch.watched, window) => SettleVerdict::Settle,
                _ => SettleVerdict::Hold,
            }
        })
        .collect()
}

/// Whether any row of a [`settle_step`] answer started a clock — the caller's one-shot arming.
///
/// Answered here rather than left as a scan on the far side because it is the same fold's second
/// conclusion, and a caller that had to re-derive it would be the third place the rule lived.
#[must_use]
pub fn arms_scheduler(verdicts: &[SettleVerdict]) -> bool {
    verdicts
        .iter()
        .any(|verdict| matches!(*verdict, SettleVerdict::Start))
}

/// Whether a watch may run on a pane at all.
///
/// Focused in an ACTIVE app — a key satellite window counts as focused, but only while the app
/// itself is frontmost, because nobody is reading a background window — and carrying a
/// finished-turn marker, either a live [`ClaudeStatus::Done`] or the unread latch. A live `Working`
/// or `NeedsPermission` is never unread OUTPUT, so it never starts a clock: the settle can
/// therefore never silence a waiting approval gate.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "four independent facts from four sources — a struct would only rename the same four"
)]
pub const fn settle_candidate(app_active: bool, focused: bool, finished: bool, unseen_finish: bool) -> bool {
    app_active && focused && (finished || unseen_finish)
}

/// Whether a walk in progress has been INTERRUPTED and must be abandoned.
///
/// The jump-to-unread walk remembers the pane it itself last focused. Any focus change that did not
/// come from the walk — a tab click, a `⌘1-9`, a session switch, a peek — is detected lazily on the
/// next press by comparing what is focused now against that memory. `walking` is false before the
/// first step, when there is no walk to abandon and nothing to compare against.
#[must_use]
pub const fn walk_interrupted(walking: bool, focus_held: bool) -> bool {
    walking && !focus_held
}

/// Whether an explicit acknowledge may settle the pane's agent status to idle.
///
/// Only a finished turn. A LIVE state — running, awaiting input, a held progress error — is
/// deliberately left alone: clearing a badge acknowledges unread output, it never fakes away a
/// still-active signal, and never an approval gate.
#[must_use]
pub const fn badge_clear_settles(status: ClaudeStatus) -> bool {
    matches!(status, ClaudeStatus::Done)
}

/// Text with nothing in it, as the ABSENCE of a value.
///
/// The store's one normalization for every host-pushed label: the agent label, the sticky session
/// intent and the coarse foreground-process name each had their own verbatim copy of it, and each
/// removed its key on the empty push so the row falls back down its own chain rather than titling
/// itself with a blank.
///
/// Trimming is the Unicode `White_Space` set, which is the same set the near side's
/// `whitespacesAndNewlines` names — so a non-breaking space is whitespace on both sides of the
/// boundary rather than a label that looks empty and is not.
#[must_use]
pub fn normalized_text(raw: &str) -> Option<&str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() { None } else { Some(trimmed) }
}

#[cfg(test)]
mod tests {
    use slopdesk_agent::status::ClaudeStatus;

    use super::{
        SettleVerdict, Watch, arms_scheduler, badge_clear_settles, normalized_text, settle_candidate,
        settle_step, walk_interrupted,
    };

    /// Every verdict's byte round-trips, and an unnamed byte degrades to the inert one.
    #[test]
    fn the_verdict_bytes_round_trip() {
        for verdict in SettleVerdict::ALL {
            assert_eq!(SettleVerdict::from_code(verdict.code()), verdict);
        }
        assert_eq!(SettleVerdict::from_code(200), SettleVerdict::Hold);
    }

    /// The four row shapes, exhaustively, at a watch that has not reached the window.
    #[test]
    fn a_short_watch_answers_the_four_shapes() {
        let rows = [
            Watch {
                watching: false,
                watched: 0.0,
                candidate: false,
            },
            Watch {
                watching: false,
                watched: 0.0,
                candidate: true,
            },
            Watch {
                watching: true,
                watched: 1.0,
                candidate: false,
            },
            Watch {
                watching: true,
                watched: 1.0,
                candidate: true,
            },
        ];
        assert_eq!(settle_step(&rows, 30.0), vec![
            SettleVerdict::Hold,
            SettleVerdict::Start,
            SettleVerdict::Drop,
            SettleVerdict::Hold,
        ]);
    }

    /// A watch that REACHES the window settles; one a tick short holds. The boundary is
    /// `pane_facts::settle_due`'s, not a second one.
    #[test]
    fn the_window_settles_when_it_is_reached() {
        let held = Watch {
            watching: true,
            watched: 29.9,
            candidate: true,
        };
        let due = Watch {
            watching: true,
            watched: 30.0,
            candidate: true,
        };
        assert_eq!(settle_step(&[held], 30.0), vec![SettleVerdict::Hold]);
        assert_eq!(settle_step(&[due], 30.0), vec![SettleVerdict::Settle]);
    }

    /// A pane that stopped being a candidate is dropped even when its watch is long past due — the
    /// window measures an UNBROKEN watch, so an abandoned one settles nothing.
    #[test]
    fn an_abandoned_watch_drops_rather_than_settling() {
        let rows = [Watch {
            watching: true,
            watched: 9_000.0,
            candidate: false,
        }];
        assert_eq!(settle_step(&rows, 30.0), vec![SettleVerdict::Drop]);
    }

    /// Only a started clock arms the one-shot.
    #[test]
    fn only_a_start_arms_the_scheduler() {
        assert!(arms_scheduler(&[SettleVerdict::Hold, SettleVerdict::Start]));
        assert!(!arms_scheduler(&[
            SettleVerdict::Hold,
            SettleVerdict::Drop,
            SettleVerdict::Settle,
        ]));
        assert!(!arms_scheduler(&[]));
    }

    /// Candidacy over its whole domain: both gates are necessary, and either marker suffices.
    #[test]
    fn candidacy_is_both_gates_and_either_marker() {
        for app_active in [false, true] {
            for focused in [false, true] {
                for finished in [false, true] {
                    for unseen in [false, true] {
                        assert_eq!(
                            settle_candidate(app_active, focused, finished, unseen),
                            app_active && focused && (finished || unseen),
                            "({app_active}, {focused}, {finished}, {unseen})"
                        );
                    }
                }
            }
        }
    }

    /// A walk is abandoned only when one is running and the focus it set has moved under it.
    #[test]
    fn only_a_running_walk_can_be_interrupted() {
        assert!(walk_interrupted(true, false));
        assert!(!walk_interrupted(true, true));
        assert!(!walk_interrupted(false, false));
        assert!(!walk_interrupted(false, true));
    }

    /// Exactly one status is settled by an acknowledge; every live one is left alone.
    #[test]
    fn the_acknowledge_settles_only_a_finished_turn() {
        for status in ClaudeStatus::ALL {
            assert_eq!(
                badge_clear_settles(status),
                status == ClaudeStatus::Done,
                "{status:?}"
            );
        }
    }

    /// Empty, blank and whitespace-only text are all ABSENT; anything else keeps its trim.
    #[test]
    fn blank_text_is_absence() {
        assert_eq!(normalized_text(""), None);
        assert_eq!(normalized_text("   "), None);
        assert_eq!(normalized_text("\n\t "), None);
        assert_eq!(normalized_text("\u{a0}"), None);
        assert_eq!(normalized_text("  build  "), Some("build"));
        assert_eq!(normalized_text("cargo test"), Some("cargo test"));
    }

    /// The trim never cuts inside a character, and never returns something the input did not hold.
    #[test]
    fn a_trim_is_always_a_slice_of_its_input() {
        for raw in ["", " é ", "é", "  ⌘⇧U  ", "a b", " \u{a0}x\u{a0} "] {
            if let Some(trimmed) = normalized_text(raw) {
                assert!(raw.contains(trimmed), "{raw:?} → {trimmed:?}");
                assert!(!trimmed.is_empty());
            }
        }
    }
}

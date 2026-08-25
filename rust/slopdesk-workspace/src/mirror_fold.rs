//! What the near side asks ABOUT the client's replica of the host-owned document, once it has one.
//!
//! The replica itself is `slopdesk_wire::document::mirror` — the three layers, their bytes, the
//! keys they are filed under, and every decision one frame makes about them. This module is what
//! is left over: folds whose inputs are values the near side already holds in hand, none of which
//! is a document. Which of three candidate strings names the running command, whether the host has
//! published a grid, whether a document change may reconcile, which intent a spec edit becomes,
//! and who — other than you — is looking at or holding a pane.
//!
//! Every one of them is a pure function of its arguments with no state between calls, which is
//! exactly why they did not go with the document: a handle would have had to be told these values
//! to answer, so the handle would buy nothing.
//!
//! ## No identity crosses
//!
//! The two roster joins are the only doors here that see a collection of THINGS, and they see them
//! as dense `u32` tokens the caller minted: a client is a token and a flag, an attachment is a
//! token. The answers are POSITIONS into the list the caller still holds. A `UUID` never crosses,
//! and neither does a label — the join decides WHICH label, and the caller reads it.

use crate::attention_fold::normalized_text;

// MARK: - Reads

/// Which of the three candidates names the command a pane is RUNNING.
///
/// The host's own open block leads, and this is the one liveness fact where that matters most. A
/// returning client gets the foreground process, the agent status and the session intent
/// re-asserted for it, so those recover on their own; the open command's TEXT does not, because it
/// lives in a per-materialization block model and a pane whose bytes were never rendered here has
/// no blocks at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunningCommand<'a> {
    /// The host's `pane/runningCommand`, trimmed.
    Hosted(&'a str),
    /// This client's own newest OPEN block, trimmed.
    Open(&'a str),
    /// The caller's cleaned-up foreground-process name. The text stays on the near side — the
    /// cleanup that produced it is the interface's, and it is already holding the string.
    ProcessLabel,
    /// Nothing is known, so the caller's remaining chain keeps resolving.
    Absent,
}

impl<'a> RunningCommand<'a> {
    /// The byte this choice crosses as: `0` nothing · `1` the host's open block · `2` this client's
    /// own · `3` the caller's process label.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Absent => 0,
            Self::Hosted(_) => 1,
            Self::Open(_) => 2,
            Self::ProcessLabel => 3,
        }
    }

    /// The text this choice names, when it names one here.
    #[must_use]
    pub const fn text(self) -> Option<&'a str> {
        match self {
            Self::Hosted(text) | Self::Open(text) => Some(text),
            Self::ProcessLabel | Self::Absent => None,
        }
    }
}

/// Resolves the running-command chain. Blank at any rung is ABSENT at that rung, not a blank answer
/// — the same rule [`normalized_text`] states, applied to two of the three candidates.
#[must_use]
pub fn running_command<'a>(hosted: &'a str, open: &'a str, has_process_label: bool) -> RunningCommand<'a> {
    if let Some(text) = normalized_text(hosted) {
        return RunningCommand::Hosted(text);
    }
    if let Some(text) = normalized_text(open) {
        return RunningCommand::Open(text);
    }
    if has_process_label {
        RunningCommand::ProcessLabel
    } else {
        RunningCommand::Absent
    }
}

/// Whether the host has actually RESOLVED a grid for a pane.
///
/// Both dimensions or neither. A zero on either axis is the roster's "not published yet", and a
/// size-passive client that letterboxed against it would be placing a pane behind a fiction.
#[must_use]
pub const fn grid_published(cols: u32, rows: u32) -> bool {
    cols > 0 && rows > 0
}

/// Whether a document change may reconcile the registry against the layout it produced.
///
/// Four refusals, and each one is a race with a layout that is about to be replaced:
///
/// - a reconcile ALREADY RUNNING owns the diff;
/// - the ABSENCE of a projection is not an empty one — reconciling against the zero sessions a
///   re-subscribe leaves would tear down every live pane and rebuild it a moment later;
/// - an ARMED BOOTSTRAP is a layout this client was told to publish and has not had a channel to
///   say on, so the frame that arrives first is the host's own first-run default;
/// - an OUTSTANDING LAUNCH ADOPT is the same race on the ordinary path — unless the replica still
///   holds this client's own SEED, which IS the tree on offer and so has nothing to hold against.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "five independent refusals from five sources — a struct would only rename the same five"
)]
pub const fn reconcile_admitted(
    reconciling: bool,
    projected: bool,
    bootstrap_armed: bool,
    adopt_pending: bool,
    epoch_is_seed: bool,
) -> bool {
    !reconciling && projected && !bootstrap_armed && (!adopt_pending || epoch_is_seed)
}

/// Which intent a spec edit becomes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpecIntent {
    /// REFUSED: the edit touched a field this client cannot publish, and the next host frame would
    /// erase it. The caller names it in the debug log rather than dropping it silently.
    Refused,
    /// The VIDEO BINDING moved — a display switch or a window re-pick moving a stream that is
    /// already running.
    VideoTarget,
    /// An AUTHORED title. A DERIVED one needs no op: it follows the binding, and the applier
    /// renames the pane alongside the re-point. Sending it as a rename would set the authorship
    /// flag and make the NEXT re-pick unable to update it.
    Rename,
}

impl SpecIntent {
    /// Every intent, in the order their bytes are numbered.
    pub const ALL: [Self; 3] = [Self::Refused, Self::VideoTarget, Self::Rename];

    /// The byte this choice crosses as — its position in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Refused => 0,
            Self::VideoTarget => 1,
            Self::Rename => 2,
        }
    }

    /// The inverse of [`code`](Self::code). An unnamed byte publishes NOTHING, which is the only
    /// choice that cannot send an intent the caller did not mean.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::VideoTarget,
            2 => Self::Rename,
            _ => Self::Refused,
        }
    }
}

/// Picks the intent for a spec edit that actually changed something.
///
/// The video binding is checked FIRST and exclusively: a re-point that also moved the derived title
/// is one gesture, and the applier renames alongside it.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "four independent facts about one edit — a struct would only rename the same four"
)]
pub const fn spec_intent(
    video_moved: bool,
    user_renamed: bool,
    title_moved: bool,
    was_user_renamed: bool,
) -> SpecIntent {
    if video_moved {
        return SpecIntent::VideoTarget;
    }
    if user_renamed && (title_moved || !was_user_renamed) {
        return SpecIntent::Rename;
    }
    SpecIntent::Refused
}

// MARK: - The roster's two joins

/// One roster client, as the joins need it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RosterClient {
    /// The dense token the caller minted for this client's instance id.
    pub token: u32,
    /// Whether the client published a label anybody can read. An unlabelled client can still HOLD a
    /// pane — it just cannot be named.
    pub labelled: bool,
    /// Whether the client is looking at the pane being asked about.
    pub viewing: bool,
}

/// The other clients currently LOOKING at a pane, as POSITIONS into `clients`.
///
/// Viewing is a separate fact from holding, and both are worth saying: a client can have a pane on
/// screen with no channel on it, and it can hold a channel on a pane it is not showing. An
/// unlabelled viewer is dropped — there is nothing to print — which is exactly where this differs
/// from [`holders`].
#[must_use]
pub fn viewers(clients: &[RosterClient], own: Option<u32>) -> Vec<u32> {
    clients
        .iter()
        .enumerate()
        .filter(|(_, client)| {
            client.viewing && client.labelled && !matches!(own, Some(mine) if mine == client.token)
        })
        .filter_map(|(index, _)| u32::try_from(index).ok())
        .collect()
}

/// The other clients HOLDING a channel on a pane, one answer per surviving attachment in
/// `attachments` order.
///
/// [`Some`] is a POSITION into `clients` — the client whose label names this attachment. [`None`]
/// is an attachment no roster client names, and it is REPORTED rather than dropped: a bare client
/// opens no workspace channel, so the host publishes its attachment with the all-zero instance id
/// and nothing can name it. It is still a real client holding a real pane at a real size, and
/// dropping it would make that pane read as unheld and make the resolved grid's arithmetic
/// unexplainable.
///
/// A client with no label is the same case — the join legitimately misses, and the answer is the
/// unnamed one rather than silence.
#[must_use]
pub fn holders(attachments: &[u32], clients: &[RosterClient], own: Option<u32>) -> Vec<Option<u32>> {
    attachments
        .iter()
        .filter(|token| !matches!(own, Some(mine) if mine == **token))
        .map(|token| {
            clients
                .iter()
                .position(|client| client.labelled && client.token == *token)
                .and_then(|index| u32::try_from(index).ok())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        RosterClient, RunningCommand, SpecIntent, grid_published, holders, reconcile_admitted,
        running_command, spec_intent, viewers,
    };

    /// The chain in order, with blank rungs skipped rather than answered.
    #[test]
    fn the_running_command_chain_skips_blank_rungs() {
        assert_eq!(
            running_command("  cargo build  ", "make", true),
            RunningCommand::Hosted("cargo build")
        );
        assert_eq!(
            running_command("   ", " make test ", true),
            RunningCommand::Open("make test")
        );
        assert_eq!(running_command("", "\n", true), RunningCommand::ProcessLabel);
        assert_eq!(running_command("", "", false), RunningCommand::Absent);
    }

    /// The choice's byte and its text agree about which rung won.
    #[test]
    fn the_chain_names_its_own_rung() {
        assert_eq!(running_command("x", "y", true).code(), 1);
        assert_eq!(running_command("", "y", true).code(), 2);
        assert_eq!(running_command("", "", true).code(), 3);
        assert_eq!(running_command("", "", false).code(), 0);
        assert_eq!(running_command("", "y", true).text(), Some("y"));
        assert_eq!(running_command("", "", true).text(), None);
    }

    /// Both axes, or the host has published nothing.
    #[test]
    fn a_grid_needs_both_axes() {
        assert!(grid_published(120, 40));
        assert!(!grid_published(0, 40));
        assert!(!grid_published(120, 0));
        assert!(!grid_published(0, 0));
    }

    /// The reconcile gate over its whole domain.
    #[test]
    fn the_reconcile_gate_over_its_domain() {
        for reconciling in [false, true] {
            for projected in [false, true] {
                for bootstrap in [false, true] {
                    for adopt in [false, true] {
                        for seed in [false, true] {
                            assert_eq!(
                                reconcile_admitted(reconciling, projected, bootstrap, adopt, seed),
                                !reconciling && projected && !bootstrap && (!adopt || seed),
                                "({reconciling}, {projected}, {bootstrap}, {adopt}, {seed})"
                            );
                        }
                    }
                }
            }
        }
    }

    /// The video binding wins outright; a rename needs authorship and something new to say.
    #[test]
    fn the_spec_intent_ladder() {
        assert_eq!(spec_intent(true, false, false, false), SpecIntent::VideoTarget);
        assert_eq!(spec_intent(true, true, true, true), SpecIntent::VideoTarget);
        assert_eq!(spec_intent(false, true, true, true), SpecIntent::Rename);
        assert_eq!(
            spec_intent(false, true, false, false),
            SpecIntent::Rename,
            "authorship itself is the news the first time"
        );
        assert_eq!(spec_intent(false, true, false, true), SpecIntent::Refused);
        assert_eq!(spec_intent(false, false, true, false), SpecIntent::Refused);
    }

    /// Viewers: this client is never one, and an unlabelled one has nothing to print.
    #[test]
    fn viewers_drop_self_and_the_unnamed() {
        let clients = [
            RosterClient {
                token: 1,
                labelled: true,
                viewing: true,
            },
            RosterClient {
                token: 2,
                labelled: true,
                viewing: false,
            },
            RosterClient {
                token: 3,
                labelled: false,
                viewing: true,
            },
            RosterClient {
                token: 4,
                labelled: true,
                viewing: true,
            },
        ];
        assert_eq!(viewers(&clients, Some(4)), vec![0]);
        assert_eq!(viewers(&clients, None), vec![0, 3]);
        assert_eq!(viewers(&[], Some(1)), Vec::<u32>::new());
    }

    /// Holders: this client is dropped, everyone else is reported — named when the join hits, and
    /// unnamed when it misses, but never silently.
    #[test]
    fn holders_report_the_unnamed_rather_than_dropping_them() {
        let clients = [
            RosterClient {
                token: 1,
                labelled: true,
                viewing: false,
            },
            RosterClient {
                token: 2,
                labelled: false,
                viewing: false,
            },
        ];
        let attachments = [1_u32, 2, 3, 7];
        assert_eq!(holders(&attachments, &clients, Some(7)), vec![
            Some(0),
            None,
            None
        ]);
        assert_eq!(holders(&attachments, &clients, None), vec![
            Some(0),
            None,
            None,
            None
        ]);
        assert_eq!(holders(&[], &clients, None), Vec::<Option<u32>>::new());
    }

    /// Two attachments from the same client are two holdings, and both are named.
    #[test]
    fn a_repeated_attachment_is_reported_twice() {
        let clients = [RosterClient {
            token: 5,
            labelled: true,
            viewing: false,
        }];
        assert_eq!(holders(&[5, 5], &clients, None), vec![Some(0), Some(0)]);
    }
}

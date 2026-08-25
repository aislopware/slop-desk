//! What one frame does to the client's replica of the host-owned document, and what the replica's
//! layers answer when they are read.
//!
//! The replica itself — the three layers, their `Data` values and the keys they are filed under —
//! stays on the near side, because it is a value type the interface binds to. What crossed is every
//! DECISION it used to make in place: whether a frame may be folded at all, when an optimistic
//! patch is retired or expires, which of the three candidate strings is the running command,
//! whether the host has published a grid, whether a document change may reconcile, which intent a
//! spec edit becomes, and who — other than you — is looking at or holding a pane.
//!
//! ## No identity crosses
//!
//! The two roster joins are the only doors here that see a collection of THINGS, and they see them
//! as dense `u32` tokens the caller minted: a client is a token and a flag, an attachment is a
//! token. The answers are POSITIONS into the list the caller still holds. A `UUID` never crosses,
//! and neither does a label — the join decides WHICH label, and the caller reads it.
//!
//! ## The mirror stays clockless
//!
//! `now` and `timeout` arrive as seconds from the caller. The replica only ever COMPARES instants,
//! which is the same discipline the freshness rule keeps one layer down, and it is what makes
//! expiry pinnable at a chosen moment instead of by sleeping.

use crate::attention_fold::normalized_text;

// MARK: - Folding one frame

/// What a DIFF frame may do to the replica.
///
/// A snapshot is self-contained and is folded whatever the replica holds — including across an
/// epoch change with no intervening reset, which is exactly the cold-connect case — so it is not a
/// decision and has no case here. A diff is only meaningful against a document already held, and
/// this is that test.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameVerdict {
    /// The frame cannot be based on what is held: the wrong document, or a base this replica is not
    /// at and cannot reach. The caller re-sends `subscribe`, which IS the resync verb.
    NeedsResubscribe,
    /// Already superseded. Nothing changes — and deliberately NOT an error: duplicates and reorders
    /// are no-ops by construction.
    Ignored,
    /// Fold it. Host truth moves to the new state number.
    Applied,
}

impl FrameVerdict {
    /// Every verdict, in the order their bytes are numbered.
    pub const ALL: [Self; 3] = [Self::NeedsResubscribe, Self::Ignored, Self::Applied];

    /// The byte this verdict crosses as — its position in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::NeedsResubscribe => 0,
            Self::Ignored => 1,
            Self::Applied => 2,
        }
    }

    /// The inverse of [`code`](Self::code). An unnamed byte reads as
    /// [`NeedsResubscribe`](Self::NeedsResubscribe) — the answer that costs a round trip and can
    /// never leave the replica claiming a state it is not at.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Ignored,
            2 => Self::Applied,
            _ => Self::NeedsResubscribe,
        }
    }
}

/// Whether a diff frame may be folded onto a replica at `held`.
///
/// `epoch_held` is the caller's own comparison — it holds an epoch AND that epoch is this frame's —
/// collapsed to the one bit the rule needs, because the identity is a `UUID` and stays on the near
/// side.
///
/// The middle clause is the subtle one. A base the replica is not at is either a frame it has
/// already passed (a duplicate or a reorder, which assign-not-mutate makes a no-op) or one reaching
/// FORWARD from a state that was never applied — and only the second is unrecoverable.
#[must_use]
pub const fn diff_frame(epoch_held: bool, base: i64, new: i64, held: i64) -> FrameVerdict {
    if !epoch_held {
        return FrameVerdict::NeedsResubscribe;
    }
    if base != held {
        if new <= held {
            return FrameVerdict::Ignored;
        }
        return FrameVerdict::NeedsResubscribe;
    }
    if new <= held {
        return FrameVerdict::Ignored;
    }
    FrameVerdict::Applied
}

/// What `subscribe` should declare as the state it holds.
///
/// All-or-nothing with the epoch: a state number without a document to attach it to reads as "I
/// know nothing", which is what makes a snapshot the answer. There is deliberately no way to ask
/// for a diff against a document this replica does not hold.
#[must_use]
pub const fn known_state_num(epoch_held: bool, state_num: i64) -> i64 {
    if epoch_held { state_num } else { 0 }
}

// MARK: - The optimistic layer

/// What the host's verdict on one in-flight intent does to its optimistic patch.
///
/// `applied` is the caller's own comparison of the wire status against `applied`, collapsed to a
/// bit — the status vocabulary belongs to the wire, and re-spelling it here would be a second place
/// for it to drift.
///
/// A REFUSAL drops the patch immediately (the answer is [`None`]) rather than at the next frame.
/// That is the anti-flicker rule stated the useful way round: a refusal is the one case where
/// waiting shows the user something the host has already said is not true.
///
/// An acceptance holds the patch until the NEXT document frame, so the pane does not blink out
/// between the answer and the frame that makes it real. A frame count rather than a state number
/// because the result carries none — and it does not need to: the host bumps the state and queues
/// the new document BEFORE it queues the result, so the first frame after an acceptance provably
/// already contains that intent's effect.
#[must_use]
pub const fn intent_retire(applied: bool, frames_applied: u64) -> Option<u64> {
    if !applied {
        return None;
    }
    // Saturating rather than wrapping: a count that reached `u64::MAX` would have to be wrong, and
    // an answer that wrapped to zero would retire every standing patch at the next frame.
    Some(frames_applied.saturating_add(1))
}

/// Which patches survive the document frame that just landed, as POSITIONS into `retire_at`.
///
/// `frames_applied` is the count INCLUDING the frame being folded — the caller bumps its own
/// watermark and asks about the result, so the comparison and the bump cannot disagree about which
/// frame this is.
#[must_use]
pub fn survivors_after_frame(retire_at: &[Option<u64>], frames_applied: u64) -> Vec<u32> {
    retire_at
        .iter()
        .enumerate()
        .filter(|(_, retire)| !matches!(**retire, Some(at) if frames_applied >= at))
        .filter_map(|(index, _)| u32::try_from(index).ok())
        .collect()
}

/// One in-flight patch's age evidence.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Age {
    /// When the intent was issued, in the caller's own timebase.
    pub issued_at: f64,
    /// Whether the host has already ANSWERED this patch, so it is waiting on a frame rather than on
    /// the host. A patch with an answer is never expired out from under the frame that will retire
    /// it.
    pub retiring: bool,
}

/// Which patches survive the expiry sweep at `now`, as POSITIONS into `ages`.
///
/// The backstop for the case with no other signal: a host that accepted the intent and died before
/// answering. Everything else has a definite end — a verdict retires it, a failed send drops it —
/// and this is only for the silence.
///
/// The comparison is `>=` on the elapsed seconds, which is the near side's verbatim: a `NaN`
/// elapsed (an issue instant the caller never set) leaves the patch STANDING rather than expiring
/// it on arithmetic nobody wrote.
#[must_use]
pub fn survivors_after_timeout(ages: &[Age], now: f64, timeout: f64) -> Vec<u32> {
    ages.iter()
        .enumerate()
        .filter(|(_, age)| {
            let elapsed = now - age.issued_at;
            // Written as the NEGATION of the expiry test, not as its De Morgan twin: the two agree
            // on every ordered pair and disagree on NaN, where `!(NaN >= t)` keeps the patch and
            // `NaN < t` drops it. The paragraph above is the whole point, so the shape stays.
            #[expect(
                clippy::nonminimal_bool,
                reason = "`elapsed < timeout || age.retiring` is NOT this expression for a NaN elapsed — \
                          see `an_uncomparable_age_never_expires`"
            )]
            !(elapsed >= timeout && !age.retiring)
        })
        .filter_map(|(index, _)| u32::try_from(index).ok())
        .collect()
}

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
        Age, FrameVerdict, RosterClient, RunningCommand, SpecIntent, diff_frame, grid_published, holders,
        intent_retire, known_state_num, reconcile_admitted, running_command, spec_intent,
        survivors_after_frame, survivors_after_timeout, viewers,
    };

    /// Both verdict vocabularies round-trip, and an unnamed byte reads as the conservative case.
    #[test]
    fn the_verdict_bytes_round_trip() {
        for verdict in FrameVerdict::ALL {
            assert_eq!(FrameVerdict::from_code(verdict.code()), verdict);
        }
        assert_eq!(FrameVerdict::from_code(9), FrameVerdict::NeedsResubscribe);
        for intent in SpecIntent::ALL {
            assert_eq!(SpecIntent::from_code(intent.code()), intent);
        }
        assert_eq!(SpecIntent::from_code(9), SpecIntent::Refused);
    }

    /// A frame for another document — or for none — is never folded, whatever its numbers say.
    #[test]
    fn a_frame_without_a_document_resubscribes() {
        for base in [0_i64, 1, 7] {
            for new in [0_i64, 1, 8] {
                assert_eq!(diff_frame(false, base, new, 7), FrameVerdict::NeedsResubscribe);
            }
        }
    }

    /// The whole small domain of `(base, new)` around a replica at 5.
    #[test]
    fn the_diff_ladder_over_a_small_domain() {
        let held = 5_i64;
        for base in 0..=8_i64 {
            for new in 0..=8_i64 {
                let expected = if base == held {
                    if new <= held {
                        FrameVerdict::Ignored
                    } else {
                        FrameVerdict::Applied
                    }
                } else if new <= held {
                    FrameVerdict::Ignored
                } else {
                    FrameVerdict::NeedsResubscribe
                };
                assert_eq!(diff_frame(true, base, new, held), expected, "{base} → {new}");
            }
        }
    }

    /// The three cases worth naming: the ordinary advance, the duplicate, and the gap.
    #[test]
    fn the_three_named_diff_cases() {
        assert_eq!(diff_frame(true, 5, 6, 5), FrameVerdict::Applied);
        assert_eq!(diff_frame(true, 4, 5, 5), FrameVerdict::Ignored);
        assert_eq!(diff_frame(true, 6, 7, 5), FrameVerdict::NeedsResubscribe);
    }

    /// A state number with no document behind it is not a state number.
    #[test]
    fn the_declared_state_is_all_or_nothing() {
        assert_eq!(known_state_num(true, 12), 12);
        assert_eq!(known_state_num(false, 12), 0);
        assert_eq!(known_state_num(true, 0), 0);
    }

    /// An acceptance holds one more frame; a refusal holds nothing.
    #[test]
    fn a_refusal_retires_now_and_an_acceptance_next_frame() {
        assert_eq!(intent_retire(true, 4), Some(5));
        assert_eq!(intent_retire(false, 4), None);
        assert_eq!(intent_retire(true, u64::MAX), Some(u64::MAX));
    }

    /// Only a patch whose watermark has been REACHED goes; an unanswered one always stays.
    #[test]
    fn a_frame_retires_only_what_it_supersedes() {
        let rows = [None, Some(3_u64), Some(4_u64), Some(9_u64)];
        assert_eq!(survivors_after_frame(&rows, 4), vec![0, 3]);
        assert_eq!(survivors_after_frame(&rows, 2), vec![0, 1, 2, 3]);
        assert_eq!(survivors_after_frame(&rows, 9), vec![0]);
        assert_eq!(survivors_after_frame(&[], 1), Vec::<u32>::new());
    }

    /// Expiry takes the silent ones only, and REACHING the timeout is enough.
    #[test]
    fn expiry_takes_the_unanswered_at_the_window() {
        let rows = [
            Age {
                issued_at: 0.0,
                retiring: false,
            },
            Age {
                issued_at: 0.0,
                retiring: true,
            },
            Age {
                issued_at: 1.0,
                retiring: false,
            },
        ];
        assert_eq!(survivors_after_timeout(&rows, 3.0, 3.0), vec![1, 2]);
        assert_eq!(survivors_after_timeout(&rows, 2.9, 3.0), vec![0, 1, 2]);
        assert_eq!(survivors_after_timeout(&rows, 4.0, 3.0), vec![1]);
    }

    /// An elapsed nobody can compare leaves the patch standing rather than expiring it.
    #[test]
    fn an_uncomparable_age_never_expires() {
        let rows = [Age {
            issued_at: f64::NAN,
            retiring: false,
        }];
        assert_eq!(survivors_after_timeout(&rows, 100.0, 3.0), vec![0]);
    }

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
